defmodule Orchard.HuggingFace.DownloadSupportTest do
  use ExUnit.Case, async: true

  alias Orchard.HuggingFace.DownloadSupport

  @file_content ~s({"model_type":"test"})
  @file_size byte_size(@file_content)
  @file_etag "abc123"
  @threshold 10 * 1_048_576

  setup do
    tmp_dir =
      System.tmp_dir!()
      |> Path.join("ds_test_#{:rand.uniform(1_000_000)}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    file_metas = [
      %{
        path: "config.json",
        size: @file_size,
        content_length: @file_size,
        etag: @file_etag
      }
    ]

    %{tmp_dir: tmp_dir, file_metas: file_metas}
  end

  test "pause closes a partial transfer and resumes only its remaining bytes", ctx do
    parent = self()
    control = :atomics.new(1, [])
    count = :atomics.new(1, [])
    first = binary_part(@file_content, 0, 5)
    rest = binary_part(@file_content, 5, @file_size - 5)

    request = fn
      :head, _, _ ->
        {:ok, %{status: 200, headers: %{}}}

      :get, url, opts
      when is_binary(url) and url == "https://huggingface.co/test/model/resolve/main/earlier.json" ->
        send(parent, :earlier_downloaded)
        stream_content(opts, @file_content)

      :get, _, opts ->
        attempt = :atomics.add_get(count, 1, 1)
        into = Keyword.fetch!(opts, :into)

        if attempt == 1 do
          :atomics.put(control, 1, 1)
          assert {:halt, {_, response}} = into.({:data, first}, {%{}, %{status: 200}})
          {:ok, response}
        else
          assert {"range", "bytes=5-"} in Keyword.fetch!(opts, :headers)
          assert {:cont, {_, response}} = into.({:data, rest}, {%{}, %{status: 206}})
          {:ok, response}
        end
    end

    opts =
      base_opts(ctx.tmp_dir, request) ++
        [
          control_fun: fn ->
            if :atomics.get(control, 1) == 1, do: {:error, :paused}, else: :ok
          end,
          progress_fun: fn progress, file ->
            send(parent, {:control_progress, progress.bytes_downloaded, file})
            :ok
          end,
          wait_fun: fn ->
            assert_received {:control_progress, retained_bytes, "config.json"}
            assert retained_bytes == @file_size + 5
            assert File.read!(Path.join(ctx.tmp_dir, "config.json.partial")) == first
            send(parent, :paused_with_partial)
            :atomics.put(control, 1, 0)
            :ok
          end
        ]

    [meta] = ctx.file_metas
    files = [%{meta | path: "earlier.json"}, meta]
    assert {:ok, %{files_completed: 2}} = DownloadSupport.download_all(files, opts)
    assert_received :earlier_downloaded
    refute_received :earlier_downloaded
    assert_received :paused_with_partial
    assert :atomics.get(count, 1) == 2
    assert File.read!(Path.join(ctx.tmp_dir, "config.json")) == @file_content
  end

  test "cancellation halts before starting a file", ctx do
    opts =
      base_opts(ctx.tmp_dir, fn _, _, _ -> flunk("request after cancellation") end) ++
        [control_fun: fn -> {:error, :cancelled} end, wait_fun: fn -> :ok end]

    assert {:error, {:callback_failed, :cancelled}} =
             DownloadSupport.download_all(ctx.file_metas, opts)

    refute File.exists?(Path.join(ctx.tmp_dir, "config.json"))
  end

  test "pause callback without a wait callback returns invalid controls", ctx do
    opts =
      base_opts(ctx.tmp_dir, fn _, _, _ -> flunk("request with invalid controls") end) ++
        [control_fun: fn -> {:error, :paused} end]

    assert {:error, {:invalid_controls, _message}} =
             DownloadSupport.download_all(ctx.file_metas, opts)
  end

  defp base_opts(tmp_dir, request_fun) do
    [
      base_url: "https://huggingface.co",
      repo_spec: %{repo_id: "test/model", encoded_repo_id: "test/model", revision: "main"},
      dest_root: tmp_dir,
      root_label: "test",
      request_fun: request_fun,
      max_attempts: 2
    ]
  end

  # Builds a request_fun that:
  # - On HEAD for the origin URL: returns a redirect with the given Location
  # - On HEAD for the redirected URL: returns 200
  # - On GET for the redirected URL: returns file content
  # Sends {:request, method, url, opts} to test_pid for assertions.
  defp redirect_request_fun(test_pid, redirect_location, opts \\ []) do
    terminal_content = Keyword.get(opts, :content, @file_content)
    redirected = :atomics.new(1, [])

    fn method, url, extra_opts ->
      send(test_pid, {:request, method, url, extra_opts})

      cond do
        # HEAD on origin /resolve/ URL before redirect → 307
        method == :head and :atomics.get(redirected, 1) == 0 and
            String.contains?(url, "/resolve/") ->
          :atomics.put(redirected, 1, 1)
          {:ok, %{status: 307, headers: %{"location" => [redirect_location]}}}

        # HEAD on terminal URL (after redirect, or non-resolve URL) → 200
        method == :head ->
          {:ok,
           %{
             status: 200,
             headers: %{
               "content-length" => [to_string(byte_size(terminal_content))],
               "etag" => ["\"#{@file_etag}\""]
             }
           }}

        # GET → stream content through into callback
        method == :get ->
          stream_content(extra_opts, terminal_content)
      end
    end
  end

  describe "redirect resolution — Location variants" do
    test "relative-path Location resolves correctly", ctx do
      request_fun = redirect_request_fun(self(), "/cdn/main/config.json")
      opts = base_opts(ctx.tmp_dir, request_fun)

      assert {:ok, _progress} = DownloadSupport.download_all(ctx.file_metas, opts)
      assert File.read!(Path.join(ctx.tmp_dir, "config.json")) == @file_content
    end

    test "query-only redirect Location resolves correctly", ctx do
      request_fun = redirect_request_fun(self(), "?token=signed&expires=123")
      opts = base_opts(ctx.tmp_dir, request_fun)

      assert {:ok, _progress} = DownloadSupport.download_all(ctx.file_metas, opts)
      assert File.read!(Path.join(ctx.tmp_dir, "config.json")) == @file_content
    end

    test "protocol-relative redirect Location resolves correctly", ctx do
      request_fun = redirect_request_fun(self(), "//cdn.example.com/files/config.json")
      opts = base_opts(ctx.tmp_dir, request_fun)

      assert {:ok, _progress} = DownloadSupport.download_all(ctx.file_metas, opts)
      assert File.read!(Path.join(ctx.tmp_dir, "config.json")) == @file_content
    end
  end

  describe "redirect resolution — error cases" do
    test "missing Location header returns redirect_resolution_failed", ctx do
      request_fun = fn method, url, extra_opts ->
        send(self(), {:request, method, url, extra_opts})

        if method == :head and String.contains?(url, "/resolve/") do
          # 307 but no Location header
          {:ok, %{status: 307, headers: %{}}}
        else
          {:ok, %{status: 200, headers: %{}}}
        end
      end

      opts = base_opts(ctx.tmp_dir, request_fun)

      assert {:error, {:redirect_resolution_failed, msg}} =
               DownloadSupport.download_all(ctx.file_metas, opts)

      assert msg =~ "missing Location"
    end

    test "hop limit exhaustion returns redirect_resolution_failed", ctx do
      # Every HEAD returns another redirect, never a terminal 200
      hop_count = :counters.new(1, [:atomics])

      request_fun = fn method, url, extra_opts ->
        send(self(), {:request, method, url, extra_opts})

        if method == :head do
          n = :counters.get(hop_count, 1)
          :counters.add(hop_count, 1, 1)

          {:ok,
           %{status: 307, headers: %{"location" => ["https://hop#{n + 1}.example.com/file"]}}}
        else
          {:ok, %{status: 200, body: @file_content}}
        end
      end

      opts = base_opts(ctx.tmp_dir, request_fun)

      assert {:error, {:redirect_resolution_failed, msg}} =
               DownloadSupport.download_all(ctx.file_metas, opts)

      assert msg =~ "too many redirect hops"
    end
  end

  describe "redirect resolution — auth boundary" do
    test "same-origin redirect keeps auth? true", ctx do
      # Redirect stays on same host
      request_fun = redirect_request_fun(self(), "https://huggingface.co/cdn/config.json")
      opts = base_opts(ctx.tmp_dir, request_fun)

      assert {:ok, _} = DownloadSupport.download_all(ctx.file_metas, opts)

      requests = collect_requests()
      # All HEAD and GET requests should have auth? true (same origin)
      Enum.each(requests, fn {_method, _url, extra_opts} ->
        assert Keyword.get(extra_opts, :auth?) == true
      end)
    end

    test "cross-origin redirect sets auth? false on CDN", ctx do
      # Redirect to a different host
      request_fun = redirect_request_fun(self(), "https://cdn.example.com/files/config.json")
      opts = base_opts(ctx.tmp_dir, request_fun)

      assert {:ok, _} = DownloadSupport.download_all(ctx.file_metas, opts)

      requests = collect_requests()

      # Origin HEAD should have auth? true
      origin_heads =
        Enum.filter(requests, fn {method, url, _} ->
          method == :head and String.contains?(url, "huggingface.co/test/model/resolve/")
        end)

      assert origin_heads != []
      Enum.each(origin_heads, fn {_, _, opts} -> assert Keyword.get(opts, :auth?) == true end)

      # CDN requests should have auth? false
      cdn_requests =
        Enum.filter(requests, fn {_method, url, _} ->
          String.contains?(url, "cdn.example.com")
        end)

      assert cdn_requests != []
      Enum.each(cdn_requests, fn {_, _, opts} -> assert Keyword.get(opts, :auth?) == false end)
    end

    test "different port on same host sets auth? false", ctx do
      # Redirect to same host but different port
      request_fun = redirect_request_fun(self(), "https://huggingface.co:8443/cdn/config.json")
      opts = base_opts(ctx.tmp_dir, request_fun)

      assert {:ok, _} = DownloadSupport.download_all(ctx.file_metas, opts)

      requests = collect_requests()

      cdn_requests =
        Enum.filter(requests, fn {_method, url, _} ->
          String.contains?(url, ":8443")
        end)

      assert cdn_requests != []
      Enum.each(cdn_requests, fn {_, _, opts} -> assert Keyword.get(opts, :auth?) == false end)
    end
  end

  describe "416 stale-partial recovery" do
    test "oversized partial with matching etag triggers recovery", ctx do
      # Pre-create an oversized .partial with matching etag
      partial_path = Path.join(ctx.tmp_dir, "config.json.partial")
      etag_path = Path.join(ctx.tmp_dir, "config.json.partial.etag")
      File.write!(partial_path, String.duplicate("x", @file_size + 500))
      File.write!(etag_path, @file_etag)

      attempt_count = :counters.new(1, [:atomics])

      request_fun = fn method, url, extra_opts ->
        send(self(), {:request, method, url, extra_opts})

        cond do
          # HEAD → no redirect (direct 200)
          method == :head ->
            {:ok,
             %{
               status: 200,
               headers: %{
                 "content-length" => [to_string(@file_size)],
                 "etag" => ["\"#{@file_etag}\""]
               }
             }}

          # GET with Range that exceeds file size → 416
          method == :get and has_range_header?(extra_opts) ->
            n = :counters.get(attempt_count, 1)
            :counters.add(attempt_count, 1, 1)

            if n == 0 do
              {:ok, %{status: 416}}
            else
              # Fresh retry after recovery
              stream_content(extra_opts, @file_content)
            end

          # GET without Range → normal download
          method == :get ->
            stream_content(extra_opts, @file_content)
        end
      end

      opts = base_opts(ctx.tmp_dir, request_fun)
      assert {:ok, _progress} = DownloadSupport.download_all(ctx.file_metas, opts)

      # File should contain the real content, not the stale partial
      assert File.read!(Path.join(ctx.tmp_dir, "config.json")) == @file_content
      # Partial and etag files should be cleaned up
      refute File.exists?(partial_path)
      refute File.exists?(etag_path)
    end
  end

  describe "no redirect — direct 200" do
    test "direct HEAD 200 skips redirect resolution and streams", ctx do
      request_fun = fn method, url, extra_opts ->
        send(self(), {:request, method, url, extra_opts})

        case method do
          :head ->
            {:ok,
             %{
               status: 200,
               headers: %{
                 "content-length" => [to_string(@file_size)],
                 "etag" => ["\"#{@file_etag}\""]
               }
             }}

          :get ->
            stream_content(extra_opts, @file_content)
        end
      end

      opts = base_opts(ctx.tmp_dir, request_fun)
      assert {:ok, _progress} = DownloadSupport.download_all(ctx.file_metas, opts)
      assert File.read!(Path.join(ctx.tmp_dir, "config.json")) == @file_content

      # Should only have 1 HEAD (redirect resolution) + 1 GET
      requests = collect_requests()
      heads = Enum.filter(requests, fn {method, _, _} -> method == :head end)
      gets = Enum.filter(requests, fn {method, _, _} -> method == :get end)
      assert length(heads) == 1
      assert length(gets) == 1
    end
  end

  describe "streaming progress emission" do
    test "emits mid-stream progress updates when file exceeds 10 MiB threshold", ctx do
      large_content = :binary.copy("y", @threshold + 1)
      large_size = byte_size(large_content)
      chunk1 = binary_part(large_content, 0, @threshold)
      chunk2 = binary_part(large_content, @threshold, large_size - @threshold)

      test_pid = self()

      progress_fun = fn progress, current_file ->
        send(test_pid, {:progress, progress, current_file})
        :ok
      end

      file_metas = [
        %{
          path: "model.safetensors",
          size: large_size,
          content_length: large_size,
          etag: "large123"
        }
      ]

      request_fun = fn method, _url, extra_opts ->
        case method do
          :head ->
            {:ok,
             %{
               status: 200,
               headers: %{
                 "content-length" => [to_string(large_size)],
                 "etag" => ["\"large123\""]
               }
             }}

          :get ->
            into = Keyword.get(extra_opts, :into)
            {_, acc1} = into.({:data, chunk1}, {nil, %{status: 200}})
            {_, acc2} = into.({:data, chunk2}, acc1)
            {:ok, %{status: 200, body: acc2}}
        end
      end

      opts =
        base_opts(ctx.tmp_dir, request_fun)
        |> Keyword.put(:progress_fun, progress_fun)
        |> Keyword.put(:emit_initial_progress?, true)

      assert {:ok, _progress} = DownloadSupport.download_all(file_metas, opts)

      all_updates = collect_progress_updates()

      # At least: initial preflight, 1 in-stream, 1 completion
      assert [_preflight_update, _stream_update, _completion_update | _] = all_updates

      # First is the initial preflight (zero bytes, nil file)
      [{preflight, nil_file} | rest] = all_updates
      assert preflight.bytes_downloaded == 0
      assert preflight.files_completed == 0
      assert is_nil(nil_file)

      # At least one mid-stream update: files_completed still 0, bytes > 0
      streaming_updates =
        Enum.filter(rest, fn {p, _f} ->
          p.files_completed == 0 and p.bytes_downloaded > 0
        end)

      assert [{stream_p, stream_file} | _] = streaming_updates
      assert stream_p.bytes_downloaded >= @threshold
      assert stream_file == "model.safetensors"

      # Final update: files_completed == 1, bytes match total
      {last_p, _} = List.last(rest)
      assert last_p.files_completed == 1
      assert last_p.bytes_downloaded == large_size
    end

    test "aborts download when progress callback returns error mid-stream", ctx do
      large_content = :binary.copy("z", @threshold + 1)
      large_size = byte_size(large_content)
      chunk1 = binary_part(large_content, 0, @threshold)
      chunk2 = binary_part(large_content, @threshold, large_size - @threshold)

      # Callback immediately returns error on every invocation
      progress_fun = fn _progress, _current_file ->
        {:error, {:callback_failed, "test callback abort"}}
      end

      file_metas = [
        %{
          path: "model.safetensors",
          size: large_size,
          content_length: large_size,
          etag: "cbfail"
        }
      ]

      request_fun = fn method, _url, extra_opts ->
        case method do
          :head ->
            {:ok,
             %{
               status: 200,
               headers: %{
                 "content-length" => [to_string(large_size)],
                 "etag" => ["\"cbfail\""]
               }
             }}

          :get ->
            into = Keyword.get(extra_opts, :into)
            {result1, acc1} = into.({:data, chunk1}, {nil, %{status: 200}})

            if result1 == :halt do
              {:ok, %{status: 200, body: acc1}}
            else
              {_, acc2} = into.({:data, chunk2}, acc1)
              {:ok, %{status: 200, body: acc2}}
            end
        end
      end

      opts =
        base_opts(ctx.tmp_dir, request_fun)
        |> Keyword.put(:progress_fun, progress_fun)

      assert {:error, {:callback_failed, {:callback_failed, "test callback abort"}}} =
               DownloadSupport.download_all(file_metas, opts)
    end

    test "does not emit mid-stream progress for file below threshold", ctx do
      # File just under @threshold bytes — delta never reaches threshold
      exact_content = :binary.copy("e", @threshold - 1)
      exact_size = byte_size(exact_content)
      test_pid = self()

      progress_fun = fn progress, current_file ->
        send(test_pid, {:progress, progress, current_file})
        :ok
      end

      file_metas = [
        %{path: "exact.safetensors", size: exact_size, content_length: exact_size, etag: "exact1"}
      ]

      request_fun = fn method, _url, extra_opts ->
        case method do
          :head ->
            {:ok,
             %{
               status: 200,
               headers: %{
                 "content-length" => [to_string(exact_size)],
                 "etag" => ["\"exact1\""]
               }
             }}

          :get ->
            into = Keyword.get(extra_opts, :into)
            {_, acc} = into.({:data, exact_content}, {nil, %{status: 200}})
            {:ok, %{status: 200, body: acc}}
        end
      end

      opts =
        base_opts(ctx.tmp_dir, request_fun)
        |> Keyword.put(:progress_fun, progress_fun)
        |> Keyword.put(:emit_initial_progress?, true)

      assert {:ok, _progress} = DownloadSupport.download_all(file_metas, opts)

      updates = collect_progress_updates()
      # Only initial (preflight) + final completion — no mid-stream emission
      streaming_updates =
        Enum.filter(updates, fn {p, f} ->
          p.files_completed == 0 and p.bytes_downloaded > 0 and not is_nil(f)
        end)

      assert streaming_updates == []
    end

    test "emits mid-stream progress for single chunk exceeding threshold", ctx do
      # One chunk larger than threshold — should emit once
      big_chunk = :binary.copy("b", @threshold * 2)
      big_size = byte_size(big_chunk)
      test_pid = self()

      progress_fun = fn progress, current_file ->
        send(test_pid, {:progress, progress, current_file})
        :ok
      end

      file_metas = [
        %{path: "big.safetensors", size: big_size, content_length: big_size, etag: "big1"}
      ]

      request_fun = fn method, _url, extra_opts ->
        case method do
          :head ->
            {:ok,
             %{
               status: 200,
               headers: %{
                 "content-length" => [to_string(big_size)],
                 "etag" => ["\"big1\""]
               }
             }}

          :get ->
            into = Keyword.get(extra_opts, :into)
            {_, acc} = into.({:data, big_chunk}, {nil, %{status: 200}})
            {:ok, %{status: 200, body: acc}}
        end
      end

      opts =
        base_opts(ctx.tmp_dir, request_fun)
        |> Keyword.put(:progress_fun, progress_fun)
        |> Keyword.put(:emit_initial_progress?, true)

      assert {:ok, _progress} = DownloadSupport.download_all(file_metas, opts)

      updates = collect_progress_updates()

      streaming_updates =
        Enum.filter(updates, fn {p, f} ->
          p.files_completed == 0 and p.bytes_downloaded > 0 and not is_nil(f)
        end)

      # Single chunk >= 2x threshold triggers exactly 1 mid-stream emission
      assert length(streaming_updates) == 1
      {stream_p, _} = hd(streaming_updates)
      assert stream_p.bytes_downloaded == big_size
    end

    test "handles zero-byte file without errors", ctx do
      test_pid = self()

      progress_fun = fn progress, current_file ->
        send(test_pid, {:progress, progress, current_file})
        :ok
      end

      file_metas = [
        %{path: "empty.json", size: 0, content_length: 0, etag: "empty1"}
      ]

      request_fun = fn method, _url, _extra_opts ->
        case method do
          :head ->
            {:ok,
             %{
               status: 200,
               headers: %{
                 "content-length" => ["0"],
                 "etag" => ["\"empty1\""]
               }
             }}

          :get ->
            {:ok, %{status: 200, body: ""}}
        end
      end

      opts =
        base_opts(ctx.tmp_dir, request_fun)
        |> Keyword.put(:progress_fun, progress_fun)
        |> Keyword.put(:emit_initial_progress?, true)

      assert {:ok, progress} = DownloadSupport.download_all(file_metas, opts)
      assert progress.files_completed == 1
      assert progress.bytes_downloaded == 0
    end
  end

  # -- Helpers ---------------------------------------------------------------

  defp collect_requests(acc \\ []) do
    receive do
      {:request, method, url, opts} -> collect_requests([{method, url, opts} | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end

  defp collect_progress_updates(acc \\ []) do
    receive do
      {:progress, progress, current_file} ->
        collect_progress_updates([{progress, current_file} | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end

  defp has_range_header?(extra_opts) do
    extra_opts
    |> Keyword.get(:headers, [])
    |> Enum.any?(fn {k, _} -> k == "range" end)
  end

  defp stream_content(extra_opts, content) do
    into = Keyword.get(extra_opts, :into)

    if into do
      {_, acc} = into.({:data, content}, {nil, %{status: 200}})
      {:ok, %{status: 200, body: acc}}
    else
      {:ok, %{status: 200, body: content}}
    end
  end
end
