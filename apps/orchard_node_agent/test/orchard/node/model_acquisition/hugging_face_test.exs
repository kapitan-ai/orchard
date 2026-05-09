defmodule Orchard.Node.ModelAcquisition.Source.HuggingFaceTest do
  use ExUnit.Case, async: false

  alias Orchard.ArtifactBundle
  alias Orchard.Cluster.V1.EnsureModelLoadedRequest
  alias Orchard.Node.ModelAcquisition
  alias Orchard.Node.ModelAcquisition.Request
  alias Orchard.Node.ModelAcquisition.Source.HuggingFace
  alias Orchard.TestSupport.HuggingFaceReqStub

  @repo_id "mlx-community/test-model"
  @revision "main"

  setup do
    tmp_dir =
      System.tmp_dir!()
      |> Path.join("hf_test_#{:rand.uniform(1_000_000)}")

    models_root = Path.join(tmp_dir, "models")
    source_dir = Path.join(tmp_dir, "source")

    File.mkdir_p!(models_root)
    File.mkdir_p!(source_dir)

    file_contents = HuggingFaceReqStub.sample_file_contents()
    HuggingFaceReqStub.write_files(source_dir, file_contents)

    {:ok, hash} = ArtifactBundle.tree_sha256(source_dir)

    tree_response =
      HuggingFaceReqStub.tree_response(file_contents, [
        %{"type" => "file", "oid" => "abc", "size" => 100, "path" => "README.md"},
        %{"type" => "file", "oid" => "def", "size" => 200, "path" => ".gitattributes"}
      ])

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    # Configure Req.Test stub name and HF config
    stub_name = :"hf_test_#{:rand.uniform(1_000_000)}"

    previous_runtime = Application.get_env(:orchard_node_agent, :runtime, [])
    override_hf_config(stub_name)

    on_exit(fn ->
      Application.put_env(:orchard_node_agent, :runtime, previous_runtime)
    end)

    %{
      tmp_dir: tmp_dir,
      models_root: models_root,
      source_dir: source_dir,
      hash: hash,
      file_contents: file_contents,
      tree_response: tree_response,
      stub_name: stub_name
    }
  end

  describe "parse_hf_uri/1" do
    test "parses org/repo with default revision" do
      assert {:ok, %{repo_id: "mlx-community/phi-3", revision: "main"}} =
               HuggingFace.parse_hf_uri("hf://mlx-community/phi-3")
    end

    test "parses org/repo with explicit revision" do
      assert {:ok, %{repo_id: "mlx-community/phi-3", revision: "v1.0"}} =
               HuggingFace.parse_hf_uri("hf://mlx-community/phi-3?revision=v1.0")
    end

    test "rejects missing repo path" do
      assert {:error, :invalid_source_uri} = HuggingFace.parse_hf_uri("hf://mlx-community")
    end

    test "rejects unknown query params" do
      assert {:error, :invalid_source_uri} =
               HuggingFace.parse_hf_uri("hf://mlx-community/phi-3?branch=dev")
    end

    test "rejects non-hf scheme" do
      assert {:error, :invalid_source_uri} =
               HuggingFace.parse_hf_uri("https://huggingface.co/mlx-community/phi-3")
    end

    test "rejects nil" do
      assert {:error, :invalid_source_uri} = HuggingFace.parse_hf_uri(nil)
    end

    test "rejects blank revision" do
      assert {:error, :invalid_source_uri} =
               HuggingFace.parse_hf_uri("hf://mlx-community/phi-3?revision=")
    end
  end

  describe "filter_and_validate/1" do
    test "retains MLX model files and filters non-model files" do
      entries = [
        %{path: "config.json", size: 100, oid: "a"},
        %{path: "model.safetensors", size: 1000, oid: "b"},
        %{path: "tokenizer.json", size: 200, oid: "c"},
        %{path: "tokenizer.model", size: 300, oid: "d"},
        %{path: "merges.txt", size: 50, oid: "e"},
        %{path: "README.md", size: 100, oid: "f"},
        %{path: ".gitattributes", size: 50, oid: "g"},
        %{path: "model.gguf", size: 5000, oid: "h"}
      ]

      assert {:ok, retained} = HuggingFace.filter_and_validate(entries)
      paths = Enum.map(retained, & &1.path)
      assert "config.json" in paths
      assert "model.safetensors" in paths
      assert "tokenizer.json" in paths
      assert "tokenizer.model" in paths
      assert "merges.txt" in paths
      refute "README.md" in paths
      refute ".gitattributes" in paths
      refute "model.gguf" in paths
    end

    test "rejects empty file list" do
      assert {:error, {:invalid_source_layout, _}} = HuggingFace.filter_and_validate([])
    end

    test "rejects repo with no safetensors (GGUF-only)" do
      entries = [
        %{path: "config.json", size: 100, oid: "a"},
        %{path: "tokenizer.json", size: 200, oid: "b"}
      ]

      assert {:error, {:invalid_source_layout, msg}} =
               HuggingFace.filter_and_validate(entries)

      assert msg =~ "safetensors"
    end
  end

  describe "materialize/1 via ensure_cached" do
    test "downloads HF model into cache and verifies hash", ctx do
      stub_successful_hf(ctx)
      request = build_hf_request(ctx)

      assert {:ok, final_path, :materialized} = ModelAcquisition.ensure_cached(request)
      assert File.dir?(final_path)

      # Verify hash matches source bundle
      expected_hash = ctx.hash
      assert {:ok, ^expected_hash} = ArtifactBundle.tree_sha256(final_path)

      # Verify all expected files exist
      assert File.exists?(Path.join(final_path, "config.json"))
      assert File.exists?(Path.join(final_path, "tokenizer.json"))
      assert File.exists?(Path.join(final_path, "model.safetensors"))

      # Verify non-model files were NOT downloaded
      refute File.exists?(Path.join(final_path, "README.md"))
    end

    test "cache hit bypasses network on second call", ctx do
      stub_successful_hf(ctx)
      request = build_hf_request(ctx)

      # First call materializes
      assert {:ok, _path, :materialized} = ModelAcquisition.ensure_cached(request)

      # Replace stub with one that fails on any call — proves no network
      Req.Test.stub(ctx.stub_name, fn conn ->
        Plug.Conn.send_resp(conn, 500, "should not be called")
      end)

      # Second call uses cache
      assert {:ok, _path, :cache_hit} = ModelAcquisition.ensure_cached(request)
    end

    test "401 from tree API returns source_unauthorized", ctx do
      Req.Test.stub(ctx.stub_name, fn conn ->
        Plug.Conn.send_resp(conn, 401, "Unauthorized")
      end)

      request = build_hf_request(ctx)

      assert {:error, {:source_unauthorized, _}} = ModelAcquisition.ensure_cached(request)
      refute File.exists?(request.final_path)
    end

    test "403 from tree API returns source_unauthorized", ctx do
      Req.Test.stub(ctx.stub_name, fn conn ->
        Plug.Conn.send_resp(conn, 403, "Forbidden")
      end)

      request = build_hf_request(ctx)

      assert {:error, {:source_unauthorized, _}} = ModelAcquisition.ensure_cached(request)
    end

    test "404 from tree API returns source_not_found", ctx do
      Req.Test.stub(ctx.stub_name, fn conn ->
        Plug.Conn.send_resp(conn, 404, "Not Found")
      end)

      request = build_hf_request(ctx)

      assert {:error, {:source_not_found, _}} = ModelAcquisition.ensure_cached(request)
    end

    test "doc-only repo returns invalid_source_layout", ctx do
      install_hf_stub(ctx,
        tree_handler: fn conn, _tree_response ->
          Req.Test.json(conn, [
            %{"type" => "file", "oid" => "abc", "size" => 100, "path" => "README.md"}
          ])
        end
      )

      request = build_hf_request(ctx)

      assert {:error, {:invalid_source_layout, _}} = ModelAcquisition.ensure_cached(request)
    end

    test "resume sends Range header on retry after partial download", ctx do
      call_count = :counters.new(1, [:atomics])

      install_hf_stub(ctx,
        head_handler: fn conn, file_path, content ->
          case content do
            nil ->
              Plug.Conn.send_resp(conn, 404, "")

            content ->
              conn
              |> Plug.Conn.put_resp_header("content-length", to_string(byte_size(content)))
              |> Plug.Conn.put_resp_header("etag", "\"test-etag-#{file_path}\"")
              |> Plug.Conn.send_resp(200, "")
          end
        end,
        download_handler: fn conn, file_path, content ->
          if file_path == "model.safetensors" do
            :counters.add(call_count, 1, 1)
            content = content || ""

            if :counters.get(call_count, 1) == 1 do
              partial = binary_part(content, 0, div(byte_size(content), 2))

              conn
              |> Plug.Conn.put_resp_header("content-length", to_string(byte_size(content)))
              |> Plug.Conn.send_resp(200, partial)
            else
              HuggingFaceReqStub.resume_download(conn, content)
            end
          else
            :default
          end
        end
      )

      current_runtime = Application.get_env(:orchard_node_agent, :runtime, [])
      hf_config = Keyword.merge(current_runtime[:hf] || [], retry_attempts: 3)

      Application.put_env(
        :orchard_node_agent,
        :runtime,
        Keyword.put(current_runtime, :hf, hf_config)
      )

      request = build_hf_request(ctx)

      assert {:ok, final_path, :materialized} = ModelAcquisition.ensure_cached(request)

      expected_hash = ctx.hash
      assert {:ok, ^expected_hash} = ArtifactBundle.tree_sha256(final_path)
      assert :counters.get(call_count, 1) >= 2
    end

    test "hash mismatch does not promote staging directory", ctx do
      stub_successful_hf(ctx)
      request = build_hf_request(ctx, artifact_sha256: String.duplicate("0", 64))

      assert {:error, :artifact_hash_mismatch} = ModelAcquisition.ensure_cached(request)
      refute File.exists?(request.final_path)
      refute File.exists?(request.staging_path)
    end

    test "progress telemetry is emitted", ctx do
      stub_successful_hf(ctx)
      request = build_hf_request(ctx)

      # Attach telemetry handler
      test_pid = self()
      handler_id = "test-progress-#{System.unique_integer()}"

      :telemetry.attach(
        handler_id,
        [:orchard, :node, :model_acquisition, :progress],
        fn event_name, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event_name, measurements, metadata})
        end,
        nil
      )

      assert {:ok, _path, :materialized} = ModelAcquisition.ensure_cached(request)

      # Should receive at least one progress event
      assert_received {:telemetry, [:orchard, :node, :model_acquisition, :progress], measurements,
                       metadata}

      assert measurements.files_completed > 0
      assert measurements.total_files > 0
      assert metadata.source_scheme == "hf"
      assert metadata.model_id == "test-org/model"

      :telemetry.detach(handler_id)
    end
  end

  describe "sanitize_entry_paths/1" do
    test "accepts clean relative paths" do
      entries = [
        %{path: "config.json", size: 100, oid: "a"},
        %{path: "model.safetensors", size: 1000, oid: "b"},
        %{path: "subdir/weights.safetensors", size: 2000, oid: "c"}
      ]

      assert {:ok, ^entries} = HuggingFace.sanitize_entry_paths(entries)
    end

    test "rejects path traversal with .." do
      entries = [
        %{path: "config.json", size: 100, oid: "a"},
        %{path: "../evil.json", size: 50, oid: "b"},
        %{path: "model.safetensors", size: 1000, oid: "c"}
      ]

      assert {:error, {:invalid_source_layout, msg}} =
               HuggingFace.sanitize_entry_paths(entries)

      assert msg =~ "path traversal"
      assert msg =~ "../evil.json"
    end

    test "rejects nested path traversal" do
      entries = [
        %{path: "weights/../../../etc/passwd", size: 100, oid: "a"}
      ]

      assert {:error, {:invalid_source_layout, msg}} =
               HuggingFace.sanitize_entry_paths(entries)

      assert msg =~ "path traversal"
    end

    test "rejects absolute paths" do
      entries = [
        %{path: "/etc/passwd", size: 100, oid: "a"}
      ]

      assert {:error, {:invalid_source_layout, msg}} =
               HuggingFace.sanitize_entry_paths(entries)

      assert msg =~ "absolute path"
    end
  end

  describe "path traversal integration" do
    test "materialize rejects tree entry with path traversal", ctx do
      tree_with_traversal = [
        %{"type" => "file", "oid" => "aaa", "size" => 100, "path" => "config.json"},
        %{"type" => "file", "oid" => "bbb", "size" => 1000, "path" => "model.safetensors"},
        %{"type" => "file", "oid" => "ccc", "size" => 50, "path" => "../evil.json"}
      ]

      install_hf_stub(ctx,
        tree_handler: fn conn, _tree_response ->
          Req.Test.json(conn, tree_with_traversal)
        end
      )

      request = build_hf_request(ctx)

      assert {:error, {:invalid_source_layout, msg}} =
               ModelAcquisition.ensure_cached(request)

      assert msg =~ "path traversal"
    end
  end

  describe "resume on 200 (server ignores Range)" do
    test "retries from scratch when server returns 200 instead of 206", ctx do
      safetensors_get_count = :counters.new(1, [:atomics])

      install_hf_stub(ctx,
        head_handler: fn conn, file_path, content ->
          case content do
            nil ->
              Plug.Conn.send_resp(conn, 404, "")

            content ->
              conn
              |> Plug.Conn.put_resp_header("content-length", to_string(byte_size(content)))
              |> Plug.Conn.put_resp_header("etag", "\"test-etag-#{file_path}\"")
              |> Plug.Conn.send_resp(200, "")
          end
        end,
        download_handler: fn conn, file_path, content ->
          if file_path == "model.safetensors" do
            :counters.add(safetensors_get_count, 1, 1)
            content = content || ""

            if :counters.get(safetensors_get_count, 1) == 1 do
              partial = binary_part(content, 0, div(byte_size(content), 2))

              conn
              |> Plug.Conn.put_resp_header("content-length", to_string(byte_size(content)))
              |> Plug.Conn.send_resp(200, partial)
            else
              conn
              |> Plug.Conn.put_resp_header("content-length", to_string(byte_size(content)))
              |> Plug.Conn.send_resp(200, content)
            end
          else
            :default
          end
        end
      )

      current_runtime = Application.get_env(:orchard_node_agent, :runtime, [])
      hf_config = Keyword.merge(current_runtime[:hf] || [], retry_attempts: 5)

      Application.put_env(
        :orchard_node_agent,
        :runtime,
        Keyword.put(current_runtime, :hf, hf_config)
      )

      request = build_hf_request(ctx)

      assert {:ok, final_path, :materialized} = ModelAcquisition.ensure_cached(request)

      expected_hash = ctx.hash
      assert {:ok, ^expected_hash} = ArtifactBundle.tree_sha256(final_path)
      assert :counters.get(safetensors_get_count, 1) >= 3
    end
  end

  describe "URI encoding" do
    test "parse_hf_uri accepts revision with slashes" do
      assert {:ok, %{repo_id: "mlx-community/phi-3", revision: "refs/pr/1"}} =
               HuggingFace.parse_hf_uri("hf://mlx-community/phi-3?revision=refs/pr/1")
    end
  end

  describe "redirect-safe download" do
    test "small redirected file downloads successfully", ctx do
      redirect_files = MapSet.new(["config.json"])
      install_hf_stub(ctx, redirect_files: redirect_files)

      request = build_hf_request(ctx)
      assert {:ok, final_path, :materialized} = ModelAcquisition.ensure_cached(request)

      config_path = Path.join(final_path, "config.json")
      assert File.exists?(config_path)
      assert File.read!(config_path) == ctx.file_contents["config.json"]
    end

    test "stale partial file triggers 416 recovery", ctx do
      install_hf_stub(ctx, redirect_files: MapSet.new())

      request = build_hf_request(ctx)

      # Pre-create an oversized .partial in the staging path
      staging_path = request.staging_path
      File.mkdir_p!(staging_path)
      content = ctx.file_contents["config.json"]
      real_etag = Orchard.TestSupport.HuggingFaceReqStub.hash_content(content)

      File.write!(
        Path.join(staging_path, "config.json.partial"),
        String.duplicate("x", byte_size(content) + 500)
      )

      File.write!(Path.join(staging_path, "config.json.partial.etag"), real_etag)

      assert {:ok, final_path, :materialized} = ModelAcquisition.ensure_cached(request)

      config_path = Path.join(final_path, "config.json")
      assert File.read!(config_path) == content
    end

    test "auth suppressed on cross-origin CDN redirect", ctx do
      redirect_files = MapSet.new(["config.json"])
      test_pid = self()

      on_request = fn conn ->
        auth =
          Enum.find_value(conn.req_headers, fn
            {"authorization", val} -> val
            _ -> nil
          end)

        send(test_pid, {:request, conn.host, conn.method, auth})
      end

      install_hf_stub(ctx, redirect_files: redirect_files, on_request: on_request)

      current_runtime = Application.get_env(:orchard_node_agent, :runtime, [])
      current_hf = Keyword.get(current_runtime, :hf, [])
      updated_hf = Keyword.put(current_hf, :token, "hf_node_secret")

      Application.put_env(
        :orchard_node_agent,
        :runtime,
        Keyword.put(current_runtime, :hf, updated_hf)
      )

      request = build_hf_request(ctx)
      assert {:ok, _, :materialized} = ModelAcquisition.ensure_cached(request)

      # Restore
      Application.put_env(
        :orchard_node_agent,
        :runtime,
        Keyword.put(current_runtime, :hf, current_hf)
      )

      messages = collect_request_messages()
      cdn_requests = Enum.filter(messages, fn {host, _, _} -> host == "cdn.test" end)
      assert cdn_requests != []
      assert Enum.all?(cdn_requests, fn {_, _, auth} -> auth == nil end)
    end
  end

  # -- Helpers ---------------------------------------------------------------

  defp collect_request_messages(acc \\ []) do
    receive do
      {:request, host, method, auth} -> collect_request_messages([{host, method, auth} | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end

  defp build_hf_request(ctx, overrides \\ []) do
    proto = %EnsureModelLoadedRequest{
      node_id: "node-local",
      model_id: "test-org/model",
      version: "v1",
      artifact_sha256: Keyword.get(overrides, :artifact_sha256, ctx.hash),
      preload: true,
      deadline_unix_ms: System.system_time(:millisecond) + 30_000,
      artifact_source_uri: "hf://#{@repo_id}?revision=#{@revision}"
    }

    {:ok, request} = Request.from_proto(proto, ctx.models_root)
    request
  end

  defp install_hf_stub(ctx, opts \\ []) do
    install_hf_stub(ctx.stub_name, ctx.file_contents, ctx.tree_response, opts)
  end

  defp install_hf_stub(stub_name, file_contents, tree_response, opts) do
    HuggingFaceReqStub.install(stub_name, file_contents, tree_response, opts)
  end

  defp stub_successful_hf(ctx) do
    install_hf_stub(ctx)
  end

  defp override_hf_config(stub_name) do
    current_runtime = Application.get_env(:orchard_node_agent, :runtime, [])
    updated_runtime = Keyword.put(current_runtime, :hf, HuggingFaceReqStub.hf_config(stub_name))
    Application.put_env(:orchard_node_agent, :runtime, updated_runtime)
  end
end
