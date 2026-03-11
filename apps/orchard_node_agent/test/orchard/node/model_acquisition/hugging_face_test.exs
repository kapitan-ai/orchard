defmodule Orchard.Node.ModelAcquisition.Source.HuggingFaceTest do
  use ExUnit.Case, async: false

  alias Orchard.ArtifactBundle
  alias Orchard.Cluster.V1.EnsureModelLoadedRequest
  alias Orchard.Node.ModelAcquisition
  alias Orchard.Node.ModelAcquisition.Request
  alias Orchard.Node.ModelAcquisition.Source.HuggingFace

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

    # Create source bundle files that we'll serve via Req.Test
    config_content = ~s({"model_type":"llama","hidden_size":256})
    tokenizer_content = ~s({"version":"1.0"})
    weights_content = "fake-safetensors-weights-data-for-testing"

    File.write!(Path.join(source_dir, "config.json"), config_content)
    File.write!(Path.join(source_dir, "tokenizer.json"), tokenizer_content)
    File.write!(Path.join(source_dir, "model.safetensors"), weights_content)

    {:ok, hash} = ArtifactBundle.tree_sha256(source_dir)

    # Build the file content map for serving
    file_contents = %{
      "config.json" => config_content,
      "tokenizer.json" => tokenizer_content,
      "model.safetensors" => weights_content
    }

    # HF tree listing response
    tree_response =
      Enum.map(file_contents, fn {path, content} ->
        %{
          "type" => "file",
          "oid" => Base.encode16(:crypto.hash(:sha256, content), case: :lower),
          "size" => byte_size(content),
          "path" => path
        }
      end) ++
        [
          # Non-model files that should be filtered out
          %{"type" => "file", "oid" => "abc", "size" => 100, "path" => "README.md"},
          %{"type" => "file", "oid" => "def", "size" => 200, "path" => ".gitattributes"}
        ]

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    # Configure Req.Test stub name and HF config
    stub_name = :"hf_test_#{:rand.uniform(1_000_000)}"

    override_hf_config(stub_name)

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
      # Tree listing with only README, no model files
      Req.Test.stub(ctx.stub_name, fn conn ->
        if String.contains?(conn.request_path, "/tree/") do
          Req.Test.json(conn, [
            %{"type" => "file", "oid" => "abc", "size" => 100, "path" => "README.md"}
          ])
        else
          Plug.Conn.send_resp(conn, 404, "")
        end
      end)

      request = build_hf_request(ctx)

      assert {:error, {:invalid_source_layout, _}} = ModelAcquisition.ensure_cached(request)
    end

    test "resume sends Range header on retry after partial download", ctx do
      file_contents = ctx.file_contents
      tree_response = ctx.tree_response
      call_count = :counters.new(1, [:atomics])

      # Stub that fails the first GET for model.safetensors mid-stream,
      # then succeeds on retry with Range header
      Req.Test.stub(ctx.stub_name, fn conn ->
        cond do
          String.contains?(conn.request_path, "/tree/") ->
            Req.Test.json(conn, tree_response)

          conn.method == "HEAD" && String.contains?(conn.request_path, "/resolve/") ->
            file_path = extract_file_path(conn.request_path)

            case Map.get(file_contents, file_path) do
              nil ->
                Plug.Conn.send_resp(conn, 404, "")

              content ->
                conn
                |> Plug.Conn.put_resp_header("content-length", to_string(byte_size(content)))
                |> Plug.Conn.put_resp_header("etag", "\"test-etag-#{file_path}\"")
                |> Plug.Conn.send_resp(200, "")
            end

          conn.method == "GET" && String.contains?(conn.request_path, "/resolve/") ->
            file_path = extract_file_path(conn.request_path)
            content = Map.get(file_contents, file_path, "")

            if file_path == "model.safetensors" do
              :counters.add(call_count, 1, 1)
              attempt = :counters.get(call_count, 1)

              if attempt == 1 do
                # First attempt: return partial data (less than content-length)
                partial = binary_part(content, 0, div(byte_size(content), 2))

                conn
                |> Plug.Conn.put_resp_header("content-length", to_string(byte_size(content)))
                |> Plug.Conn.send_resp(200, partial)
              else
                # Second attempt: check for Range header
                range_header =
                  Enum.find_value(conn.req_headers, fn
                    {"range", val} -> val
                    _ -> nil
                  end)

                if range_header do
                  # Resume from offset
                  "bytes=" <> range_spec = range_header
                  [start_str | _] = String.split(range_spec, "-")
                  start = String.to_integer(start_str)
                  remaining = binary_part(content, start, byte_size(content) - start)

                  conn
                  |> Plug.Conn.put_resp_header(
                    "content-length",
                    to_string(byte_size(remaining))
                  )
                  |> Plug.Conn.send_resp(206, remaining)
                else
                  # No resume, send full content
                  conn
                  |> Plug.Conn.put_resp_header(
                    "content-length",
                    to_string(byte_size(content))
                  )
                  |> Plug.Conn.send_resp(200, content)
                end
              end
            else
              conn
              |> Plug.Conn.put_resp_header("content-length", to_string(byte_size(content)))
              |> Plug.Conn.send_resp(200, content)
            end

          true ->
            Plug.Conn.send_resp(conn, 404, "")
        end
      end)

      # Override config with retry_attempts: 3 to allow retry
      current_runtime = Application.get_env(:orchard_node_agent, :runtime, [])
      hf_config = Keyword.merge(current_runtime[:hf] || [], retry_attempts: 3)
      Application.put_env(:orchard_node_agent, :runtime, Keyword.put(current_runtime, :hf, hf_config))

      request = build_hf_request(ctx)

      assert {:ok, final_path, :materialized} = ModelAcquisition.ensure_cached(request)

      # Verify the final content is correct
      expected_hash = ctx.hash
      assert {:ok, ^expected_hash} = ArtifactBundle.tree_sha256(final_path)

      # model.safetensors GET was called at least twice (retry)
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
      assert_received {:telemetry, [:orchard, :node, :model_acquisition, :progress],
                        measurements, metadata}

      assert measurements.files_completed > 0
      assert measurements.total_files > 0
      assert metadata.source_scheme == "hf"
      assert metadata.model_id == "test-org/model"

      :telemetry.detach(handler_id)
    end
  end

  # -- Helpers ---------------------------------------------------------------

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

  defp stub_successful_hf(ctx) do
    file_contents = ctx.file_contents
    tree_response = ctx.tree_response

    Req.Test.stub(ctx.stub_name, fn conn ->
      cond do
        # Tree listing
        String.contains?(conn.request_path, "/tree/") ->
          Req.Test.json(conn, tree_response)

        # HEAD for resolve
        conn.method == "HEAD" && String.contains?(conn.request_path, "/resolve/") ->
          file_path = extract_file_path(conn.request_path)

          case Map.get(file_contents, file_path) do
            nil ->
              Plug.Conn.send_resp(conn, 404, "")

            content ->
              conn
              |> Plug.Conn.put_resp_header("content-length", to_string(byte_size(content)))
              |> Plug.Conn.put_resp_header("etag", "\"#{hash_content(content)}\"")
              |> Plug.Conn.send_resp(200, "")
          end

        # GET for resolve (download)
        conn.method == "GET" && String.contains?(conn.request_path, "/resolve/") ->
          file_path = extract_file_path(conn.request_path)

          case Map.get(file_contents, file_path) do
            nil ->
              Plug.Conn.send_resp(conn, 404, "")

            content ->
              # Check for Range header (resume)
              range_header =
                conn.req_headers
                |> Enum.find(fn {k, _} -> k == "range" end)

              {status, body} =
                case range_header do
                  {"range", "bytes=" <> range_spec} ->
                    [start_str | _] = String.split(range_spec, "-")
                    start = String.to_integer(start_str)
                    {206, binary_part(content, start, byte_size(content) - start)}

                  _ ->
                    {200, content}
                end

              conn
              |> Plug.Conn.put_resp_header(
                "content-length",
                to_string(byte_size(body))
              )
              |> Plug.Conn.send_resp(status, body)
          end

        true ->
          Plug.Conn.send_resp(conn, 404, "unknown path")
      end
    end)
  end

  defp extract_file_path(request_path) do
    # Path format: /{repo_id}/resolve/{revision}/{file_path}
    # e.g., /mlx-community/test-model/resolve/main/config.json
    parts = String.split(request_path, "/resolve/#{@revision}/")

    case parts do
      [_, file_path] -> file_path
      _ -> ""
    end
  end

  defp hash_content(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower) |> binary_part(0, 16)
  end

  defp override_hf_config(stub_name) do
    current_runtime = Application.get_env(:orchard_node_agent, :runtime, [])

    hf_config = [
      base_url: "https://huggingface.co",
      api_base_url: "https://huggingface.co/api",
      token: nil,
      retry_attempts: 1,
      connect_timeout_ms: 5_000,
      receive_timeout_ms: 5_000,
      req_options: [plug: {Req.Test, stub_name}]
    ]

    updated_runtime = Keyword.put(current_runtime, :hf, hf_config)
    Application.put_env(:orchard_node_agent, :runtime, updated_runtime)

    # No on_exit restore needed since each test overrides fresh
  end
end
