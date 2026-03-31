defmodule Orchard.HuggingFace.DownloadSupportTest do
  use ExUnit.Case, async: true

  alias Orchard.HuggingFace.DownloadSupport

  @file_content ~s({"model_type":"test"})
  @file_size byte_size(@file_content)
  @file_etag "abc123"

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

      assert length(origin_heads) > 0
      Enum.each(origin_heads, fn {_, _, opts} -> assert Keyword.get(opts, :auth?) == true end)

      # CDN requests should have auth? false
      cdn_requests =
        Enum.filter(requests, fn {_method, url, _} ->
          String.contains?(url, "cdn.example.com")
        end)

      assert length(cdn_requests) > 0
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

      assert length(cdn_requests) > 0
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

  # -- Helpers ---------------------------------------------------------------

  defp collect_requests(acc \\ []) do
    receive do
      {:request, method, url, opts} -> collect_requests([{method, url, opts} | acc])
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
