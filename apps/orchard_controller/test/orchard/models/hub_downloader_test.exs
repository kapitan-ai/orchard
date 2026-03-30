defmodule Orchard.Models.HubDownloaderTest do
  use ExUnit.Case, async: false

  Module.register_attribute(__MODULE__, :no_clone, persist: true)

  alias Orchard.Models.HubDownloader
  alias Orchard.TestSupport.HuggingFaceReqStub

  @repo_id "mlx-community/test-model"
  @revision "main"

  setup do
    previous_hf = Application.get_env(:orchard_controller, :hf, [])
    stub_name = :"hub_dl_test_#{:rand.uniform(1_000_000)}"

    tmp_dir =
      System.tmp_dir!()
      |> Path.join("hub_dl_test_#{:rand.uniform(1_000_000)}")

    dest_dir = Path.join(tmp_dir, "download")
    File.mkdir_p!(dest_dir)

    file_contents = HuggingFaceReqStub.sample_file_contents()

    tree_response =
      HuggingFaceReqStub.tree_response(file_contents, [
        %{"type" => "file", "oid" => "abc", "size" => 100, "path" => "README.md"},
        %{"type" => "file", "oid" => "def", "size" => 200, "path" => ".gitattributes"},
        %{"type" => "file", "oid" => "ghi", "size" => 5000, "path" => "model.gguf"}
      ])

    Application.put_env(:orchard_controller, :hf, base_hf_config(stub_name))

    on_exit(fn ->
      Application.put_env(:orchard_controller, :hf, previous_hf)
      File.rm_rf!(tmp_dir)
    end)

    %{
      tmp_dir: tmp_dir,
      dest_dir: dest_dir,
      stub_name: stub_name,
      file_contents: file_contents,
      tree_response: tree_response
    }
  end

  # -- Happy-path download with allowlist filtering --------------------------

  describe "download/3 happy path" do
    test "downloads allowlisted files and skips non-model files", ctx do
      stub_successful_hf(ctx)

      assert {:ok, dest, summary} = HubDownloader.download(@repo_id, ctx.dest_dir)

      assert dest == ctx.dest_dir
      assert summary.files_downloaded == 3
      assert summary.total_bytes > 0
      assert summary.revision == "main"

      # Allowlisted files exist
      assert File.exists?(Path.join(ctx.dest_dir, "config.json"))
      assert File.exists?(Path.join(ctx.dest_dir, "tokenizer.json"))
      assert File.exists?(Path.join(ctx.dest_dir, "model.safetensors"))

      # Non-allowlisted files were NOT downloaded
      refute File.exists?(Path.join(ctx.dest_dir, "README.md"))
      refute File.exists?(Path.join(ctx.dest_dir, ".gitattributes"))
      refute File.exists?(Path.join(ctx.dest_dir, "model.gguf"))

      # File contents match
      for {path, expected} <- ctx.file_contents do
        assert File.read!(Path.join(ctx.dest_dir, path)) == expected
      end
    end

    test "uses custom revision", ctx do
      stub_successful_hf(ctx, revision: "abc123")

      assert {:ok, _dest, summary} =
               HubDownloader.download(@repo_id, ctx.dest_dir, revision: "abc123")

      assert summary.revision == "abc123"
    end

    test "supports revisions with slashes", ctx do
      revision = "refs/pr/1"
      stub_successful_hf(ctx, revision: revision)

      assert {:ok, dest, summary} =
               HubDownloader.download(@repo_id, ctx.dest_dir, revision: revision)

      assert dest == ctx.dest_dir
      assert summary.revision == revision

      for {path, expected} <- ctx.file_contents do
        assert File.read!(Path.join(ctx.dest_dir, path)) == expected
      end
    end

    test "preserves nested relative paths", ctx do
      nested_contents = %{
        "config.json" => ~s({"model_type":"llama"}),
        "model.safetensors" => "weights",
        "subdir/extra.json" => ~s({"extra":true})
      }

      tree_response =
        Enum.map(nested_contents, fn {path, content} ->
          %{
            "type" => "file",
            "oid" => "abc",
            "size" => byte_size(content),
            "path" => path
          }
        end)

      Req.Test.stub(ctx.stub_name, fn conn ->
        cond do
          String.contains?(conn.request_path, "/tree/") ->
            Req.Test.json(conn, tree_response)

          conn.method == "HEAD" ->
            file_path = extract_file_path(conn.request_path)
            content = Map.get(nested_contents, file_path, "")

            conn
            |> Plug.Conn.put_resp_header("content-length", to_string(byte_size(content)))
            |> Plug.Conn.put_resp_header("etag", "\"etag-#{file_path}\"")
            |> Plug.Conn.send_resp(200, "")

          conn.method == "GET" ->
            file_path = extract_file_path(conn.request_path)
            content = Map.get(nested_contents, file_path, "")

            conn
            |> Plug.Conn.put_resp_header("content-length", to_string(byte_size(content)))
            |> Plug.Conn.send_resp(200, content)

          true ->
            Plug.Conn.send_resp(conn, 404, "")
        end
      end)

      assert {:ok, _dest, _summary} = HubDownloader.download(@repo_id, ctx.dest_dir)

      assert File.exists?(Path.join(ctx.dest_dir, "subdir/extra.json"))
      assert File.read!(Path.join(ctx.dest_dir, "subdir/extra.json")) == ~s({"extra":true})
    end
  end

  # -- Auth header injection -------------------------------------------------

  describe "auth header" do
    test "sends bearer token when configured", ctx do
      test_pid = self()

      with_hf_overrides(ctx.stub_name, [token: "secret-token"], fn ->
        Req.Test.stub(ctx.stub_name, fn conn ->
          auth = Plug.Conn.get_req_header(conn, "authorization")
          send(test_pid, {:auth_header, conn.method, auth})

          cond do
            String.contains?(conn.request_path, "/tree/") ->
              Req.Test.json(conn, ctx.tree_response)

            conn.method == "HEAD" ->
              file_path = extract_file_path(conn.request_path)
              content = Map.get(ctx.file_contents, file_path, "")

              conn
              |> Plug.Conn.put_resp_header("content-length", to_string(byte_size(content)))
              |> Plug.Conn.put_resp_header("etag", "\"etag-#{file_path}\"")
              |> Plug.Conn.send_resp(200, "")

            conn.method == "GET" ->
              file_path = extract_file_path(conn.request_path)
              content = Map.get(ctx.file_contents, file_path, "")

              conn
              |> Plug.Conn.put_resp_header("content-length", to_string(byte_size(content)))
              |> Plug.Conn.send_resp(200, content)

            true ->
              Plug.Conn.send_resp(conn, 404, "")
          end
        end)

        assert {:ok, _dest, _summary} = HubDownloader.download(@repo_id, ctx.dest_dir)

        # Verify auth on tree GET
        assert_received {:auth_header, "GET", ["Bearer secret-token"]}
        # Verify auth on at least one HEAD
        assert_received {:auth_header, "HEAD", ["Bearer secret-token"]}
        # Verify auth on at least one file GET
        assert_received {:auth_header, "GET", ["Bearer secret-token"]}
      end)
    end

    test "omits auth header when no token configured", ctx do
      test_pid = self()

      Req.Test.stub(ctx.stub_name, fn conn ->
        auth = Plug.Conn.get_req_header(conn, "authorization")
        send(test_pid, {:auth_header, auth})

        cond do
          String.contains?(conn.request_path, "/tree/") ->
            Req.Test.json(conn, ctx.tree_response)

          conn.method == "HEAD" ->
            file_path = extract_file_path(conn.request_path)
            content = Map.get(ctx.file_contents, file_path, "")

            conn
            |> Plug.Conn.put_resp_header("content-length", to_string(byte_size(content)))
            |> Plug.Conn.put_resp_header("etag", "\"etag-#{file_path}\"")
            |> Plug.Conn.send_resp(200, "")

          conn.method == "GET" ->
            file_path = extract_file_path(conn.request_path)
            content = Map.get(ctx.file_contents, file_path, "")

            conn
            |> Plug.Conn.put_resp_header("content-length", to_string(byte_size(content)))
            |> Plug.Conn.send_resp(200, content)

          true ->
            Plug.Conn.send_resp(conn, 404, "")
        end
      end)

      assert {:ok, _dest, _summary} = HubDownloader.download(@repo_id, ctx.dest_dir)

      # All auth headers should be empty (no token)
      assert_received {:auth_header, []}
    end
  end

  # -- Path traversal rejection ----------------------------------------------

  describe "path traversal" do
    test "rejects tree entries with .. traversal", ctx do
      tree_with_traversal = [
        %{"type" => "file", "oid" => "a", "size" => 100, "path" => "config.json"},
        %{"type" => "file", "oid" => "b", "size" => 1000, "path" => "model.safetensors"},
        %{"type" => "file", "oid" => "c", "size" => 50, "path" => "../evil.json"}
      ]

      Req.Test.stub(ctx.stub_name, fn conn ->
        if String.contains?(conn.request_path, "/tree/") do
          Req.Test.json(conn, tree_with_traversal)
        else
          Plug.Conn.send_resp(conn, 404, "")
        end
      end)

      assert {:error, {:invalid_source_layout, msg}} =
               HubDownloader.download(@repo_id, ctx.dest_dir)

      assert msg =~ "path traversal"
      assert msg =~ "../evil.json"

      # Verify no file escaped
      refute File.exists?(Path.join(ctx.tmp_dir, "evil.json"))
    end

    test "rejects absolute paths", ctx do
      tree = [
        %{"type" => "file", "oid" => "a", "size" => 100, "path" => "model.safetensors"},
        %{"type" => "file", "oid" => "b", "size" => 50, "path" => "/etc/evil.safetensors"}
      ]

      Req.Test.stub(ctx.stub_name, fn conn ->
        if String.contains?(conn.request_path, "/tree/") do
          Req.Test.json(conn, tree)
        else
          Plug.Conn.send_resp(conn, 404, "")
        end
      end)

      assert {:error, {:invalid_source_layout, msg}} =
               HubDownloader.download(@repo_id, ctx.dest_dir)

      assert msg =~ "absolute path"
    end
  end

  # -- No-weight rejection ---------------------------------------------------

  describe "no weight rejection" do
    test "rejects repo with no safetensors files", ctx do
      tree = [
        %{"type" => "file", "oid" => "a", "size" => 100, "path" => "config.json"},
        %{"type" => "file", "oid" => "b", "size" => 200, "path" => "tokenizer.json"}
      ]

      Req.Test.stub(ctx.stub_name, fn conn ->
        if String.contains?(conn.request_path, "/tree/") do
          Req.Test.json(conn, tree)
        else
          Plug.Conn.send_resp(conn, 404, "")
        end
      end)

      assert {:error, {:invalid_source_layout, msg}} =
               HubDownloader.download(@repo_id, ctx.dest_dir)

      assert msg =~ "safetensors"
    end

    test "rejects empty tree (doc-only repo)", ctx do
      tree = [
        %{"type" => "file", "oid" => "a", "size" => 100, "path" => "README.md"}
      ]

      Req.Test.stub(ctx.stub_name, fn conn ->
        if String.contains?(conn.request_path, "/tree/") do
          Req.Test.json(conn, tree)
        else
          Plug.Conn.send_resp(conn, 404, "")
        end
      end)

      assert {:error, {:invalid_source_layout, msg}} =
               HubDownloader.download(@repo_id, ctx.dest_dir)

      assert msg =~ "no MLX model files"
    end
  end

  # -- HEAD preflight uses x-linked-* fallback ------------------------------

  describe "HEAD preflight x-linked-* fallback" do
    test "uses x-linked-size and x-linked-etag when standard headers missing", ctx do
      Req.Test.stub(ctx.stub_name, fn conn ->
        cond do
          String.contains?(conn.request_path, "/tree/") ->
            Req.Test.json(conn, ctx.tree_response)

          conn.method == "HEAD" ->
            file_path = extract_file_path(conn.request_path)
            content = Map.get(ctx.file_contents, file_path, "")

            # Use x-linked-* headers instead of standard ones
            conn
            |> Plug.Conn.put_resp_header("x-linked-size", to_string(byte_size(content)))
            |> Plug.Conn.put_resp_header("x-linked-etag", "\"linked-etag-#{file_path}\"")
            |> Plug.Conn.send_resp(200, "")

          conn.method == "GET" ->
            file_path = extract_file_path(conn.request_path)
            content = Map.get(ctx.file_contents, file_path, "")

            conn
            |> Plug.Conn.put_resp_header("content-length", to_string(byte_size(content)))
            |> Plug.Conn.send_resp(200, content)

          true ->
            Plug.Conn.send_resp(conn, 404, "")
        end
      end)

      assert {:ok, _dest, summary} = HubDownloader.download(@repo_id, ctx.dest_dir)

      # total_bytes should reflect x-linked-size values
      expected_bytes =
        ctx.file_contents |> Map.values() |> Enum.map(&byte_size/1) |> Enum.sum()

      assert summary.total_bytes == expected_bytes
    end
  end

  # -- Normalized HTTP errors ------------------------------------------------

  describe "normalized HTTP errors" do
    test "401 on tree returns unauthorized", ctx do
      Req.Test.stub(ctx.stub_name, fn conn ->
        Plug.Conn.send_resp(conn, 401, "Unauthorized")
      end)

      assert {:error, {:unauthorized, msg}} = HubDownloader.download(@repo_id, ctx.dest_dir)
      assert msg =~ "access denied"
    end

    test "403 on tree returns unauthorized", ctx do
      Req.Test.stub(ctx.stub_name, fn conn ->
        Plug.Conn.send_resp(conn, 403, "Forbidden")
      end)

      assert {:error, {:unauthorized, msg}} = HubDownloader.download(@repo_id, ctx.dest_dir)
      assert msg =~ "access denied"
    end

    test "404 on tree returns not_found", ctx do
      Req.Test.stub(ctx.stub_name, fn conn ->
        Plug.Conn.send_resp(conn, 404, "Not Found")
      end)

      assert {:error, {:not_found, msg}} = HubDownloader.download(@repo_id, ctx.dest_dir)
      assert msg =~ "not found"
    end

    test "404 on file HEAD returns not_found", ctx do
      Req.Test.stub(ctx.stub_name, fn conn ->
        cond do
          String.contains?(conn.request_path, "/tree/") ->
            Req.Test.json(conn, ctx.tree_response)

          conn.method == "HEAD" ->
            Plug.Conn.send_resp(conn, 404, "Not Found")

          true ->
            Plug.Conn.send_resp(conn, 404, "")
        end
      end)

      assert {:error, {:not_found, msg}} = HubDownloader.download(@repo_id, ctx.dest_dir)
      assert msg =~ "not found"
    end

    test "404 on file download includes missing path", ctx do
      Req.Test.stub(ctx.stub_name, fn conn ->
        cond do
          String.contains?(conn.request_path, "/tree/") ->
            Req.Test.json(conn, ctx.tree_response)

          conn.method == "HEAD" ->
            file_path = extract_file_path(conn.request_path)
            content = Map.get(ctx.file_contents, file_path, "")

            conn
            |> Plug.Conn.put_resp_header("content-length", to_string(byte_size(content)))
            |> Plug.Conn.put_resp_header("etag", "\"etag-#{file_path}\"")
            |> Plug.Conn.send_resp(200, "")

          conn.method == "GET" ->
            file_path = extract_file_path(conn.request_path)

            if file_path == "model.safetensors" do
              Plug.Conn.send_resp(conn, 404, "Not Found")
            else
              content = Map.get(ctx.file_contents, file_path, "")

              conn
              |> Plug.Conn.put_resp_header("content-length", to_string(byte_size(content)))
              |> Plug.Conn.send_resp(200, content)
            end

          true ->
            Plug.Conn.send_resp(conn, 404, "")
        end
      end)

      assert {:error, {:not_found, msg}} = HubDownloader.download(@repo_id, ctx.dest_dir)
      assert msg =~ "model.safetensors"
    end
  end

  describe "destination safety" do
    test "rejects nested destination symlinks", ctx do
      nested_contents = %{
        "config.json" => ~s({"model_type":"llama"}),
        "escaped/model.safetensors" => "weights"
      }

      tree_response =
        Enum.map(nested_contents, fn {path, content} ->
          %{"type" => "file", "oid" => "abc", "size" => byte_size(content), "path" => path}
        end)

      outside_dir = Path.join(ctx.tmp_dir, "outside")
      escaped_dir = Path.join(ctx.dest_dir, "escaped")
      File.mkdir_p!(outside_dir)
      File.ln_s!(outside_dir, escaped_dir)

      Req.Test.stub(ctx.stub_name, fn conn ->
        cond do
          String.contains?(conn.request_path, "/tree/") ->
            Req.Test.json(conn, tree_response)

          conn.method == "HEAD" ->
            file_path = extract_file_path(conn.request_path)
            content = Map.get(nested_contents, file_path, "")

            conn
            |> Plug.Conn.put_resp_header("content-length", to_string(byte_size(content)))
            |> Plug.Conn.put_resp_header("etag", "\"etag-#{file_path}\"")
            |> Plug.Conn.send_resp(200, "")

          conn.method == "GET" ->
            file_path = extract_file_path(conn.request_path)
            content = Map.get(nested_contents, file_path, "")

            conn
            |> Plug.Conn.put_resp_header("content-length", to_string(byte_size(content)))
            |> Plug.Conn.send_resp(200, content)

          true ->
            Plug.Conn.send_resp(conn, 404, "")
        end
      end)

      assert {:error, {:invalid_source_layout, msg}} =
               HubDownloader.download(@repo_id, ctx.dest_dir)

      assert msg =~ "escaped/model.safetensors"
      assert [] == File.ls!(outside_dir)
    end
  end

  # -- Retry on transient failure --------------------------------------------

  describe "retry" do
    test "retries on 503 then succeeds", ctx do
      call_count = :counters.new(1, [:atomics])

      with_hf_overrides(ctx.stub_name, [retry_attempts: 3], fn ->
        Req.Test.stub(ctx.stub_name, fn conn ->
          cond do
            String.contains?(conn.request_path, "/tree/") ->
              :counters.add(call_count, 1, 1)
              attempt = :counters.get(call_count, 1)

              if attempt == 1 do
                Plug.Conn.send_resp(conn, 503, "Service Unavailable")
              else
                Req.Test.json(conn, ctx.tree_response)
              end

            conn.method == "HEAD" ->
              file_path = extract_file_path(conn.request_path)
              content = Map.get(ctx.file_contents, file_path, "")

              conn
              |> Plug.Conn.put_resp_header("content-length", to_string(byte_size(content)))
              |> Plug.Conn.put_resp_header("etag", "\"etag-#{file_path}\"")
              |> Plug.Conn.send_resp(200, "")

            conn.method == "GET" ->
              file_path = extract_file_path(conn.request_path)
              content = Map.get(ctx.file_contents, file_path, "")

              conn
              |> Plug.Conn.put_resp_header("content-length", to_string(byte_size(content)))
              |> Plug.Conn.send_resp(200, content)

            true ->
              Plug.Conn.send_resp(conn, 404, "")
          end
        end)

        assert {:ok, _dest, _summary} = HubDownloader.download(@repo_id, ctx.dest_dir)
        assert :counters.get(call_count, 1) >= 2
      end)
    end

    test "retries GET on transient failure then succeeds", ctx do
      get_call_count = :counters.new(1, [:atomics])

      with_hf_overrides(ctx.stub_name, [retry_attempts: 3], fn ->
        Req.Test.stub(ctx.stub_name, fn conn ->
          cond do
            String.contains?(conn.request_path, "/tree/") ->
              Req.Test.json(conn, ctx.tree_response)

            conn.method == "HEAD" ->
              file_path = extract_file_path(conn.request_path)
              content = Map.get(ctx.file_contents, file_path, "")

              conn
              |> Plug.Conn.put_resp_header("content-length", to_string(byte_size(content)))
              |> Plug.Conn.put_resp_header("etag", "\"etag-#{file_path}\"")
              |> Plug.Conn.send_resp(200, "")

            conn.method == "GET" ->
              file_path = extract_file_path(conn.request_path)
              content = Map.get(ctx.file_contents, file_path, "")

              if file_path == "model.safetensors" do
                :counters.add(get_call_count, 1, 1)
                attempt = :counters.get(get_call_count, 1)

                if attempt == 1 do
                  Plug.Conn.send_resp(conn, 429, "Rate limited")
                else
                  conn
                  |> Plug.Conn.put_resp_header(
                    "content-length",
                    to_string(byte_size(content))
                  )
                  |> Plug.Conn.send_resp(200, content)
                end
              else
                conn
                |> Plug.Conn.put_resp_header(
                  "content-length",
                  to_string(byte_size(content))
                )
                |> Plug.Conn.send_resp(200, content)
              end

            true ->
              Plug.Conn.send_resp(conn, 404, "")
          end
        end)

        assert {:ok, _dest, _summary} = HubDownloader.download(@repo_id, ctx.dest_dir)
        assert :counters.get(get_call_count, 1) >= 2
      end)
    end
  end

  # -- Resume with Range header after partial failure -----------------------

  describe "resume" do
    test "resumes via Range header when partial + matching ETag exists", ctx do
      file_contents = ctx.file_contents
      safetensors_get_count = :counters.new(1, [:atomics])

      with_hf_overrides(ctx.stub_name, [retry_attempts: 3], fn ->
        Req.Test.stub(ctx.stub_name, fn conn ->
          cond do
            String.contains?(conn.request_path, "/tree/") ->
              Req.Test.json(conn, ctx.tree_response)

            conn.method == "HEAD" ->
              file_path = extract_file_path(conn.request_path)
              content = Map.get(file_contents, file_path, "")

              conn
              |> Plug.Conn.put_resp_header("content-length", to_string(byte_size(content)))
              |> Plug.Conn.put_resp_header("etag", "\"test-etag-#{file_path}\"")
              |> Plug.Conn.send_resp(200, "")

            conn.method == "GET" ->
              file_path = extract_file_path(conn.request_path)
              content = Map.get(file_contents, file_path, "")

              if file_path == "model.safetensors" do
                :counters.add(safetensors_get_count, 1, 1)
                attempt = :counters.get(safetensors_get_count, 1)

                if attempt == 1 do
                  # First attempt: return partial data
                  partial = binary_part(content, 0, div(byte_size(content), 2))

                  conn
                  |> Plug.Conn.put_resp_header(
                    "content-length",
                    to_string(byte_size(content))
                  )
                  |> Plug.Conn.send_resp(200, partial)
                else
                  # Retry: check for Range header
                  range_header = get_range_header(conn)

                  if range_header do
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
                |> Plug.Conn.put_resp_header(
                  "content-length",
                  to_string(byte_size(content))
                )
                |> Plug.Conn.send_resp(200, content)
              end

            true ->
              Plug.Conn.send_resp(conn, 404, "")
          end
        end)

        assert {:ok, _dest, _summary} = HubDownloader.download(@repo_id, ctx.dest_dir)

        # model.safetensors GET was called at least twice (retry)
        assert :counters.get(safetensors_get_count, 1) >= 2

        # Verify final content is correct
        assert File.read!(Path.join(ctx.dest_dir, "model.safetensors")) ==
                 file_contents["model.safetensors"]
      end)
    end
  end

  # -- Server ignores Range (200 instead of 206) ----------------------------

  describe "server ignores Range" do
    test "retries from scratch when server returns 200 instead of 206", ctx do
      file_contents = ctx.file_contents
      safetensors_get_count = :counters.new(1, [:atomics])

      with_hf_overrides(ctx.stub_name, [retry_attempts: 5], fn ->
        Req.Test.stub(ctx.stub_name, fn conn ->
          cond do
            String.contains?(conn.request_path, "/tree/") ->
              Req.Test.json(conn, ctx.tree_response)

            conn.method == "HEAD" ->
              file_path = extract_file_path(conn.request_path)
              content = Map.get(file_contents, file_path, "")

              conn
              |> Plug.Conn.put_resp_header("content-length", to_string(byte_size(content)))
              |> Plug.Conn.put_resp_header("etag", "\"test-etag-#{file_path}\"")
              |> Plug.Conn.send_resp(200, "")

            conn.method == "GET" ->
              file_path = extract_file_path(conn.request_path)
              content = Map.get(file_contents, file_path, "")

              if file_path == "model.safetensors" do
                :counters.add(safetensors_get_count, 1, 1)
                attempt = :counters.get(safetensors_get_count, 1)

                if attempt == 1 do
                  # First attempt: return partial data
                  partial = binary_part(content, 0, div(byte_size(content), 2))

                  conn
                  |> Plug.Conn.put_resp_header(
                    "content-length",
                    to_string(byte_size(content))
                  )
                  |> Plug.Conn.send_resp(200, partial)
                else
                  # Retry: server ignores Range, returns full content with 200
                  conn
                  |> Plug.Conn.put_resp_header(
                    "content-length",
                    to_string(byte_size(content))
                  )
                  |> Plug.Conn.send_resp(200, content)
                end
              else
                conn
                |> Plug.Conn.put_resp_header(
                  "content-length",
                  to_string(byte_size(content))
                )
                |> Plug.Conn.send_resp(200, content)
              end

            true ->
              Plug.Conn.send_resp(conn, 404, "")
          end
        end)

        assert {:ok, _dest, _summary} = HubDownloader.download(@repo_id, ctx.dest_dir)

        # model.safetensors GET was called at least 3 times
        # (1: partial, 2: 200-on-resume detected, 3+: fresh start success)
        assert :counters.get(safetensors_get_count, 1) >= 3

        # Verify content is correct (not corrupted)
        assert File.read!(Path.join(ctx.dest_dir, "model.safetensors")) ==
                 file_contents["model.safetensors"]
      end)
    end
  end

  # -- Progress callback shape and ordering ---------------------------------

  describe "progress callback" do
    test "emits initial preflight and per-file completion updates", ctx do
      stub_successful_hf(ctx)
      test_pid = self()

      callback = fn update -> send(test_pid, {:progress, update}) end

      assert {:ok, _dest, _summary} =
               HubDownloader.download(@repo_id, ctx.dest_dir, progress_callback: callback)

      # Collect all progress messages
      updates = collect_progress_messages()

      # First update is preflight (zero completions, full totals)
      [preflight | file_updates] = updates
      assert preflight.files_completed == 0
      assert preflight.total_files == 3
      assert preflight.bytes_downloaded == 0
      assert preflight.total_bytes > 0
      assert preflight.current_file == nil

      # One completion update per file
      assert length(file_updates) == 3

      # Completions are sequential
      file_counts = Enum.map(file_updates, & &1.files_completed)
      assert file_counts == [1, 2, 3]

      # Each has correct shape
      for update <- file_updates do
        assert is_integer(update.files_completed)
        assert is_integer(update.total_files)
        assert is_integer(update.bytes_downloaded)
        assert is_integer(update.total_bytes)
        assert is_binary(update.current_file)
      end

      # Final update has all files complete
      last = List.last(file_updates)
      assert last.files_completed == 3
      assert last.bytes_downloaded == last.total_bytes
    end

    test "works without callback (nil)", ctx do
      stub_successful_hf(ctx)
      assert {:ok, _dest, _summary} = HubDownloader.download(@repo_id, ctx.dest_dir)
    end

    test "callback failure stops download", ctx do
      stub_successful_hf(ctx)

      bad_callback = fn _update -> raise "boom" end

      assert {:error, {:callback_failed, _msg}} =
               HubDownloader.download(@repo_id, ctx.dest_dir, progress_callback: bad_callback)
    end
  end

  # -- Input validation ------------------------------------------------------

  describe "input validation" do
    test "rejects non-binary repo_id" do
      assert {:error, {:invalid_repo_id, _}} = HubDownloader.download(123, "/tmp/dest")
    end

    test "rejects non-binary dest_dir" do
      assert {:error, {:invalid_destination, _}} = HubDownloader.download("org/repo", 123)
    end

    test "rejects non-keyword opts" do
      assert {:error, {:invalid_options, _}} =
               HubDownloader.download("org/repo", "/tmp/dest", %{})
    end

    test "rejects blank repo_id" do
      assert {:error, {:invalid_repo_id, _}} = HubDownloader.download("   ", "/tmp/dest")
    end

    test "rejects repo_id without slash" do
      assert {:error, {:invalid_repo_id, _}} = HubDownloader.download("noorg", "/tmp/dest")
    end

    test "rejects repo_id with traversal segments" do
      assert {:error, {:invalid_repo_id, _}} = HubDownloader.download("../evil/repo", "/tmp/dest")
    end

    test "rejects invalid callback" do
      assert {:error, {:invalid_options, _}} =
               HubDownloader.download("org/repo", "/tmp/dest", progress_callback: "not a fn")
    end
  end

  # -- Helpers ---------------------------------------------------------------

  defp base_hf_config(stub_name), do: HuggingFaceReqStub.hf_config(stub_name)

  defp with_hf_overrides(stub_name, overrides, fun) do
    previous = Application.get_env(:orchard_controller, :hf, [])
    merged = Keyword.merge(base_hf_config(stub_name), overrides)
    Application.put_env(:orchard_controller, :hf, merged)

    try do
      fun.()
    after
      Application.put_env(:orchard_controller, :hf, previous)
    end
  end

  # Intentional mirror of the node-agent HF stub: these tests need aligned
  # HTTP fixtures so controller and node-agent download behavior stays in lockstep.
  @no_clone true
  defp stub_successful_hf(ctx, opts \\ []) do
    revision = Keyword.get(opts, :revision, @revision)

    Req.Test.stub(ctx.stub_name, fn conn ->
      HuggingFaceReqStub.dispatch(conn, ctx.file_contents, ctx.tree_response, revision: revision)
    end)
  end

  defp extract_file_path(request_path, revision \\ @revision) do
    HuggingFaceReqStub.extract_file_path(request_path, revision)
  end

  defp get_range_header(conn), do: HuggingFaceReqStub.range_header(conn)

  defp collect_progress_messages(acc \\ []) do
    receive do
      {:progress, update} -> collect_progress_messages([update | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end
end
