defmodule OrchardConsole.ModelHubTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Ecto.Adapters.SQL.Sandbox
  alias Orchard.{ArtifactBundle, Models}
  alias OrchardConsole.ModelHub
  alias OrchardConsole.ModelHubTest.{StubClient, StubDownloader}

  setup do
    # DB sandbox: shared mode so spawned tasks can access the repo
    :ok = Sandbox.checkout(Orchard.Repo)
    Sandbox.mode(Orchard.Repo, {:shared, self()})

    previous = Application.get_env(:orchard_controller, :console, [])

    Application.put_env(
      :orchard_controller,
      :console,
      Keyword.merge(previous,
        model_hub_impl: ModelHub,
        model_hub_client_impl: StubClient,
        model_hub_download_impl: StubDownloader
      )
    )

    on_exit(fn -> Application.put_env(:orchard_controller, :console, previous) end)
    :ok
  end

  describe "start_search/3" do
    test "returns {:ok, pid} immediately" do
      ref = make_ref()
      stub_client(search: {:ok, []})

      assert {:ok, pid} = ModelHub.start_search(self(), ref, "Qwen")
      assert is_pid(pid)
      assert_receive {:model_hub, ^ref, :search_finished, {:ok, _}}, 1000
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

    test "redacts secret-bearing search error messages before sending results" do
      secrets = bearer_secret_samples()
      hf_token = "hf_1234567890abcdef"

      error = %{
        status: :rate_limited,
        code: "hf_rate_limited",
        message:
          "search failed with Bearer #{secrets.slash} and #{hf_token}; jwt Bearer #{secrets.jwt}; " <>
            "opaque Bearer #{secrets.opaque}; sk Bearer #{secrets.sk}"
      }

      stub_client(search: {:error, error})

      ref = make_ref()
      assert {:ok, _pid} = ModelHub.start_search(self(), ref, nil)

      assert_receive {:model_hub, ^ref, :search_finished, {:error, redacted}}, 1000
      assert redacted.status == :rate_limited
      assert redacted.code == "hf_rate_limited"
      assert redacted.message =~ "Bearer [REDACTED]"
      assert redacted.message =~ "[REDACTED-HF-TOKEN]"
      refute_bearer_secrets(redacted.message, secrets)
      refute redacted.message =~ hf_token
    end

    test "preserves benign bearer prose in search error messages" do
      message = "Bearer authentication is required"
      error = %{status: :rate_limited, code: "hf_rate_limited", message: message}

      stub_client(search: {:error, error})

      ref = make_ref()
      assert {:ok, _pid} = ModelHub.start_search(self(), ref, nil)
      assert_receive {:model_hub, ^ref, :search_finished, {:error, ^error}}, 1000
    end

    test "normalizes raised exceptions to a generic error result" do
      ref = make_ref()
      stub_client(search: :raise)

      log =
        capture_log(fn ->
          assert {:ok, _pid} = ModelHub.start_search(self(), ref, nil)

          assert_receive {:model_hub, ^ref, :search_finished, {:error, error}}, 1000

          assert error == %{
                   status: :error,
                   code: "hf_error",
                   message: "Hugging Face request failed."
                 }

          refute_receive {:model_hub, ^ref, :search_finished, _}, 50
        end)

      assert log =~ "ModelHub: pipeline rescued exception"
    end

    test "redacts auth tokens from rescued exception logs" do
      secrets = bearer_secret_samples()
      hf_token = "hf_1234567890abcdef"
      ref = make_ref()

      stub_client(
        search:
          {:raise,
           "boom Authorization: Bearer #{hf_token} and retry with Bearer #{secrets.slash} " <>
             "jwt Bearer #{secrets.jwt} opaque Bearer #{secrets.opaque} sk Bearer #{secrets.sk}"}
      )

      log =
        capture_log(fn ->
          assert {:ok, _pid} = ModelHub.start_search(self(), ref, nil)
          assert_receive {:model_hub, ^ref, :search_finished, {:error, %{code: "hf_error"}}}, 1000
        end)

      assert log =~ "ModelHub: pipeline rescued exception"
      assert log =~ "Authorization: Bearer [REDACTED]"
      assert log =~ "retry with Bearer [REDACTED]"
      assert log =~ "jwt Bearer [REDACTED]"
      assert log =~ "opaque Bearer [REDACTED]"
      assert log =~ "sk Bearer [REDACTED]"
      refute_bearer_secrets(log, secrets)
      refute log =~ hf_token
    end

    test "normalizes thrown values to a generic error result" do
      ref = make_ref()
      stub_client(search: :throw)

      capture_log(fn ->
        assert {:ok, _pid} = ModelHub.start_search(self(), ref, nil)

        assert_receive {:model_hub, ^ref, :search_finished, {:error, error}}, 1000

        assert error == %{
                 status: :error,
                 code: "hf_error",
                 message: "Hugging Face request failed."
               }

        refute_receive {:model_hub, ^ref, :search_finished, _}, 50
      end)
    end

    test "normalizes exits to a generic error result" do
      ref = make_ref()
      stub_client(search: :exit)

      capture_log(fn ->
        assert {:ok, _pid} = ModelHub.start_search(self(), ref, nil)

        assert_receive {:model_hub, ^ref, :search_finished, {:error, error}}, 1000

        assert error == %{
                 status: :error,
                 code: "hf_error",
                 message: "Hugging Face request failed."
               }

        refute_receive {:model_hub, ^ref, :search_finished, _}, 50
      end)
    end
  end

  describe "start_detail/3" do
    test "returns {:ok, pid} immediately" do
      ref = make_ref()
      detail = %{repo_id: "mlx-community/Qwen"}
      stub_client(detail: {:ok, detail})

      assert {:ok, pid} = ModelHub.start_detail(self(), ref, "mlx-community/Qwen")
      assert is_pid(pid)
      assert_receive {:model_hub, ^ref, :detail_finished, {:ok, ^detail}}, 1000
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

    test "redacts secret-bearing detail error messages before sending results" do
      secrets = bearer_secret_samples()
      hf_token = "hf_1234567890abcdef"

      error = %{
        status: :not_found,
        code: "hf_not_found",
        message:
          "detail failed with Bearer #{secrets.slash} and #{hf_token}; jwt Bearer #{secrets.jwt}; " <>
            "opaque Bearer #{secrets.opaque}; sk Bearer #{secrets.sk}"
      }

      stub_client(detail: {:error, error})

      ref = make_ref()
      assert {:ok, _pid} = ModelHub.start_detail(self(), ref, "mlx-community/missing")

      assert_receive {:model_hub, ^ref, :detail_finished, {:error, redacted}}, 1000
      assert redacted.status == :not_found
      assert redacted.code == "hf_not_found"
      assert redacted.message =~ "Bearer [REDACTED]"
      assert redacted.message =~ "[REDACTED-HF-TOKEN]"
      refute_bearer_secrets(redacted.message, secrets)
      refute redacted.message =~ hf_token
    end

    test "preserves benign bearer prose in detail error messages" do
      message = "Bearer authentication is required"
      error = %{status: :not_found, code: "hf_not_found", message: message}

      stub_client(detail: {:error, error})

      ref = make_ref()
      assert {:ok, _pid} = ModelHub.start_detail(self(), ref, "mlx-community/missing")
      assert_receive {:model_hub, ^ref, :detail_finished, {:error, ^error}}, 1000
    end

    test "normalizes raised exceptions to a generic error result" do
      ref = make_ref()
      stub_client(detail: :raise)

      capture_log(fn ->
        assert {:ok, _pid} = ModelHub.start_detail(self(), ref, "mlx-community/exploded")

        assert_receive {:model_hub, ^ref, :detail_finished, {:error, error}}, 1000

        assert error == %{
                 status: :error,
                 code: "hf_error",
                 message: "Hugging Face request failed."
               }

        refute_receive {:model_hub, ^ref, :detail_finished, _}, 50
      end)
    end

    test "normalizes thrown values to a generic error result" do
      ref = make_ref()
      stub_client(detail: :throw)

      capture_log(fn ->
        assert {:ok, _pid} = ModelHub.start_detail(self(), ref, "mlx-community/exploded")

        assert_receive {:model_hub, ^ref, :detail_finished, {:error, error}}, 1000

        assert error == %{
                 status: :error,
                 code: "hf_error",
                 message: "Hugging Face request failed."
               }

        refute_receive {:model_hub, ^ref, :detail_finished, _}, 50
      end)
    end

    test "normalizes exits to a generic error result" do
      ref = make_ref()
      stub_client(detail: :exit)

      capture_log(fn ->
        assert {:ok, _pid} = ModelHub.start_detail(self(), ref, "mlx-community/exploded")

        assert_receive {:model_hub, ^ref, :detail_finished, {:error, error}}, 1000

        assert error == %{
                 status: :error,
                 code: "hf_error",
                 message: "Hugging Face request failed."
               }

        refute_receive {:model_hub, ^ref, :detail_finished, _}, 50
      end)
    end
  end

  # ===========================================================================
  # start_search/3 — repo-ID direct lookup
  # ===========================================================================

  describe "start_search/3 with repo-ID queries" do
    test "repo-ID query triggers direct lookup and injects result into search payload" do
      ref = make_ref()

      direct_detail = %{
        repo_id: "owner/model-name",
        author: "owner",
        downloads: 42,
        likes: 7,
        tags: ["mlx"],
        pipeline_tag: "text-generation",
        library_name: "mlx",
        used_storage_bytes: 1_000,
        safetensors_total: 600_000_000,
        last_modified: "2024-01-01",
        gated: false
      }

      stub_client(
        search: {:ok, []},
        detail: {:ok, direct_detail},
        capture_detail: true
      )

      assert {:ok, _pid} = ModelHub.start_search(self(), ref, "owner/model-name")

      assert_receive {:captured_detail, "owner/model-name"}, 1000

      assert_receive {:model_hub, ^ref, :search_finished,
                      {:ok, %{query: "owner/model-name", results: results}}},
                     1000

      assert length(results) == 1
      assert hd(results).repo_id == "owner/model-name"
      assert hd(results).safetensors_total == 600_000_000
    end

    test "non-repo-ID query does not trigger direct lookup" do
      ref = make_ref()

      stub_client(
        search: {:ok, []},
        capture_detail: true
      )

      assert {:ok, _pid} = ModelHub.start_search(self(), ref, "qwen")

      assert_receive {:model_hub, ^ref, :search_finished, {:ok, %{results: []}}}, 1000
      refute_receive {:captured_detail, _}, 100
    end

    test "nil query does not trigger direct lookup" do
      ref = make_ref()

      stub_client(
        search: {:ok, []},
        capture_detail: true
      )

      assert {:ok, _pid} = ModelHub.start_search(self(), ref, nil)

      assert_receive {:model_hub, ^ref, :search_finished, {:ok, %{results: []}}}, 1000
      refute_receive {:captured_detail, _}, 100
    end

    test "direct lookup runs in parallel with MLX search" do
      ref = make_ref()

      direct_detail = %{
        repo_id: "owner/parallel-model",
        author: "owner",
        downloads: 0,
        likes: 0,
        tags: [],
        pipeline_tag: nil,
        library_name: nil,
        used_storage_bytes: 0,
        last_modified: nil,
        gated: false
      }

      stub_client(
        search: {:ok, []},
        detail: {:ok, direct_detail},
        capture_detail: true,
        block_search: true
      )

      assert {:ok, _search_pid} = ModelHub.start_search(self(), ref, "owner/parallel-model")

      # Both messages arrive while search is blocked; assert either order.
      assert_receive {:blocked_search, search_task_pid}, 1000
      assert_receive {:captured_detail, "owner/parallel-model"}, 1000

      # Unblock search and await final result.
      send(search_task_pid, :proceed_search)
      assert_receive {:model_hub, ^ref, :search_finished, {:ok, _}}, 1000
    end

    test "deduplicates when direct lookup repo_id already in search results" do
      ref = make_ref()
      shared_repo_id = "owner/shared-model"

      direct_detail = %{
        repo_id: shared_repo_id,
        author: "owner",
        downloads: 999,
        likes: 50,
        tags: ["mlx"],
        pipeline_tag: "text-generation",
        library_name: "mlx",
        used_storage_bytes: 5_000,
        last_modified: "2024-06-01",
        gated: false
      }

      search_results = [
        %{
          repo_id: shared_repo_id,
          author: "owner",
          downloads: 100,
          likes: 5,
          tags: ["mlx"],
          pipeline_tag: nil,
          library_name: nil,
          used_storage_bytes: 0,
          last_modified: nil,
          gated: false
        },
        %{
          repo_id: "owner/other-model",
          author: "owner",
          downloads: 50,
          likes: 2,
          tags: [],
          pipeline_tag: nil,
          library_name: nil,
          used_storage_bytes: 0,
          last_modified: nil,
          gated: false
        }
      ]

      stub_client(
        search: {:ok, search_results},
        detail: {:ok, direct_detail}
      )

      assert {:ok, _pid} = ModelHub.start_search(self(), ref, shared_repo_id)

      assert_receive {:model_hub, ^ref, :search_finished, {:ok, %{results: results}}}, 1000

      # Should have 2 results (deduped), not 3.
      assert length(results) == 2

      # First result is the direct lookup (downloads: 999, not the search result's 100).
      [first | rest] = results
      assert first.repo_id == shared_repo_id
      assert first.downloads == 999

      # The duplicate from search results is removed; the other result remains.
      refute Enum.any?(rest, fn r -> r.repo_id == shared_repo_id end)
      assert Enum.any?(rest, fn r -> r.repo_id == "owner/other-model" end)
    end

    test "direct lookup :not_found is silently ignored" do
      ref = make_ref()
      not_found = %{status: :not_found, code: "hf_not_found", message: "not found"}

      search_results = [
        %{
          repo_id: "owner/model-exists",
          author: "owner",
          downloads: 100,
          likes: 5,
          tags: [],
          pipeline_tag: nil,
          library_name: nil,
          used_storage_bytes: 0,
          last_modified: nil,
          gated: false
        }
      ]

      stub_client(
        search: {:ok, search_results},
        detail: {:error, not_found}
      )

      assert {:ok, _pid} = ModelHub.start_search(self(), ref, "owner/model-exists")

      assert_receive {:model_hub, ^ref, :search_finished, {:ok, %{results: ^search_results}}},
                     1000
    end

    test "direct lookup crash is silently ignored" do
      ref = make_ref()

      search_results = [
        %{
          repo_id: "owner/crash-model",
          author: "owner",
          downloads: 1,
          likes: 0,
          tags: [],
          pipeline_tag: nil,
          library_name: nil,
          used_storage_bytes: 0,
          last_modified: nil,
          gated: false
        }
      ]

      stub_client(
        search: {:ok, search_results},
        detail: :raise
      )

      assert {:ok, _pid} = ModelHub.start_search(self(), ref, "owner/crash-model")

      assert_receive {:model_hub, ^ref, :search_finished, {:ok, %{results: ^search_results}}},
                     1000
    end

    test "killing the search pid also terminates the linked direct-lookup child" do
      ref = make_ref()

      stub_client(
        search: {:ok, []},
        detail:
          {:ok,
           %{
             repo_id: "owner/kill-test",
             author: "owner",
             downloads: 0,
             likes: 0,
             tags: [],
             pipeline_tag: nil,
             library_name: nil,
             used_storage_bytes: 0,
             last_modified: nil,
             gated: false
           }},
        capture_detail_pid: true,
        block_detail: true
      )

      assert {:ok, search_pid} = ModelHub.start_search(self(), ref, "owner/kill-test")

      # Wait for the detail child to start and block.
      assert_receive {:captured_detail_pid, detail_pid}, 1000

      detail_monitor = Process.monitor(detail_pid)

      # Kill the outer search task; the linked child must die too.
      Process.exit(search_pid, :kill)

      assert_receive {:DOWN, ^detail_monitor, :process, ^detail_pid, _reason}, 1000
    end
  end

  # ===========================================================================
  # start_download_import/4
  # ===========================================================================

  describe "start_download_import/4" do
    test "cancelled transfer removes temporary files before acknowledging cancellation" do
      stub_client(detail: {:ok, stub_detail()})
      stub_downloader(download: {:error, {:cancelled, "Cancelled"}}, capture_dest_dir: true)
      ref = make_ref()
      {:ok, _pid} = ModelHub.start_download_import(self(), ref, "mlx-community/test")
      assert_receive {:captured_dest_dir, path}, 2000

      assert_receive {:model_hub, ^ref, :download_finished,
                      {:error, %{code: "download_cancelled"}}},
                     2000

      refute File.exists?(path)
      refute_receive {:model_hub, ^ref, :download_progress, %{phase: :preparing_bundle}}
    end

    test "cleanup failure does not claim cancellation reclaimed temporary storage" do
      stub_client(detail: {:ok, stub_detail()})
      stub_downloader(download: {:error, {:cancelled, "Cancelled"}}, capture_dest_dir: true)
      ref = make_ref()
      control = :atomics.new(1, [])
      :atomics.put(control, 1, 2)

      {:ok, _pid} =
        ModelHub.start_download_import(self(), ref, "mlx-community/test",
          control: control,
          cleanup_fun: fn path -> {:error, :eacces, path} end
        )

      assert_receive {:captured_dest_dir, path}, 2000
      on_exit(fn -> File.rm_rf(path) end)

      assert_receive {:model_hub, ^ref, :download_finished,
                      {:error, %{code: "download_cleanup_failed", message: message}}},
                     2000

      assert File.exists?(path)
      assert message =~ "could not be removed"
      refute message =~ "Temporary files removed"
    end

    test "rapid resume and pause acknowledges the new pause before waiting again" do
      stub_client(detail: {:ok, stub_detail()})
      stub_downloader(download: :wait_control, capture_dest_dir: true)
      control = :atomics.new(1, [])
      :atomics.put(control, 1, 1)
      ref = make_ref()

      {:ok, pid} =
        ModelHub.start_download_import(self(), ref, "mlx-community/test", control: control)

      assert_receive {:captured_dest_dir, path}, 2000
      assert_receive {:"$gen_call", first_ack, {:download_paused, ^ref}}, 2000
      # Re-pause before the worker consumes the resume notification.
      :atomics.put(control, 1, 0)
      send(pid, {:model_hub_control, ref, :resume})
      :atomics.put(control, 1, 1)
      GenServer.reply(first_ack, :ok)
      assert_receive {:"$gen_call", second_ack, {:download_paused, ^ref}}, 2000
      GenServer.reply(second_ack, :ok)
      :atomics.put(control, 1, 2)
      send(pid, {:model_hub_control, ref, :cancel})

      assert_receive {:model_hub, ^ref, :download_finished,
                      {:error, %{code: "download_cancelled"}}},
                     2000

      refute File.exists?(path)
    end

    test "accepted cancellation wins over a delayed provider detail failure" do
      stub_client(
        detail: {:error, %{status: :error, code: "hf_unavailable", message: "Offline"}},
        block_detail: true
      )

      stub_downloader(download: :success)
      control = :atomics.new(1, [])
      ref = make_ref()

      {:ok, _pid} =
        ModelHub.start_download_import(self(), ref, "mlx-community/test", control: control)

      assert_receive {:blocked_detail, worker}, 2000
      :atomics.put(control, 1, 2)
      send(worker, :proceed_detail)

      assert_receive {:model_hub, ^ref, :download_finished,
                      {:error, %{code: "download_cancelled"}}},
                     2000
    end

    test "accepted cancellation wins over a delayed downloader preflight failure" do
      stub_client(detail: {:ok, stub_detail()})

      stub_downloader(
        download: {:error, {:unavailable, "Preflight unavailable"}},
        block_download: true,
        capture_dest_dir: true
      )

      control = :atomics.new(1, [])
      ref = make_ref()

      {:ok, _pid} =
        ModelHub.start_download_import(self(), ref, "mlx-community/test", control: control)

      assert_receive {:captured_dest_dir, path}, 2000
      assert_receive {:blocked_download, worker}, 2000
      :atomics.put(control, 1, 2)
      send(worker, :proceed_download)

      assert_receive {:model_hub, ^ref, :download_finished,
                      {:error, %{code: "download_cancelled"}}},
                     2000

      refute File.exists?(path)
    end

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

      # Should get multiple downloading progress messages (streaming update + file completions)
      assert_receive {:model_hub, ^ref, :download_progress, %{phase: :downloading}}, 2000
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
      assert error.message == "Hugging Face access denied."
    end

    test "redacts secret-bearing downloader error messages before sending results" do
      secrets = bearer_secret_samples()
      hf_token = "hf_1234567890abcdef"

      message =
        "upstream failed with Bearer #{secrets.slash} and #{hf_token}; " <>
          "jwt Bearer #{secrets.jwt}; opaque Bearer #{secrets.opaque}; sk Bearer #{secrets.sk}"

      stub_client(detail: {:ok, stub_detail()})
      stub_downloader(download: {:error, {:unauthorized, message}})

      ref = make_ref()
      {:ok, _pid} = ModelHub.start_download_import(self(), ref, "mlx-community/test")

      assert_receive {:model_hub, ^ref, :download_finished, {:error, error}}, 2000
      assert error.status == :unauthorized
      assert error.code == "hf_unauthorized"
      assert error.message =~ "Bearer [REDACTED]"
      assert error.message =~ "[REDACTED-HF-TOKEN]"
      refute_bearer_secrets(error.message, secrets)
      refute error.message =~ hf_token
    end

    test "preserves non-secret bearer wording in downloader error messages" do
      message = "Bearer authentication is required"

      stub_client(detail: {:ok, stub_detail()})
      stub_downloader(download: {:error, {:unauthorized, message}})

      ref = make_ref()
      {:ok, _pid} = ModelHub.start_download_import(self(), ref, "mlx-community/test")

      assert_receive {:model_hub, ^ref, :download_finished, {:error, error}}, 2000
      assert error.status == :unauthorized
      assert error.code == "hf_unauthorized"
      assert error.message == message
    end

    test "missing revision produces specific error" do
      stub_client(detail: {:ok, %{repo_id: "test", revision_sha: nil}})
      stub_downloader(download: :success)

      ref = make_ref()
      {:ok, _pid} = ModelHub.start_download_import(self(), ref, "mlx-community/test")

      assert_receive {:model_hub, ^ref, :download_finished, {:error, error}}, 2000
      assert error.code == "hf_revision_unavailable"
    end

    test "rejects a stale pinned revision before calling the downloader" do
      detail = stub_detail()
      stub_client(detail: {:ok, detail})
      stub_downloader(download: :success, capture_download: true)

      ref = make_ref()

      {:ok, _pid} =
        ModelHub.start_download_import(self(), ref, detail.repo_id, revision: "stale-revision")

      assert_receive {:model_hub, ^ref, :download_finished, {:error, error}}, 2000
      assert error.status == :error
      assert error.code == "hf_revision_changed"
      refute_receive {:captured_download, _, _}, 100
      refute_receive {:model_hub, ^ref, :download_started, _}, 100
    end

    test "SPEC 6.5 registers an exact pinned revision and returns its final stored digest" do
      detail = stub_detail()
      repo_id = detail.repo_id
      stub_client(detail: {:ok, detail})
      stub_downloader(download: :success, capture_download: true)

      ref = make_ref()

      {:ok, _pid} =
        ModelHub.start_download_import(self(), ref, detail.repo_id,
          revision: detail.revision_sha,
          activate: false
        )

      assert_receive {:captured_download, ^repo_id, download_opts}, 2000
      assert download_opts[:revision] == detail.revision_sha
      assert_receive {:model_hub, ^ref, :download_finished, {:ok, result}}, 2000

      model = Models.get_model_by_identity(detail.repo_id, detail.revision_sha)
      assert {:ok, artifact_path} = Models.artifact_local_path(model)
      assert {:ok, final_tree_sha256} = ArtifactBundle.tree_sha256(artifact_path)
      assert result.state == :registered
      assert model.state == :registered
      assert result.version == detail.revision_sha
      assert result.artifact_sha256 == model.artifact_sha256
      assert result.artifact_sha256 == final_tree_sha256
    end

    test "reimports through the Model Hub pipeline at an explicit catalog version", _ctx do
      detail = stub_detail()
      catalog_version = detail.revision_sha <> "-tool-admission"
      stub_client(detail: {:ok, detail})
      stub_downloader(download: :success, capture_download: true)
      ref = make_ref()

      {:ok, _pid} =
        ModelHub.start_download_import(self(), ref, detail.repo_id,
          revision: detail.revision_sha,
          catalog_version: catalog_version,
          activate: false
        )

      assert_receive {:captured_download, _, download_opts}, 2000
      assert download_opts[:revision] == detail.revision_sha
      assert_receive {:model_hub, ^ref, :download_finished, {:ok, result}}, 2000
      assert result.version == catalog_version

      model = Models.get_model_by_identity(detail.repo_id, catalog_version)
      assert {:ok, artifact_path} = Models.artifact_local_path(model)

      evidence =
        artifact_path
        |> Path.join("tool_capability_evidence.json")
        |> File.read!()
        |> Jason.decode!()
        |> Map.fetch!("tool_calling")

      assert evidence["source_revision"] == detail.revision_sha
      assert evidence["result"] == "unknown"
      assert evidence["runtime_qualification"] == "not_established"
    end

    test "rejects a catalog version that matches the source revision before downloading" do
      detail = stub_detail()
      stub_client(detail: {:ok, detail})
      stub_downloader(download: :success, capture_download: true)
      ref = make_ref()

      {:ok, _pid} =
        ModelHub.start_download_import(self(), ref, detail.repo_id,
          revision: detail.revision_sha,
          catalog_version: detail.revision_sha
        )

      assert_receive {:model_hub, ^ref, :download_finished, {:error, error}}, 2000
      assert error.code == "invalid_catalog_version"
      refute_receive {:captured_download, _, _}, 50
    end

    test "rejects an unsafe catalog version before downloading" do
      detail = stub_detail()
      stub_client(detail: {:ok, detail})
      stub_downloader(download: :success, capture_download: true)
      ref = make_ref()

      {:ok, _pid} =
        ModelHub.start_download_import(self(), ref, detail.repo_id,
          revision: detail.revision_sha,
          catalog_version: "../escape"
        )

      assert_receive {:model_hub, ^ref, :download_finished, {:error, error}}, 2000
      assert error.code == "invalid_catalog_version"
      assert error.message =~ "may use only"
      refute_receive {:captured_download, _, _}, 50
    end

    test "rejects an over-long catalog version before downloading" do
      detail = stub_detail()
      stub_client(detail: {:ok, detail})
      stub_downloader(download: :success, capture_download: true)
      ref = make_ref()

      {:ok, _pid} =
        ModelHub.start_download_import(self(), ref, detail.repo_id,
          revision: detail.revision_sha,
          catalog_version: String.duplicate("v", 129)
        )

      assert_receive {:model_hub, ^ref, :download_finished, {:error, error}}, 2000
      assert error.code == "invalid_catalog_version"
      assert error.message =~ "at most 128 characters"
      refute_receive {:captured_download, _, _}, 50
    end

    test "rejects a blank explicit catalog version before downloading" do
      stub_client(detail: {:ok, stub_detail()})
      stub_downloader(download: :success, capture_download: true)
      ref = make_ref()

      {:ok, _pid} =
        ModelHub.start_download_import(self(), ref, "mlx-community/test", catalog_version: "  ")

      assert_receive {:model_hub, ^ref, :download_finished, {:error, error}}, 2000
      assert error.code == "invalid_catalog_version"
      refute_receive {:captured_download, _, _}, 100
    end

    test "normalizes exceptions to download_import_failed" do
      stub_client(detail: {:ok, stub_detail()})
      stub_downloader(download: :raise)

      ref = make_ref()

      log =
        capture_log(fn ->
          {:ok, _pid} = ModelHub.start_download_import(self(), ref, "mlx-community/test")

          assert_receive {:model_hub, ^ref, :download_finished, {:error, error}}, 2000
          assert error.code == "download_import_failed"
          refute_receive {:model_hub, ^ref, :download_finished, _}, 100
        end)

      assert log =~ "ModelHub: pipeline rescued exception"
    end

    test "normalizes thrown values to download_import_failed" do
      stub_client(detail: {:ok, stub_detail()})
      stub_downloader(download: :throw)

      ref = make_ref()

      log =
        capture_log(fn ->
          {:ok, _pid} = ModelHub.start_download_import(self(), ref, "mlx-community/test")

          assert_receive {:model_hub, ^ref, :download_finished, {:error, error}}, 2000
          assert error.code == "download_import_failed"
          refute_receive {:model_hub, ^ref, :download_finished, _}, 100
        end)

      assert log =~ "ModelHub: pipeline caught throw"
    end

    test "normalizes exits to download_import_failed" do
      stub_client(detail: {:ok, stub_detail()})
      stub_downloader(download: :exit)

      ref = make_ref()

      log =
        capture_log(fn ->
          {:ok, _pid} = ModelHub.start_download_import(self(), ref, "mlx-community/test")

          assert_receive {:model_hub, ^ref, :download_finished, {:error, error}}, 2000
          assert error.code == "download_import_failed"
          refute_receive {:model_hub, ^ref, :download_finished, _}, 100
        end)

      assert log =~ "ModelHub: pipeline caught exit"
    end

    test "logs unrecognized downloader errors while preserving generic result" do
      secrets = bearer_secret_samples()
      hf_token = "hf_1234567890abcdef"
      stub_client(detail: {:ok, stub_detail()})

      stub_downloader(
        download:
          {:error,
           {:weird_shape,
            %{
              hf_token: hf_token,
              slash: "Bearer #{secrets.slash}",
              jwt: "Bearer #{secrets.jwt}",
              opaque: "Bearer #{secrets.opaque}",
              sk: "Bearer #{secrets.sk}"
            }}}
      )

      ref = make_ref()

      log =
        capture_log(fn ->
          {:ok, _pid} = ModelHub.start_download_import(self(), ref, "mlx-community/test")

          assert_receive {:model_hub, ^ref, :download_finished, {:error, error}}, 2000
          assert error.code == "download_import_failed"
          refute_receive {:model_hub, ^ref, :download_finished, _}, 100
        end)

      assert log =~ "ModelHub: unrecognized download error"
      assert log =~ "weird_shape"
      assert log =~ ~s(hf_token: "[REDACTED]")
      assert log =~ "Bearer [REDACTED]"
      refute log =~ hf_token
      refute_bearer_secrets(log, secrets)
    end

    test "preserves non-secret bearer prose in unrecognized downloader logs" do
      message = "Bearer authentication is required"
      stub_client(detail: {:ok, stub_detail()})
      stub_downloader(download: {:error, {:weird_shape, %{message: message}}})

      ref = make_ref()

      log =
        capture_log(fn ->
          {:ok, _pid} = ModelHub.start_download_import(self(), ref, "mlx-community/test")

          assert_receive {:model_hub, ^ref, :download_finished, {:error, error}}, 2000
          assert error.code == "download_import_failed"
        end)

      assert log =~ message
      refute log =~ "Bearer [REDACTED]"
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

      if config[:block_search] do
        send(pid, {:blocked_search, self()})

        receive do
          :proceed_search -> :ok
        end
      end

      case config[:search] do
        {:raise, message} -> raise message
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

      if config[:capture_detail_pid] do
        send(pid, {:captured_detail_pid, self()})
      end

      if config[:block_detail] do
        send(pid, {:blocked_detail, self()})

        receive do
          :proceed_detail -> :ok
        end
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

      if config[:capture_download] do
        send(pid, {:captured_download, repo_id, opts})
      end

      if config[:block_download] do
        send(pid, {:blocked_download, self()})

        receive do
          :proceed_download -> :ok
        end
      end

      handle_download_result(config[:download], repo_id, dest_dir, opts)
    end

    defp handle_download_result(:wait_control, _repo_id, _dest_dir, opts) do
      case Keyword.fetch!(opts, :wait_fun).() do
        {:error, {:callback_failed, :cancelled}} -> {:error, {:cancelled, "Cancelled"}}
        result -> result
      end
    end

    defp handle_download_result(:raise, _repo_id, _dest_dir, _opts),
      do: raise("download exploded")

    defp handle_download_result(:throw, _repo_id, _dest_dir, _opts), do: throw(:download_exploded)
    defp handle_download_result(:exit, _repo_id, _dest_dir, _opts), do: exit(:download_exploded)
    defp handle_download_result({:error, _} = err, _repo_id, _dest_dir, _opts), do: err

    defp handle_download_result(result, _repo_id, dest_dir, opts)
         when result in [:success, nil] do
      write_stub_files(dest_dir)
      invoke_callback(opts)
      {:ok, dest_dir, download_summary(opts)}
    end

    defp handle_download_result(result, _repo_id, _dest_dir, _opts), do: result

    defp download_summary(opts) do
      revision = Keyword.get(opts, :revision, "main")
      %{files_downloaded: 2, total_bytes: 100, revision: revision}
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
        # Initial preflight callback → triggers :download_started
        callback.(%{
          files_completed: 0,
          total_files: 2,
          bytes_downloaded: 0,
          total_bytes: 100,
          current_file: nil
        })

        # Mid-file streaming update (simulates in-file byte progress before first completion)
        callback.(%{
          files_completed: 0,
          total_files: 2,
          bytes_downloaded: 30,
          total_bytes: 100,
          current_file: "config.json"
        })

        # File 1 completion callback
        callback.(%{
          files_completed: 1,
          total_files: 2,
          bytes_downloaded: 50,
          total_bytes: 100,
          current_file: "config.json"
        })

        # File 2 completion callback
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

  defp bearer_secret_samples do
    %{
      jwt: "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjMifQ.sig_nature-test",
      opaque: "abcdef1234567890",
      sk: "sk-test-abcdef1234567890",
      slash: "abc/def+ghi="
    }
  end

  defp refute_bearer_secrets(text, samples) do
    samples
    |> Map.values()
    |> Enum.each(fn secret -> refute text =~ secret end)
  end

  defp stub_client(config) do
    ensure_registry()
    Registry.register(__MODULE__.StubRegistry, :client, config)
  end

  defp stub_downloader(config) do
    ensure_registry()
    Registry.register(__MODULE__.StubRegistry, :downloader, config)
  end

  defp stub_detail do
    unique_rev = "rev#{Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)}"

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
