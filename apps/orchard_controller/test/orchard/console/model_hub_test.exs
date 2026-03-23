defmodule OrchardConsole.ModelHubTest do
  use ExUnit.Case, async: false

  alias OrchardConsole.ModelHub

  setup do
    # DB sandbox: shared mode so spawned tasks can access the repo
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Orchard.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Orchard.Repo, {:shared, self()})

    previous = Application.get_env(:orchard_controller, :console, [])

    Application.put_env(
      :orchard_controller,
      :console,
      Keyword.merge(previous,
        model_hub_impl: ModelHub,
        model_hub_client_impl: __MODULE__.StubClient,
        model_hub_download_impl: __MODULE__.StubDownloader
      )
    )

    on_exit(fn -> Application.put_env(:orchard_controller, :console, previous) end)
    :ok
  end

  describe "start_search/3" do
    test "returns {:ok, pid} immediately" do
      stub_client(search: {:ok, []})

      assert {:ok, pid} = ModelHub.start_search(self(), make_ref(), "Qwen")
      assert is_pid(pid)
    end

    test "task is not linked to the caller" do
      ref = make_ref()
      stub_client(search: {:ok, []})

      {:ok, pid} = ModelHub.start_search(self(), ref, "Qwen")

      {:links, links} = Process.info(self(), :links)
      refute pid in links

      assert_receive {:model_hub, ^ref, :search_finished, {:ok, %{query: "Qwen", results: []}}},
                     1000
    end

    test "forwards query with the supported empty opts contract and sends success message" do
      ref = make_ref()
      results = [%{repo_id: "mlx-community/Qwen2.5-7B-Instruct-4bit"}]

      stub_client(
        search: {:ok, results},
        capture_search: true
      )

      assert {:ok, _pid} = ModelHub.start_search(self(), ref, "Qwen")

      assert_receive {:captured_search, "Qwen", []}, 1000

      assert_receive {:model_hub, ^ref, :search_finished,
                      {:ok, %{query: "Qwen", results: ^results}}},
                     1000
    end

    test "forwards client errors unchanged" do
      ref = make_ref()
      error = %{status: :rate_limited, code: "hf_rate_limited", message: "slow down"}

      stub_client(search: {:error, error})

      assert {:ok, _pid} = ModelHub.start_search(self(), ref, nil)
      assert_receive {:model_hub, ^ref, :search_finished, {:error, ^error}}, 1000
    end

    test "normalizes raised exceptions to a generic error result" do
      ref = make_ref()
      stub_client(search: :raise)

      assert {:ok, _pid} = ModelHub.start_search(self(), ref, nil)

      assert_receive {:model_hub, ^ref, :search_finished, {:error, error}}, 1000
      assert error == %{status: :error, code: "hf_error", message: "Hugging Face request failed."}
      refute_receive {:model_hub, ^ref, :search_finished, _}, 50
    end

    test "normalizes thrown values to a generic error result" do
      ref = make_ref()
      stub_client(search: :throw)

      assert {:ok, _pid} = ModelHub.start_search(self(), ref, nil)

      assert_receive {:model_hub, ^ref, :search_finished, {:error, error}}, 1000
      assert error == %{status: :error, code: "hf_error", message: "Hugging Face request failed."}
      refute_receive {:model_hub, ^ref, :search_finished, _}, 50
    end

    test "normalizes exits to a generic error result" do
      ref = make_ref()
      stub_client(search: :exit)

      assert {:ok, _pid} = ModelHub.start_search(self(), ref, nil)

      assert_receive {:model_hub, ^ref, :search_finished, {:error, error}}, 1000
      assert error == %{status: :error, code: "hf_error", message: "Hugging Face request failed."}
      refute_receive {:model_hub, ^ref, :search_finished, _}, 50
    end
  end

  describe "start_detail/3" do
    test "returns {:ok, pid} immediately" do
      stub_client(detail: {:ok, %{repo_id: "mlx-community/Qwen"}})

      assert {:ok, pid} = ModelHub.start_detail(self(), make_ref(), "mlx-community/Qwen")
      assert is_pid(pid)
    end

    test "forwards repo_id to the client and sends success message" do
      ref = make_ref()
      detail = %{repo_id: "mlx-community/Qwen2.5-7B-Instruct-4bit"}

      stub_client(
        detail: {:ok, detail},
        capture_detail: true
      )

      assert {:ok, _pid} =
               ModelHub.start_detail(self(), ref, "mlx-community/Qwen2.5-7B-Instruct-4bit")

      assert_receive {:captured_detail, "mlx-community/Qwen2.5-7B-Instruct-4bit"}, 1000
      assert_receive {:model_hub, ^ref, :detail_finished, {:ok, ^detail}}, 1000
    end

    test "forwards client errors unchanged" do
      ref = make_ref()
      error = %{status: :not_found, code: "hf_not_found", message: "missing"}

      stub_client(detail: {:error, error})

      assert {:ok, _pid} = ModelHub.start_detail(self(), ref, "mlx-community/missing")
      assert_receive {:model_hub, ^ref, :detail_finished, {:error, ^error}}, 1000
    end

    test "normalizes raised exceptions to a generic error result" do
      ref = make_ref()
      stub_client(detail: :raise)

      assert {:ok, _pid} = ModelHub.start_detail(self(), ref, "mlx-community/exploded")

      assert_receive {:model_hub, ^ref, :detail_finished, {:error, error}}, 1000
      assert error == %{status: :error, code: "hf_error", message: "Hugging Face request failed."}
      refute_receive {:model_hub, ^ref, :detail_finished, _}, 50
    end

    test "normalizes thrown values to a generic error result" do
      ref = make_ref()
      stub_client(detail: :throw)

      assert {:ok, _pid} = ModelHub.start_detail(self(), ref, "mlx-community/exploded")

      assert_receive {:model_hub, ^ref, :detail_finished, {:error, error}}, 1000
      assert error == %{status: :error, code: "hf_error", message: "Hugging Face request failed."}
      refute_receive {:model_hub, ^ref, :detail_finished, _}, 50
    end

    test "normalizes exits to a generic error result" do
      ref = make_ref()
      stub_client(detail: :exit)

      assert {:ok, _pid} = ModelHub.start_detail(self(), ref, "mlx-community/exploded")

      assert_receive {:model_hub, ^ref, :detail_finished, {:error, error}}, 1000
      assert error == %{status: :error, code: "hf_error", message: "Hugging Face request failed."}
      refute_receive {:model_hub, ^ref, :detail_finished, _}, 50
    end
  end

  # ===========================================================================
  # start_download_import/4
  # ===========================================================================

  describe "start_download_import/4" do
    test "returns {:ok, pid} immediately and task is unlinked" do
      stub_client(detail: {:ok, stub_detail()})
      stub_downloader(download: :success)

      ref = make_ref()
      {:ok, pid} = ModelHub.start_download_import(self(), ref, "mlx-community/test")
      assert is_pid(pid)

      {:links, links} = Process.info(self(), :links)
      refute pid in links

      assert_receive {:model_hub, ^ref, :download_finished, _}, 2000
    end

    test "sends download_started, progress, and finished messages in order" do
      stub_client(detail: {:ok, stub_detail()})
      stub_downloader(download: :success)

      ref = make_ref()
      {:ok, _pid} = ModelHub.start_download_import(self(), ref, "mlx-community/test")

      # Collect all messages
      assert_receive {:model_hub, ^ref, :download_started, started}, 2000
      assert started.repo_id == "mlx-community/test"
      assert is_binary(started.revision)
      assert started.total_files == 2
      assert started.total_bytes > 0

      # Should get at least one downloading progress
      assert_receive {:model_hub, ^ref, :download_progress, %{phase: :downloading}}, 2000

      # Should get preparing_bundle phase
      assert_receive {:model_hub, ^ref, :download_progress, %{phase: :preparing_bundle}}, 2000

      # Should get importing phase
      assert_receive {:model_hub, ^ref, :download_progress, %{phase: :importing}}, 2000

      # Should get finished
      assert_receive {:model_hub, ^ref, :download_finished, {:ok, result}}, 2000
      assert result.model_id == "mlx-community/test"
      assert is_binary(result.version)
      assert result.state in [:active, :registered]

      # No more finished messages
      refute_receive {:model_hub, ^ref, :download_finished, _}, 100
    end

    test "forwards client detail errors unchanged" do
      error = %{status: :not_found, code: "hf_not_found", message: "not found"}
      stub_client(detail: {:error, error})
      stub_downloader(download: :success)

      ref = make_ref()
      {:ok, _pid} = ModelHub.start_download_import(self(), ref, "mlx-community/missing")

      assert_receive {:model_hub, ^ref, :download_finished, {:error, ^error}}, 2000
      # No started message for detail failure
      refute_receive {:model_hub, ^ref, :download_started, _}, 100
    end

    test "normalizes downloader unauthorized error" do
      stub_client(detail: {:ok, stub_detail()})
      stub_downloader(download: {:error, {:unauthorized, "Hugging Face access denied."}})

      ref = make_ref()
      {:ok, _pid} = ModelHub.start_download_import(self(), ref, "mlx-community/test")

      assert_receive {:model_hub, ^ref, :download_finished, {:error, error}}, 2000
      assert error.status == :unauthorized
      assert error.code == "hf_unauthorized"
    end

    test "missing revision produces specific error" do
      stub_client(detail: {:ok, %{repo_id: "test", revision_sha: nil}})
      stub_downloader(download: :success)

      ref = make_ref()
      {:ok, _pid} = ModelHub.start_download_import(self(), ref, "mlx-community/test")

      assert_receive {:model_hub, ^ref, :download_finished, {:error, error}}, 2000
      assert error.code == "hf_revision_unavailable"
    end

    test "normalizes exceptions to download_import_failed" do
      stub_client(detail: {:ok, stub_detail()})
      stub_downloader(download: :raise)

      ref = make_ref()
      {:ok, _pid} = ModelHub.start_download_import(self(), ref, "mlx-community/test")

      assert_receive {:model_hub, ^ref, :download_finished, {:error, error}}, 2000
      assert error.code == "download_import_failed"
      refute_receive {:model_hub, ^ref, :download_finished, _}, 100
    end

    test "normalizes exits to download_import_failed" do
      stub_client(detail: {:ok, stub_detail()})
      stub_downloader(download: :exit)

      ref = make_ref()
      {:ok, _pid} = ModelHub.start_download_import(self(), ref, "mlx-community/test")

      assert_receive {:model_hub, ^ref, :download_finished, {:error, error}}, 2000
      assert error.code == "download_import_failed"
      refute_receive {:model_hub, ^ref, :download_finished, _}, 100
    end

    test "cleans up temp directory on success" do
      stub_client(detail: {:ok, stub_detail()})
      stub_downloader(download: :success, capture_dest_dir: true)

      ref = make_ref()
      {:ok, _pid} = ModelHub.start_download_import(self(), ref, "mlx-community/test")

      assert_receive {:captured_dest_dir, dest_dir}, 2000
      assert_receive {:model_hub, ^ref, :download_finished, {:ok, _}}, 2000

      # Temp dir should be cleaned up
      refute File.exists?(dest_dir)
    end

    test "cleans up temp directory on failure" do
      stub_client(detail: {:ok, stub_detail()})
      stub_downloader(download: {:error, {:unauthorized, "denied"}}, capture_dest_dir: true)

      ref = make_ref()
      {:ok, _pid} = ModelHub.start_download_import(self(), ref, "mlx-community/test")

      assert_receive {:captured_dest_dir, dest_dir}, 2000
      assert_receive {:model_hub, ^ref, :download_finished, {:error, _}}, 2000

      refute File.exists?(dest_dir)
    end

    test "normalizes duplicate import error" do
      # First import succeeds
      detail = stub_detail()
      stub_client(detail: {:ok, detail})
      stub_downloader(download: :success)

      ref1 = make_ref()
      {:ok, _pid1} = ModelHub.start_download_import(self(), ref1, "mlx-community/test")
      assert_receive {:model_hub, ^ref1, :download_finished, {:ok, _}}, 2000

      # Second import with same identity should get duplicate error
      ref2 = make_ref()
      {:ok, _pid2} = ModelHub.start_download_import(self(), ref2, "mlx-community/test")
      assert_receive {:model_hub, ^ref2, :download_finished, {:error, error}}, 2000
      assert error.code == "model_already_imported"
    end
  end

  # ===========================================================================
  # Stubs
  # ===========================================================================

  defmodule StubClient do
    def search_models(query, opts) do
      [{pid, config}] = Registry.lookup(OrchardConsole.ModelHubTest.StubRegistry, :client)

      if config[:capture_search] do
        send(pid, {:captured_search, query, opts})
      end

      case config[:search] do
        :raise -> raise "search exploded"
        :throw -> throw(:search_exploded)
        :exit -> exit(:search_exploded)
        nil -> {:ok, []}
        result -> result
      end
    end

    def get_model_detail(repo_id) do
      [{pid, config}] = Registry.lookup(OrchardConsole.ModelHubTest.StubRegistry, :client)

      if config[:capture_detail] do
        send(pid, {:captured_detail, repo_id})
      end

      case config[:detail] do
        :raise -> raise "detail exploded"
        :throw -> throw(:detail_exploded)
        :exit -> exit(:detail_exploded)
        nil -> {:ok, %{repo_id: repo_id}}
        result -> result
      end
    end
  end

  defmodule StubDownloader do
    @doc """
    Stub downloader that writes minimal HF files and calls the progress callback.
    """
    def download(repo_id, dest_dir, opts) do
      [{pid, config}] = Registry.lookup(OrchardConsole.ModelHubTest.StubRegistry, :downloader)

      if config[:capture_dest_dir] do
        send(pid, {:captured_dest_dir, dest_dir})
      end

      case config[:download] do
        :raise ->
          raise "download exploded"

        :throw ->
          throw(:download_exploded)

        :exit ->
          exit(:download_exploded)

        {:error, _} = err ->
          err

        :success_with_duplicate ->
          write_stub_files(dest_dir)
          invoke_callback(opts)
          revision = Keyword.get(opts, :revision, "main")
          {:ok, dest_dir, %{files_downloaded: 2, total_bytes: 100, revision: revision}}

        :success ->
          write_stub_files(dest_dir)
          invoke_callback(opts)
          revision = Keyword.get(opts, :revision, "main")
          {:ok, dest_dir, %{files_downloaded: 2, total_bytes: 100, revision: revision}}

        nil ->
          write_stub_files(dest_dir)
          invoke_callback(opts)
          revision = Keyword.get(opts, :revision, "main")
          {:ok, dest_dir, %{files_downloaded: 2, total_bytes: 100, revision: revision}}

        result ->
          result
      end
    end

    defp write_stub_files(dest_dir) do
      File.mkdir_p!(dest_dir)
      File.write!(Path.join(dest_dir, "config.json"), ~s({"max_position_embeddings": 4096}))
      File.write!(Path.join(dest_dir, "tokenizer.json"), ~s({"version": "1.0"}))
      File.write!(Path.join(dest_dir, "model.safetensors"), "fake-weights")

      File.write!(
        Path.join(dest_dir, "chat_template.jinja"),
        "{% for m in messages %}{{ m.content }}{% endfor %}"
      )
    end

    defp invoke_callback(opts) do
      callback = Keyword.get(opts, :progress_callback)

      if callback do
        # Initial preflight callback
        callback.(%{
          files_completed: 0,
          total_files: 2,
          bytes_downloaded: 0,
          total_bytes: 100,
          current_file: nil
        })

        # File completion callbacks
        callback.(%{
          files_completed: 1,
          total_files: 2,
          bytes_downloaded: 50,
          total_bytes: 100,
          current_file: "config.json"
        })

        callback.(%{
          files_completed: 2,
          total_files: 2,
          bytes_downloaded: 100,
          total_bytes: 100,
          current_file: "model.safetensors"
        })
      end
    end
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp stub_client(config) do
    ensure_registry()
    Registry.register(__MODULE__.StubRegistry, :client, config)
  end

  defp stub_downloader(config) do
    ensure_registry()
    Registry.register(__MODULE__.StubRegistry, :downloader, config)
  end

  defp stub_detail do
    unique_rev = "rev#{System.unique_integer([:positive])}"

    %{
      repo_id: "mlx-community/test",
      revision_sha: unique_rev,
      author: "mlx-community",
      downloads: 1000,
      likes: 10,
      tags: ["mlx"],
      pipeline_tag: "text-generation",
      library_name: "mlx",
      used_storage_bytes: 1000,
      last_modified: "2024-01-01",
      gated: false,
      metadata_summary: %{license: nil, languages: [], base_models: []},
      config_summary: %{
        model_type: "llama",
        architectures: [],
        context_window_tokens: 4096,
        quantization_bits: nil
      },
      siblings: []
    }
  end

  defp ensure_registry do
    unless Process.whereis(__MODULE__.StubRegistry) do
      start_supervised!({Registry, keys: :duplicate, name: __MODULE__.StubRegistry})
    end
  end
end
