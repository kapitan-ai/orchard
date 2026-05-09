defmodule Orchard.Models.HubDownloaderTest do
  use ExUnit.Case, async: false

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

      install_hf_stub(ctx.stub_name, nested_contents, tree_response)

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
        install_hf_stub(ctx,
          on_request: fn conn ->
            auth = Plug.Conn.get_req_header(conn, "authorization")
            send(test_pid, {:auth_header, conn.method, auth})
          end
        )

        assert {:ok, _dest, _summary} = HubDownloader.download(@repo_id, ctx.dest_dir)

        assert_received {:auth_header, "GET", ["Bearer secret-token"]}
        assert_received {:auth_header, "HEAD", ["Bearer secret-token"]}
        assert_received {:auth_header, "GET", ["Bearer secret-token"]}
      end)
    end

    test "omits auth header when no token configured", ctx do
      test_pid = self()

      install_hf_stub(ctx,
        on_request: fn conn ->
          auth = Plug.Conn.get_req_header(conn, "authorization")
          send(test_pid, {:auth_header, auth})
        end
      )

      assert {:ok, _dest, _summary} = HubDownloader.download(@repo_id, ctx.dest_dir)

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

      install_hf_stub(ctx,
        tree_handler: fn conn, _tree_response ->
          Req.Test.json(conn, tree_with_traversal)
        end
      )

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

      install_hf_stub(ctx,
        tree_handler: fn conn, _tree_response ->
          Req.Test.json(conn, tree)
        end
      )

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

      install_hf_stub(ctx,
        tree_handler: fn conn, _tree_response ->
          Req.Test.json(conn, tree)
        end
      )

      assert {:error, {:invalid_source_layout, msg}} =
               HubDownloader.download(@repo_id, ctx.dest_dir)

      assert msg =~ "safetensors"
    end

    test "rejects empty tree (doc-only repo)", ctx do
      tree = [
        %{"type" => "file", "oid" => "a", "size" => 100, "path" => "README.md"}
      ]

      install_hf_stub(ctx,
        tree_handler: fn conn, _tree_response ->
          Req.Test.json(conn, tree)
        end
      )

      assert {:error, {:invalid_source_layout, msg}} =
               HubDownloader.download(@repo_id, ctx.dest_dir)

      assert msg =~ "no MLX model files"
    end
  end

  # -- HEAD preflight uses x-linked-* fallback ------------------------------

  describe "HEAD preflight x-linked-* fallback" do
    test "uses x-linked-size and x-linked-etag when standard headers missing", ctx do
      install_hf_stub(ctx,
        head_handler: fn conn, file_path, content ->
          conn
          |> Plug.Conn.put_resp_header("x-linked-size", to_string(byte_size(content || "")))
          |> Plug.Conn.put_resp_header("x-linked-etag", "\"linked-etag-#{file_path}\"")
          |> Plug.Conn.send_resp(200, "")
        end
      )

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
      install_hf_stub(ctx,
        head_handler: fn conn, _file_path, _content ->
          Plug.Conn.send_resp(conn, 404, "Not Found")
        end
      )

      assert {:error, {:not_found, msg}} = HubDownloader.download(@repo_id, ctx.dest_dir)
      assert msg =~ "not found"
    end

    test "404 on file download includes missing path", ctx do
      install_hf_stub(ctx,
        download_handler: fn conn, file_path, _content ->
          if file_path == "model.safetensors" do
            Plug.Conn.send_resp(conn, 404, "Not Found")
          else
            :default
          end
        end
      )

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

      install_hf_stub(ctx.stub_name, nested_contents, tree_response)

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
        install_hf_stub(ctx,
          tree_handler: fn conn, tree_response ->
            :counters.add(call_count, 1, 1)

            if :counters.get(call_count, 1) == 1 do
              Plug.Conn.send_resp(conn, 503, "Service Unavailable")
            else
              Req.Test.json(conn, tree_response)
            end
          end
        )

        assert {:ok, _dest, _summary} = HubDownloader.download(@repo_id, ctx.dest_dir)
        assert :counters.get(call_count, 1) >= 2
      end)
    end

    test "retries GET on transient failure then succeeds", ctx do
      get_call_count = :counters.new(1, [:atomics])

      with_hf_overrides(ctx.stub_name, [retry_attempts: 3], fn ->
        install_hf_stub(ctx,
          download_handler: fn conn, file_path, content ->
            if file_path == "model.safetensors" do
              :counters.add(get_call_count, 1, 1)

              if :counters.get(get_call_count, 1) == 1 do
                Plug.Conn.send_resp(conn, 429, "Rate limited")
              else
                conn
                |> Plug.Conn.put_resp_header(
                  "content-length",
                  to_string(byte_size(content || ""))
                )
                |> Plug.Conn.send_resp(200, content || "")
              end
            else
              :default
            end
          end
        )

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
        install_hf_stub(ctx,
          head_handler: fn conn, file_path, content ->
            conn
            |> Plug.Conn.put_resp_header("content-length", to_string(byte_size(content || "")))
            |> Plug.Conn.put_resp_header("etag", "\"test-etag-#{file_path}\"")
            |> Plug.Conn.send_resp(200, "")
          end,
          download_handler: fn conn, file_path, content ->
            if file_path == "model.safetensors" do
              :counters.add(safetensors_get_count, 1, 1)
              attempt = :counters.get(safetensors_get_count, 1)
              content = content || ""

              if attempt == 1 do
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

        assert {:ok, _dest, _summary} = HubDownloader.download(@repo_id, ctx.dest_dir)
        assert :counters.get(safetensors_get_count, 1) >= 2

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
        install_hf_stub(ctx,
          head_handler: fn conn, file_path, content ->
            conn
            |> Plug.Conn.put_resp_header("content-length", to_string(byte_size(content || "")))
            |> Plug.Conn.put_resp_header("etag", "\"test-etag-#{file_path}\"")
            |> Plug.Conn.send_resp(200, "")
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

        assert {:ok, _dest, _summary} = HubDownloader.download(@repo_id, ctx.dest_dir)
        assert :counters.get(safetensors_get_count, 1) >= 3

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

    test "emits in-file streaming updates for files exceeding 10 MiB threshold", ctx do
      threshold = 10 * 1_048_576
      large_content = :binary.copy("x", threshold + 1024)
      large_size = byte_size(large_content)

      large_file_contents = %{"model.safetensors" => large_content}
      large_tree_response = HuggingFaceReqStub.tree_response(large_file_contents)
      install_hf_stub(ctx.stub_name, large_file_contents, large_tree_response)

      test_pid = self()
      callback = fn update -> send(test_pid, {:progress, update}) end

      assert {:ok, _dest, _summary} =
               HubDownloader.download(@repo_id, ctx.dest_dir, progress_callback: callback)

      updates = collect_progress_messages()

      # At least one mid-file update: current_file set, files_completed < total, bytes > 0
      mid_file_updates =
        Enum.filter(updates, fn u ->
          u.current_file == "model.safetensors" and
            u.bytes_downloaded > 0 and
            u.files_completed < u.total_files
        end)

      assert [streaming | _] = mid_file_updates
      assert streaming.bytes_downloaded >= threshold
      assert streaming.total_bytes >= large_size

      # Final update has all files complete and bytes match total
      final = List.last(updates)
      assert final.files_completed == 1
      assert final.bytes_downloaded == final.total_bytes
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

  describe "redirect-safe download" do
    test "small redirected file downloads successfully", ctx do
      redirect_files = MapSet.new(["config.json"])
      install_hf_stub(ctx, redirect_files: redirect_files)

      assert {:ok, _, summary} = HubDownloader.download(@repo_id, ctx.dest_dir)

      config_path = Path.join(ctx.dest_dir, "config.json")
      assert File.exists?(config_path)
      assert File.read!(config_path) == ctx.file_contents["config.json"]
      assert summary.files_downloaded == 3
    end

    test "auth token suppressed on cross-origin redirect target", ctx do
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

      with_hf_overrides(ctx.stub_name, [token: "hf_secret"], fn ->
        assert {:ok, _, _} = HubDownloader.download(@repo_id, ctx.dest_dir)
      end)

      # Collect all requests
      messages = collect_request_messages()

      # Origin requests should have auth
      origin_requests = Enum.filter(messages, fn {host, _, _} -> host != "cdn.test" end)
      assert Enum.all?(origin_requests, fn {_, _, auth} -> auth == "Bearer hf_secret" end)

      # CDN requests should NOT have auth
      cdn_requests = Enum.filter(messages, fn {host, _, _} -> host == "cdn.test" end)
      assert cdn_requests != []
      assert Enum.all?(cdn_requests, fn {_, _, auth} -> auth == nil end)
    end

    test "stale partial file triggers 416 recovery", ctx do
      install_hf_stub(ctx, redirect_files: MapSet.new())

      # Pre-create an oversized .partial for config.json
      config_partial = Path.join(ctx.dest_dir, "config.json.partial")
      config_etag = Path.join(ctx.dest_dir, "config.json.partial.etag")
      content = ctx.file_contents["config.json"]
      real_etag = Orchard.TestSupport.HuggingFaceReqStub.hash_content(content)
      File.write!(config_partial, String.duplicate("x", byte_size(content) + 500))
      File.write!(config_etag, real_etag)

      assert {:ok, _, summary} = HubDownloader.download(@repo_id, ctx.dest_dir)

      config_path = Path.join(ctx.dest_dir, "config.json")
      assert File.read!(config_path) == content
      assert summary.files_downloaded == 3
    end

    test "no redirect still works (direct 200)", ctx do
      # Empty redirect set = all files served directly
      install_hf_stub(ctx, redirect_files: MapSet.new())

      assert {:ok, _, summary} = HubDownloader.download(@repo_id, ctx.dest_dir)
      assert summary.files_downloaded == 3

      Enum.each(ctx.file_contents, fn {path, expected} ->
        assert File.read!(Path.join(ctx.dest_dir, path)) == expected
      end)
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

  defp install_hf_stub(ctx, opts) do
    install_hf_stub(ctx.stub_name, ctx.file_contents, ctx.tree_response, opts)
  end

  defp install_hf_stub(stub_name, file_contents, tree_response, opts \\ []) do
    HuggingFaceReqStub.install(stub_name, file_contents, tree_response, opts)
  end

  defp stub_successful_hf(ctx, opts \\ []) do
    revision = Keyword.get(opts, :revision, @revision)
    install_hf_stub(ctx, revision: revision)
  end

  defp collect_progress_messages(acc \\ []) do
    receive do
      {:progress, update} -> collect_progress_messages([update | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end

  defp collect_request_messages(acc \\ []) do
    receive do
      {:request, host, method, auth} -> collect_request_messages([{host, method, auth} | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end
end
