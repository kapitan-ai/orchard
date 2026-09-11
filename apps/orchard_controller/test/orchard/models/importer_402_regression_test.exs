defmodule Orchard.Models.Importer402RegressionTest do
  use Orchard.DataCase, async: false

  alias Orchard.ArtifactBundle
  alias Orchard.Models
  alias Orchard.Models.Importer

  @fixture Path.expand("../../fixtures/bundles/test-model-bundle", __DIR__)

  # Investigation-only copy of the exact production AST. The only inserted code
  # is a message barrier before staging or after destination validation. All
  # validation, filesystem operations and catalog calls remain the real code.
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
              Orchard.Models.Importer402RegressionTest.barrier(unquote(name))
              unquote(body)
            end

          {:defp, meta, [head, [do: body]]}

        other ->
          other
      end)

    Code.compile_quoted(ast, source)
    :ok
  end

  setup do
    root = Path.join(System.tmp_dir!(), "orchard-402-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, artifacts: Path.join(root, "artifacts")}
  end

  test "SPEC 6.4/6.5 concurrent overlapping imports preserve every catalog digest", ctx do
    outer = bundle(ctx.root, "outer", "owner/model", "v1")
    inner = bundle(ctx.root, "inner", "owner/model/v1/nested", "repair")
    task = paused_import(inner, ctx.artifacts, :move_staged_to_dest)
    assert_receive {:barrier, :move_staged_to_dest, pid}
    refute File.exists?(Path.join(ctx.artifacts, "owner/model/v1"))

    assert {:ok, original} = Importer.import_bundle(outer, artifacts_root: ctx.artifacts)
    assert_digest(original)
    send(pid, :continue)
    nested_result = Task.await(task)
    rows = Models.list_models()
    IO.inspect({nested_result, Enum.map(rows, &{&1.model_id, &1.version})}, label: "P1 outcome")

    # Re-read the surviving rows, not just the return values from import.
    Enum.each(rows, &assert_digest/1)
    assert match?({:error, _}, nested_result)
    assert Path.wildcard(Path.join(ctx.artifacts, ".staging-*")) == []
  end

  for replacement <- ["v2/nested", "v2"] do
    @replacement replacement
    test "SPEC 6.4 rejects staged identity replacement with #{@replacement}", ctx do
      source = bundle(ctx.root, "source", "owner/model", "v1")
      task = paused_import(source, ctx.artifacts, :stage_bundle)
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
        staging: Path.wildcard(Path.join(ctx.artifacts, ".staging-*"))
      }

      IO.inspect(observed, label: "P2 staged identity #{@replacement}")
      assert match?({:error, _}, result)
      assert observed.rows == []
      assert observed.stored == []
      assert observed.staging == []
    end
  end

  test "barrier-free instrumented import stores a complete synthetic bundle with correct digest",
       ctx do
    source = bundle(ctx.root, "control", "owner/model", "v1")

    assert {:ok, model} =
             apply(Orchard.Models.Importer402Instrumented, :import_bundle, [
               source,
               [artifacts_root: ctx.artifacts]
             ])

    assert model.version == "v1"
    assert_digest(model)
  end

  def barrier(point) do
    case Process.get(:import_barrier) do
      {^point, parent} ->
        send(parent, {:barrier, point, self()})

        receive do
          :continue -> :ok
        after
          10_000 -> raise "investigation barrier was not released"
        end

      _ ->
        :ok
    end
  end

  defp paused_import(source, artifacts, point) do
    parent = self()

    Task.async(fn ->
      Process.put(:import_barrier, {point, parent})

      apply(Orchard.Models.Importer402Instrumented, :import_bundle, [
        source,
        [artifacts_root: artifacts]
      ])
    end)
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
