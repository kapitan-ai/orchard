defmodule OrchardConsole.ModelHubDownloadCoordinatorTest do
  use ExUnit.Case, async: false

  alias OrchardConsole.ModelHubDownloadCoordinator, as: Coordinator

  setup do
    previous = Application.get_env(:orchard_controller, :console, [])

    Application.put_env(
      :orchard_controller,
      :console,
      Keyword.merge(previous, model_hub_impl: __MODULE__.ModelHubStub)
    )

    :persistent_term.put({__MODULE__, :test_pid}, self())
    :persistent_term.erase({__MODULE__, :start_download_result})

    Coordinator.reset()

    on_exit(fn ->
      Application.put_env(:orchard_controller, :console, previous)
      Coordinator.reset()
      :persistent_term.erase({__MODULE__, :test_pid})
      :persistent_term.erase({__MODULE__, :start_download_result})
    end)

    :ok
  end

  describe "start_download/2" do
    test "starts download and returns starting snapshot" do
      assert {:ok, snapshot} = Coordinator.start_download("owner/model")

      assert snapshot.repo_id == "owner/model"
      assert snapshot.status == :starting
      assert snapshot.key == {"owner/model", nil}
      assert snapshot.progress.repo_id == "owner/model"
      assert snapshot.result == nil
      assert snapshot.error == nil

      # Verify stub received the call with coordinator as owner
      assert_receive {:stub_download, owner, _ref, "owner/model", opts}, 200
      assert is_pid(owner)
      assert owner == Process.whereis(Coordinator)
      assert opts[:activate] == true
    end

    test "passes revision option through to seam" do
      assert {:ok, snapshot} = Coordinator.start_download("owner/model", revision: "abc123")

      assert snapshot.key == {"owner/model", "abc123"}

      assert_receive {:stub_download, _owner, _ref, "owner/model", opts}, 200
      assert opts[:revision] == "abc123"
    end

    test "trims and normalizes blank revision to nil" do
      assert {:ok, snapshot} = Coordinator.start_download("owner/model", revision: "  ")
      assert snapshot.key == {"owner/model", nil}
    end

    test "deduplicates active download for same repo_id" do
      assert {:ok, first_snapshot} = Coordinator.start_download("owner/model")

      assert {:error, {:already_downloading, existing}} =
               Coordinator.start_download("owner/model")

      assert existing.repo_id == "owner/model"
      assert existing.status == first_snapshot.status

      # Only one stub call
      assert_receive {:stub_download, _, _, "owner/model", _}, 200
      refute_receive {:stub_download, _, _, "owner/model", _}, 50
    end

    test "allows different repo_ids concurrently" do
      assert {:ok, _} = Coordinator.start_download("owner/model-a")
      assert {:ok, _} = Coordinator.start_download("owner/model-b")

      assert_receive {:stub_download, _, _, "owner/model-a", _}, 200
      assert_receive {:stub_download, _, _, "owner/model-b", _}, 200
    end

    test "allows retry after terminal error for same repo_id" do
      assert {:ok, _} = Coordinator.start_download("owner/model")
      assert_receive {:stub_download, _, ref, "owner/model", _}, 200

      # Complete with error
      send_to_coordinator({:model_hub, ref, :download_finished, {:error, %{message: "fail"}}})

      # Now retry should work
      assert {:ok, retry_snapshot} = Coordinator.start_download("owner/model")
      assert retry_snapshot.status == :starting
      assert_receive {:stub_download, _, _, "owner/model", _}, 200
    end

    test "allows retry after terminal success for same repo_id" do
      assert {:ok, _} = Coordinator.start_download("owner/model")
      assert_receive {:stub_download, _, ref, "owner/model", _}, 200

      # Complete with success
      send_to_coordinator({:model_hub, ref, :download_finished, {:ok, %{model_id: "m1"}}})

      # Now retry should work
      assert {:ok, _} = Coordinator.start_download("owner/model")
      assert_receive {:stub_download, _, _, "owner/model", _}, 200
    end

    test "immediate start failure returns error snapshot" do
      :persistent_term.put({__MODULE__, :start_download_result}, :error)

      assert {:error, snapshot} = Coordinator.start_download("owner/model")
      assert snapshot.status == :error
      assert snapshot.error.code == "download_import_failed"
    end

    test "rejects nil repo_id" do
      assert {:error, snapshot} = Coordinator.start_download(nil)
      assert snapshot.status == :error
    end

    test "rejects blank repo_id" do
      assert {:error, snapshot} = Coordinator.start_download("  ")
      assert snapshot.status == :error
    end
  end

  describe "PubSub broadcast" do
    test "broadcasts starting snapshot on successful start" do
      Coordinator.subscribe()
      assert {:ok, _} = Coordinator.start_download("owner/model")

      assert_receive {:model_hub_download, snapshot}, 200
      assert snapshot.status == :starting
      assert snapshot.repo_id == "owner/model"
    end

    test "broadcasts error snapshot on immediate start failure" do
      :persistent_term.put({__MODULE__, :start_download_result}, :error)
      Coordinator.subscribe()

      assert {:error, _} = Coordinator.start_download("owner/model")

      assert_receive {:model_hub_download, snapshot}, 200
      assert snapshot.status == :error
    end
  end

  describe "message normalization" do
    test ":download_started updates to downloading status" do
      Coordinator.subscribe()
      {:ok, _} = Coordinator.start_download("owner/model")
      assert_receive {:stub_download, _, ref, _, _}, 200
      # Drain the starting broadcast
      assert_receive {:model_hub_download, %{status: :starting}}, 200

      send_to_coordinator(
        {:model_hub, ref, :download_started,
         %{repo_id: "owner/model", revision: "abc123", total_files: 10, total_bytes: 4096}}
      )

      assert_receive {:model_hub_download, snapshot}, 200
      assert snapshot.status == :downloading
      assert snapshot.progress.repo_id == "owner/model"
      assert snapshot.progress.revision == "abc123"
      assert snapshot.progress.total_files == 10
      assert snapshot.progress.total_bytes == 4096
      assert snapshot.progress.phase == :downloading
    end

    test ":download_progress maps phases correctly" do
      Coordinator.subscribe()
      {:ok, _} = Coordinator.start_download("owner/model")
      assert_receive {:stub_download, _, ref, _, _}, 200
      assert_receive {:model_hub_download, _}, 200

      # downloading phase
      send_to_coordinator(
        {:model_hub, ref, :download_progress,
         %{
           phase: :downloading,
           files_completed: 3,
           total_files: 10,
           bytes_downloaded: 512,
           total_bytes: 4096
         }}
      )

      assert_receive {:model_hub_download, snapshot}, 200
      assert snapshot.status == :downloading
      assert snapshot.progress.files_completed == 3

      # preparing_bundle phase → :preparing status
      send_to_coordinator(
        {:model_hub, ref, :download_progress,
         %{
           phase: :preparing_bundle,
           files_completed: 10,
           total_files: 10,
           bytes_downloaded: 4096,
           total_bytes: 4096
         }}
      )

      assert_receive {:model_hub_download, snapshot}, 200
      assert snapshot.status == :preparing

      # importing phase
      send_to_coordinator(
        {:model_hub, ref, :download_progress,
         %{
           phase: :importing,
           files_completed: 10,
           total_files: 10,
           bytes_downloaded: 4096,
           total_bytes: 4096
         }}
      )

      assert_receive {:model_hub_download, snapshot}, 200
      assert snapshot.status == :importing
    end

    test ":download_finished {:ok, ...} sets completed" do
      Coordinator.subscribe()
      {:ok, _} = Coordinator.start_download("owner/model")
      assert_receive {:stub_download, _, ref, _, _}, 200
      assert_receive {:model_hub_download, _}, 200

      result = %{model_id: "owner/model", version: "v1", state: :active}
      send_to_coordinator({:model_hub, ref, :download_finished, {:ok, result}})

      assert_receive {:model_hub_download, snapshot}, 200
      assert snapshot.status == :completed
      assert snapshot.result == result
      assert snapshot.error == nil
    end

    test ":download_finished {:error, ...} sets error" do
      Coordinator.subscribe()
      {:ok, _} = Coordinator.start_download("owner/model")
      assert_receive {:stub_download, _, ref, _, _}, 200
      assert_receive {:model_hub_download, _}, 200

      error = %{status: :error, code: "hf_error", message: "Failed."}
      send_to_coordinator({:model_hub, ref, :download_finished, {:error, error}})

      assert_receive {:model_hub_download, snapshot}, 200
      assert snapshot.status == :error
      assert snapshot.error == error
      assert snapshot.result == nil
    end

    test "ignores messages for unknown refs" do
      Coordinator.subscribe()
      stale_ref = make_ref()

      send_to_coordinator({:model_hub, stale_ref, :download_started, %{repo_id: "unknown/model"}})

      refute_receive {:model_hub_download, _}, 100
    end

    test "ignores messages for terminal jobs" do
      Coordinator.subscribe()
      {:ok, _} = Coordinator.start_download("owner/model")
      assert_receive {:stub_download, _, ref, _, _}, 200
      assert_receive {:model_hub_download, _}, 200

      # Complete the job
      send_to_coordinator({:model_hub, ref, :download_finished, {:ok, %{model_id: "m1"}}})
      assert_receive {:model_hub_download, %{status: :completed}}, 200

      # Stale messages after terminal should be ignored
      send_to_coordinator({:model_hub, ref, :download_progress, %{phase: :downloading}})
      refute_receive {:model_hub_download, _}, 100
    end
  end

  describe "crash handling" do
    test "task crash produces error snapshot" do
      Coordinator.subscribe()
      {:ok, _} = Coordinator.start_download("owner/model")
      assert_receive {:stub_download, _, _ref, _, _}, 200
      assert_receive {:stub_download_pid, pid}, 200
      assert_receive {:model_hub_download, %{status: :starting}}, 200

      # Kill the task
      Process.exit(pid, :kill)

      assert_receive {:model_hub_download, snapshot}, 500
      assert snapshot.status == :error
      assert snapshot.error.code == "download_import_failed"
    end

    test "crash after terminal completion is ignored" do
      Coordinator.subscribe()
      {:ok, _} = Coordinator.start_download("owner/model")
      assert_receive {:stub_download, _, ref, _, _}, 200
      assert_receive {:stub_download_pid, pid}, 200
      assert_receive {:model_hub_download, _}, 200

      # Complete first
      send_to_coordinator({:model_hub, ref, :download_finished, {:ok, %{model_id: "m1"}}})
      assert_receive {:model_hub_download, %{status: :completed}}, 200

      # Then kill task — should not produce error
      Process.exit(pid, :kill)
      refute_receive {:model_hub_download, %{status: :error}}, 200
    end
  end

  describe "snapshot queries" do
    test "latest_snapshot/0 returns nil when no jobs" do
      assert Coordinator.latest_snapshot() == nil
    end

    test "latest_snapshot/0 returns most recent snapshot" do
      {:ok, snapshot} = Coordinator.start_download("owner/model")
      assert Coordinator.latest_snapshot() == snapshot
    end

    test "latest_snapshot_for_repo/1 returns nil for unknown repo" do
      assert Coordinator.latest_snapshot_for_repo("unknown/repo") == nil
    end

    test "latest_snapshot_for_repo/1 returns snapshot for known repo" do
      {:ok, _} = Coordinator.start_download("owner/model")
      snapshot = Coordinator.latest_snapshot_for_repo("owner/model")
      assert snapshot != nil
      assert snapshot.repo_id == "owner/model"
    end

    test "latest_snapshot updates as messages arrive" do
      {:ok, _} = Coordinator.start_download("owner/model")
      assert_receive {:stub_download, _, ref, _, _}, 200

      send_to_coordinator(
        {:model_hub, ref, :download_started,
         %{repo_id: "owner/model", revision: "abc", total_files: 5, total_bytes: 1024}}
      )

      snapshot = Coordinator.latest_snapshot()
      assert snapshot.status == :downloading
    end
  end

  describe "reset/0" do
    test "clears all state" do
      {:ok, _} = Coordinator.start_download("owner/model")
      assert Coordinator.latest_snapshot() != nil

      Coordinator.reset()

      assert Coordinator.latest_snapshot() == nil
      assert Coordinator.latest_snapshot_for_repo("owner/model") == nil
    end

    test "allows fresh start after reset" do
      {:ok, _} = Coordinator.start_download("owner/model")
      Coordinator.reset()

      assert {:ok, _} = Coordinator.start_download("owner/model")
    end
  end

  describe "topic/0" do
    test "returns expected topic string" do
      assert Coordinator.topic() == "console:model_hub:downloads"
    end
  end

  # ===========================================================================
  # Test stub
  # ===========================================================================

  defp send_to_coordinator(msg) do
    send(Process.whereis(Coordinator), msg)
    # Synchronous drain to ensure coordinator processes message
    Coordinator.latest_snapshot()
  end

  defmodule ModelHubStub do
    def start_search(_owner, _ref, _query), do: {:ok, spawn(fn -> Process.sleep(:infinity) end)}
    def start_detail(_owner, _ref, _repo_id), do: {:ok, spawn(fn -> Process.sleep(:infinity) end)}

    def start_download_import(owner, ref, repo_id, opts) do
      test_pid =
        :persistent_term.get({OrchardConsole.ModelHubDownloadCoordinatorTest, :test_pid}, nil)

      case :persistent_term.get(
             {OrchardConsole.ModelHubDownloadCoordinatorTest, :start_download_result},
             :ok
           ) do
        :ok ->
          pid = spawn(fn -> Process.sleep(:infinity) end)

          if test_pid do
            send(test_pid, {:stub_download, owner, ref, repo_id, opts})
            send(test_pid, {:stub_download_pid, pid})
          end

          {:ok, pid}

        other ->
          other
      end
    end
  end
end
