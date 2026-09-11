defmodule Orchard.Models.Importer402RegressionTest do
  use Orchard.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Orchard.ArtifactBundle
  alias Orchard.Models
  alias Orchard.Models.Importer

  @fixture Path.expand("../../fixtures/bundles/test-model-bundle", __DIR__)

  # Compile a renamed production AST with barriers at otherwise private race
  # boundaries. No filesystem, parser or database operations are replaced.
  # The separate public-entrypoint test verifies the actual module's lock too;
  # this instrumentation is not a cross-BEAM or crash-recovery test.
  setup_all do
    source = Path.expand("../../../lib/orchard/models/importer.ex", __DIR__)
    ast = source |> File.read!() |> Code.string_to_quoted!()

    ast =
      Macro.postwalk(ast, fn
        {:defmodule, meta, [_name, body]} ->
          {:defmodule, meta, [Orchard.Models.Importer402Instrumented, body]}

        {:defp, meta, [{name, _, _} = head, [do: body]]}
        when name in [:stage_bundle, :move_staged_to_dest] ->
          body =
            quote do
              unquote(__MODULE__).barrier(unquote(name))
              unquote(body)
            end

          {:defp, meta, [head, [do: body]]}

        {{:., _, [{:__aliases__, _, [:File]}, :rm_rf]}, _, [{:dest_path, _, _}]} = call ->
          quote do
            unquote(__MODULE__).barrier(:cleanup_destination)
            unquote(call)
          end

        other ->
          other
      end)

    [{instrumented_importer, _bytecode}] = Code.compile_quoted(ast, source)
    %{instrumented_importer: instrumented_importer}
  end

  setup tags do
    root = Path.join(System.tmp_dir!(), "orchard-402-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    if tags[:unboxed], do: Sandbox.checkin(Repo)

    on_exit(fn ->
      if tags[:unboxed] do
        Sandbox.unboxed_run(Repo, fn ->
          Repo.delete_all(
            from(model in Models.Model,
              where: like(model.artifact_uri, ^("file://" <> root <> "/%"))
            )
          )
        end)
      end

      File.rm_rf!(root)
    end)

    %{root: root, artifacts: Path.join(root, "artifacts")}
  end

  @tag :unboxed
  test "SPEC 6.4/6.5 concurrent overlapping imports preserve every catalog digest",
       %{instrumented_importer: importer} = ctx do
    outer = bundle(ctx.root, "outer", "owner/model", "v1")
    inner = bundle(ctx.root, "inner", "owner/model/v1/nested", "repair")
    parent = self()

    task =
      session_task(fn ->
        Process.put(:import_barrier, {:move_staged_to_dest, parent})

        importer.import_bundle(inner, artifacts_root: ctx.artifacts)
      end)

    assert_receive {:barrier, :move_staged_to_dest, pid}
    assert_receive {:session, ^pid, inner_backend}
    refute File.exists?(Path.join(ctx.artifacts, "owner/model/v1"))

    contender =
      session_task(fn -> Importer.import_bundle(outer, artifacts_root: ctx.artifacts) end)

    contender_pid = contender.pid
    assert_receive {:session, ^contender_pid, outer_backend}
    refute inner_backend == outer_backend

    # The old implementation completes A here; the coordinated implementation
    # waits on B's database lock. Neither ordering relies on a timed sleep.
    observed = await_publication_or_lock(contender, outer_backend, 500)
    send(pid, :continue)
    nested_result = Task.await(task)

    outer_result =
      case observed do
        {:finished, result} -> result
        :waiting -> Task.await(contender)
      end

    rows = Sandbox.unboxed_run(Repo, &Models.list_models/0)

    Enum.each(rows, &assert_digest/1)
    assert Enum.count([outer_result, nested_result], &match?({:ok, _}, &1)) == 1
    assert Enum.count([outer_result, nested_result], &match?({:error, _}, &1)) == 1
    assert Path.wildcard(Path.join(ctx.artifacts, ".staging-*"), match_dot: true) == []
  end

  @tag :unboxed
  test "SPEC 6.5 failed catalog publication cleans up before another importer can publish below it",
       %{instrumented_importer: importer} = ctx do
    source = bundle(ctx.root, "source", "owner/model", "v1")
    parent = self()

    failed =
      session_task(fn ->
        Process.put(:import_barrier, {:stage_bundle, parent})

        importer.import_bundle(source, artifacts_root: ctx.artifacts)
      end)

    assert_receive {:barrier, :stage_bundle, failed_pid}
    assert_receive {:session, ^failed_pid, failed_backend}

    # A concurrent import into another root wins the Catalog identity after the
    # first importer checked for duplicates, forcing insertion-time rollback.
    original_root = Path.join(ctx.root, "original-artifacts")

    assert {:ok, original} =
             Sandbox.unboxed_run(Repo, fn ->
               Importer.import_bundle(source, artifacts_root: original_root)
             end)

    send(failed_pid, {:continue, :cleanup_destination})
    assert_receive {:barrier, :cleanup_destination, ^failed_pid}

    nested = bundle(ctx.root, "nested", "owner/model/v1/nested", "repair")

    contender =
      session_task(fn -> Importer.import_bundle(nested, artifacts_root: ctx.artifacts) end)

    contender_pid = contender.pid
    assert_receive {:session, ^contender_pid, contender_backend}
    refute failed_backend == contender_backend
    observed = await_publication_or_lock(contender, contender_backend, 500)
    send(failed_pid, :continue)

    assert {:error, %Ecto.Changeset{}} = Task.await(failed)

    result =
      case observed do
        {:finished, result} -> result
        :waiting -> Task.await(contender)
      end

    assert {:ok, repaired} = result
    assert_digest(original)
    assert_digest(repaired)
    assert Path.wildcard(Path.join(ctx.artifacts, ".staging-*"), match_dot: true) == []
  end

  @tag :unboxed
  test "SPEC 6.5 public imports contend on the same database publication guard", ctx do
    source = bundle(ctx.root, "source", "owner/model", "v1")
    nested = bundle(ctx.root, "nested", "owner/model/v1/nested", "repair")
    parent = self()

    holder =
      session_task(fn ->
        Repo.transaction(fn ->
          Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
            "orchard:models:artifact-publication"
          ])

          send(parent, :guard_held)

          receive do
            :release -> :ok
          after
            10_000 -> raise "publication guard was not released"
          end
        end)
      end)

    assert_receive :guard_held

    tasks =
      for bundle <- [source, nested] do
        task =
          session_task(fn -> Importer.import_bundle(bundle, artifacts_root: ctx.artifacts) end)

        pid = task.pid
        assert_receive {:session, ^pid, backend}
        assert :waiting == await_publication_or_lock(task, backend, 500)
        task
      end

    send(holder.pid, :release)
    assert {:ok, :ok} = Task.await(holder)
    results = Enum.map(tasks, &Task.await/1)
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, _}, &1)) == 1
    Sandbox.unboxed_run(Repo, fn -> Enum.each(Models.list_models(), &assert_digest/1) end)
    assert Path.wildcard(Path.join(ctx.artifacts, ".staging-*"), match_dot: true) == []
  end

  test "SPEC 6.5 staging uses UUIDs rather than counters local to a controller or CLI VM", ctx do
    source = bundle(ctx.root, "source", "owner/model", "v1")
    task = paused_import(ctx.instrumented_importer, source, ctx.artifacts, :move_staged_to_dest)
    assert_receive {:barrier, :move_staged_to_dest, pid}
    [staged] = Path.wildcard(Path.join(ctx.artifacts, ".staging-*"), match_dot: true)
    suffix = staged |> Path.basename() |> String.replace_prefix(".staging-", "")
    send(pid, :continue)
    assert {:ok, model} = Task.await(task)
    assert {:ok, ^suffix} = Ecto.UUID.cast(suffix)
    assert_digest(model)
  end

  for replacement <- ["v2/nested", "v2"] do
    @replacement replacement
    test "SPEC 6.4 rejects staged identity replacement with #{@replacement}", ctx do
      source = bundle(ctx.root, "source", "owner/model", "v1")
      task = paused_import(ctx.instrumented_importer, source, ctx.artifacts, :stage_bundle)
      assert_receive {:barrier, :stage_bundle, pid}
      path = Path.join(source, "manifest.json")
      manifest = path |> File.read!() |> Jason.decode!()
      File.write!(path, Jason.encode!(Map.put(manifest, "version", @replacement)))
      send(pid, :continue)
      result = Task.await(task)

      observed = %{
        result: result,
        rows: Enum.map(Models.list_models(), &{&1.model_id, &1.version}),
        stored: Path.wildcard(Path.join(ctx.artifacts, "**/manifest.json")),
        staging: Path.wildcard(Path.join(ctx.artifacts, ".staging-*"), match_dot: true)
      }

      assert match?({:error, _}, result)
      assert observed.rows == []
      assert observed.stored == []
      assert observed.staging == []
    end
  end

  test "barrier-free instrumented import stores a complete synthetic bundle with correct digest",
       %{instrumented_importer: importer} = ctx do
    source = bundle(ctx.root, "control", "owner/model", "v1")

    assert {:ok, model} = importer.import_bundle(source, artifacts_root: ctx.artifacts)

    assert model.version == "v1"
    assert_digest(model)
  end

  def barrier(point) do
    case Process.get(:import_barrier) do
      {^point, parent} ->
        send(parent, {:barrier, point, self()})

        receive do
          :continue -> :ok
          {:continue, next_point} -> Process.put(:import_barrier, {next_point, parent})
        after
          10_000 -> raise "investigation barrier was not released"
        end

      _ ->
        :ok
    end
  end

  defp paused_import(importer, source, artifacts, point) do
    parent = self()

    Task.async(fn ->
      Process.put(:import_barrier, {point, parent})

      importer.import_bundle(source, artifacts_root: artifacts)
    end)
  end

  defp session_task(fun) do
    parent = self()

    Task.async(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        [[backend]] = Repo.query!("SELECT pg_backend_pid()").rows
        send(parent, {:session, self(), backend})
        fun.()
      end)
    end)
  end

  defp await_publication_or_lock(_task, _backend, 0),
    do: flunk("import neither published nor waited for its lock")

  defp await_publication_or_lock(task, backend, attempts) do
    case Task.yield(task, 0) do
      {:ok, result} ->
        {:finished, result}

      nil ->
        waiting =
          Sandbox.unboxed_run(Repo, fn ->
            Repo.query!(
              """
              SELECT EXISTS (
                SELECT 1 FROM pg_locks
                WHERE pid = $1 AND locktype = 'advisory' AND NOT granted
              )
              """,
              [backend]
            ).rows
          end)

        if waiting == [[true]] do
          :waiting
        else
          Process.sleep(10)
          await_publication_or_lock(task, backend, attempts - 1)
        end
    end
  end

  defp bundle(root, name, model_id, version) do
    path = Path.join(root, name)
    File.cp_r!(@fixture, path)
    manifest_path = Path.join(path, "manifest.json")
    manifest = manifest_path |> File.read!() |> Jason.decode!()
    manifest = Map.merge(manifest, %{"model_id" => model_id, "version" => version})

    manifest =
      update_in(manifest["safe_tokenization"], fn safe ->
        Map.merge(safe, %{"compatible" => true, "template_compatible" => true})
      end)

    File.write!(manifest_path, Jason.encode!(manifest))
    path
  end

  defp assert_digest(model) do
    path = String.replace_prefix(model.artifact_uri, "file://", "")
    assert {:ok, digest} = ArtifactBundle.tree_sha256(path)
    assert model.artifact_sha256 == digest
  end
end
