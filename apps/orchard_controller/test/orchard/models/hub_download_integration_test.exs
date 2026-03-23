defmodule Orchard.Models.HubDownloadIntegrationTest do
  @moduledoc """
  Integration test for the full HF download → bundle build → import pipeline.

  Exercises `OrchardConsole.ModelHub.start_download_import/4` end-to-end with
  real production modules, stubbing only HF HTTP via `Req.Test`.
  """
  use Orchard.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Orchard.Models
  alias Orchard.Models.{Importer, ManifestParser}
  alias OrchardConsole.ModelHub

  @repo_id "integration-test/mlx-model-#{System.unique_integer([:positive])}"
  @revision_sha "abc#{:crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)}"
  @stub_name __MODULE__.ReqStub

  # Fixture file contents
  @config_json Jason.encode!(%{
                 "model_type" => "llama",
                 "architectures" => ["LlamaForCausalLM"],
                 "max_position_embeddings" => 4096
               })

  @tokenizer_json Jason.encode!(%{"version" => "1.0", "model" => %{"type" => "BPE"}})

  @chat_template_content "{% for msg in messages %}{{ msg.content }}{% endfor %}"

  @tokenizer_config_json Jason.encode!(%{
                           "chat_template" => @chat_template_content,
                           "bos_token" => "<s>",
                           "eos_token" => "</s>"
                         })

  @model_safetensors :crypto.strong_rand_bytes(64)

  # File map: name → {content, in_allowlist?}
  @hf_files %{
    "config.json" => {@config_json, true},
    "tokenizer.json" => {@tokenizer_json, true},
    "tokenizer_config.json" => {@tokenizer_config_json, true},
    "model.safetensors" => {@model_safetensors, true},
    "README.md" => {"# Test model", false}
  }

  @allowlisted_files @hf_files
                     |> Enum.filter(fn {_name, {_content, allowed}} -> allowed end)
                     |> Enum.map(fn {name, _} -> name end)
                     |> Enum.sort()

  @total_bytes @hf_files
               |> Enum.filter(fn {_name, {_content, allowed}} -> allowed end)
               |> Enum.map(fn {_name, {content, _}} -> byte_size(content) end)
               |> Enum.sum()

  setup do
    # DB sandbox: shared mode so spawned task can access the repo
    Sandbox.mode(Orchard.Repo, {:shared, self()})

    # Unique artifacts root per test
    artifacts_root =
      Path.join(System.tmp_dir!(), "orchard-integ-#{System.unique_integer([:positive])}")

    File.mkdir_p!(artifacts_root)

    # Snapshot configs
    prev_console = Application.get_env(:orchard_controller, :console, [])
    prev_hf = Application.get_env(:orchard_controller, :hf, [])
    prev_inference = Application.get_env(:orchard_controller, :inference, [])

    # Force real modules (override test defaults that might use stubs)
    Application.put_env(
      :orchard_controller,
      :console,
      Keyword.merge(prev_console,
        model_hub_impl: OrchardConsole.ModelHub,
        model_hub_client_impl: Orchard.Models.HubClient,
        model_hub_download_impl: Orchard.Models.HubDownloader
      )
    )

    # Inject Req.Test plug into HF config
    Application.put_env(
      :orchard_controller,
      :hf,
      Keyword.merge(prev_hf,
        retry_attempts: 0,
        req_options: [plug: {Req.Test, @stub_name}]
      )
    )

    # Override artifacts root only
    Application.put_env(
      :orchard_controller,
      :inference,
      Keyword.merge(prev_inference, artifacts_root: artifacts_root)
    )

    # Register Req.Test stubs
    Req.Test.stub(@stub_name, &handle_hf_request/1)

    on_exit(fn ->
      Application.put_env(:orchard_controller, :console, prev_console)
      Application.put_env(:orchard_controller, :hf, prev_hf)
      Application.put_env(:orchard_controller, :inference, prev_inference)
      File.rm_rf!(artifacts_root)
    end)

    %{artifacts_root: artifacts_root}
  end

  describe "end-to-end download pipeline" do
    test "downloads, builds bundle, imports as active, and streams ordered messages",
         %{artifacts_root: artifacts_root} do
      ref = make_ref()

      assert {:ok, pid} =
               ModelHub.start_download_import(self(), ref, @repo_id, activate: true)

      assert is_pid(pid)

      # Collect all messages for this ref until terminal
      messages = collect_messages(ref, [])

      # 1. Exactly one :download_started
      started_msgs = Enum.filter(messages, &match?({:model_hub, _, :download_started, _}, &1))
      assert length(started_msgs) == 1

      {:model_hub, ^ref, :download_started, started} = hd(started_msgs)
      assert started.repo_id == @repo_id
      assert started.revision == @revision_sha
      assert started.total_files == length(@allowlisted_files)
      assert started.total_bytes == @total_bytes

      # 2. Progress messages with correct phases
      progress_msgs = Enum.filter(messages, &match?({:model_hub, _, :download_progress, _}, &1))
      phases = Enum.map(progress_msgs, fn {:model_hub, _, :download_progress, p} -> p.phase end)

      # Must have downloading phase(s), then preparing_bundle, then importing
      downloading_phases = Enum.filter(phases, &(&1 == :downloading))
      assert downloading_phases != [], "Expected at least one :downloading phase"

      # Preparing and importing appear after downloading
      last_downloading_idx =
        phases
        |> Enum.with_index()
        |> Enum.filter(fn {p, _} -> p == :downloading end)
        |> List.last()
        |> elem(1)

      preparing_idx =
        phases
        |> Enum.find_index(&(&1 == :preparing_bundle))

      importing_idx =
        phases
        |> Enum.find_index(&(&1 == :importing))

      assert preparing_idx != nil, "Expected :preparing_bundle phase in progress messages"
      assert importing_idx != nil, "Expected :importing phase in progress messages"
      assert preparing_idx > last_downloading_idx
      assert importing_idx > preparing_idx

      # 3. Exactly one :download_finished with {:ok, result}
      finished_msgs = Enum.filter(messages, &match?({:model_hub, _, :download_finished, _}, &1))
      assert length(finished_msgs) == 1

      {:model_hub, ^ref, :download_finished, {:ok, result}} = hd(finished_msgs)
      assert result.model_id == @repo_id
      assert result.version == @revision_sha
      assert result.state == :active

      # No duplicate terminal
      refute_receive {:model_hub, ^ref, :download_finished, _}, 200

      # 4. DB assertions: model exists and is active
      model = Models.get_model_by_identity(@repo_id, @revision_sha)
      assert model != nil, "Expected model to be in DB after import"
      assert model.state == :active
      assert model.format == "mlx"
      assert model.max_context_tokens == 4096
      assert is_binary(model.artifact_sha256)
      assert byte_size(model.artifact_sha256) == 64

      active_models = Models.list_active_models()
      assert Enum.any?(active_models, &(&1.model_id == @repo_id and &1.version == @revision_sha))

      # 5. Artifact bundle assertions
      artifact_dir = Importer.artifact_destination_path(artifacts_root, @repo_id, @revision_sha)
      assert File.dir?(artifact_dir), "Expected artifact directory at #{artifact_dir}"

      # Required files present
      for file <- [
            "manifest.json",
            "config.json",
            "tokenizer.json",
            "tokenizer_config.json",
            "model.safetensors",
            "chat_template.jinja"
          ] do
        assert File.exists?(Path.join(artifact_dir, file)),
               "Expected #{file} in artifact bundle"
      end

      # Filtered file absent
      refute File.exists?(Path.join(artifact_dir, "README.md")),
             "README.md should have been filtered by allowlist"

      # 6. Manifest validation
      {:ok, manifest} = ManifestParser.parse_from_bundle(artifact_dir)
      assert manifest.model_id == @repo_id
      assert manifest.version == @revision_sha
      assert manifest.format == "mlx"
      assert manifest.artifact_layout == "directory"
      assert manifest.entrypoint == "."
      assert "chat" in manifest.capabilities
      assert manifest.chat_template.path == "chat_template.jinja"
      assert is_binary(manifest.chat_template.sha256)
      assert manifest.tokenizer.path == "tokenizer.json"

      # 7. Generated chat template matches source
      generated_template = File.read!(Path.join(artifact_dir, "chat_template.jinja"))
      assert generated_template == @chat_template_content
    end
  end

  # ---------------------------------------------------------------------------
  # Req.Test stub handler
  # ---------------------------------------------------------------------------

  defp handle_hf_request(%Plug.Conn{} = conn) do
    case classify_hf_route(conn.method, conn.request_path) do
      :detail -> detail_response(conn)
      :tree -> tree_response(conn)
      :head_preflight -> head_response(conn)
      :file_download -> get_file_response(conn)
      :unknown -> Req.Test.json(Plug.Conn.put_status(conn, 404), %{"error" => "not found"})
    end
  end

  defp classify_hf_route("GET", "/api/models/" <> rest) do
    if String.contains?(rest, "/tree/"), do: :tree, else: :detail
  end

  defp classify_hf_route("HEAD", path) do
    if String.contains?(path, "/resolve/"), do: :head_preflight, else: :unknown
  end

  defp classify_hf_route("GET", path) do
    if String.contains?(path, "/resolve/"), do: :file_download, else: :unknown
  end

  defp classify_hf_route(_method, _path), do: :unknown

  defp detail_response(conn) do
    siblings =
      Enum.map(@hf_files, fn {name, {content, _}} ->
        %{"rfilename" => name, "size" => byte_size(content)}
      end)

    Req.Test.json(conn, %{
      "id" => @repo_id,
      "sha" => @revision_sha,
      "author" => "integration-test",
      "downloads" => 100,
      "likes" => 10,
      "tags" => ["mlx", "text-generation"],
      "pipeline_tag" => "text-generation",
      "library_name" => "transformers",
      "gated" => false,
      "siblings" => siblings,
      "lastModified" => "2026-03-23T00:00:00Z",
      "cardData" => %{"license" => "mit", "language" => ["en"]},
      "config" => %{
        "model_type" => "llama",
        "architectures" => ["LlamaForCausalLM"]
      }
    })
  end

  defp tree_response(conn) do
    tree =
      Enum.map(@hf_files, fn {name, {content, _}} ->
        %{
          "type" => "file",
          "oid" => Base.encode16(:crypto.hash(:sha256, content), case: :lower),
          "size" => byte_size(content),
          "path" => name
        }
      end)

    Req.Test.json(conn, tree)
  end

  defp head_response(conn) do
    file_name = extract_file_path(conn.request_path)

    case Map.get(@hf_files, file_name) do
      {content, _} ->
        conn
        |> Plug.Conn.put_resp_header("content-length", Integer.to_string(byte_size(content)))
        |> Plug.Conn.put_resp_header("etag", "\"etag-#{file_name}\"")
        |> Plug.Conn.send_resp(200, "")

      nil ->
        Plug.Conn.send_resp(conn, 404, "")
    end
  end

  defp get_file_response(conn) do
    file_name = extract_file_path(conn.request_path)

    case Map.get(@hf_files, file_name) do
      {content, _} ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/octet-stream")
        |> Plug.Conn.put_resp_header("etag", "\"etag-#{file_name}\"")
        |> Plug.Conn.send_resp(200, content)

      nil ->
        Plug.Conn.send_resp(conn, 404, "")
    end
  end

  defp extract_file_path(request_path) do
    # Paths like /org/repo/resolve/revision/filename.ext
    case String.split(request_path, "/resolve/#{@revision_sha}/") do
      [_prefix, file_path] -> file_path
      _ -> ""
    end
  end

  # ---------------------------------------------------------------------------
  # Message collection
  # ---------------------------------------------------------------------------

  defp collect_messages(ref, acc) do
    receive do
      {:model_hub, ^ref, :download_finished, _} = msg ->
        Enum.reverse([msg | acc])

      {:model_hub, ^ref, _kind, _payload} = msg ->
        collect_messages(ref, [msg | acc])
    after
      30_000 ->
        flunk(
          "Timed out waiting for :download_finished. " <>
            "Collected #{length(acc)} messages so far: #{inspect(acc, pretty: true, limit: 5)}"
        )
    end
  end
end
