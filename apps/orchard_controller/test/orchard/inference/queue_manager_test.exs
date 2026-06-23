defmodule Orchard.Inference.QueueManagerTest do
  use Orchard.DataCase, async: false

  import Orchard.TestSupport.QueueAdmissionAPI,
    only: [assert_queue_metadata: 2, assert_queue_metadata: 3]

  alias Orchard.Inference.QueueManager
  alias Orchard.Requests
  alias Orchard.Requests.{Request, RequestServer}

  setup do
    QueueManager.reset()
    :ok
  end

  test "grants one active request per model lane and releases idempotently" do
    request = admission_request("req-a")

    assert {:ok, grant} = QueueManager.acquire(request, config: queue_config())
    assert grant.queue_result == :immediate
    assert grant.queue_key == "queue-model@v1"

    assert {:queued, ticket} =
             QueueManager.acquire(admission_request("req-b"), config: queue_config())

    assert :ok = QueueManager.release(grant)
    assert {:ok, queued_grant} = QueueManager.await(ticket)
    assert queued_grant.queue_result == :queued
    assert queued_grant.queued_at != nil

    assert :ok = QueueManager.release(grant)
    assert :ok = QueueManager.release(queued_grant)
    assert :ok = QueueManager.release(queued_grant)
  end

  test "capacity two admits two active requests and queues the third" do
    with_queue_admission_config(queue_config(capacity: 2, max_wait_ms: 1_000), fn ->
      assert {:ok, first_grant} = QueueManager.acquire(admission_request("req-capacity2-a"))
      assert first_grant.queue_result == :immediate

      assert {:ok, second_grant} = QueueManager.acquire(admission_request("req-capacity2-b"))
      assert second_grant.queue_result == :immediate

      assert {:queued, third_ticket} = QueueManager.acquire(admission_request("req-capacity2-c"))

      assert :ok = QueueManager.release(first_grant)
      assert {:ok, third_grant} = QueueManager.await(third_ticket)
      assert third_grant.queue_result == :queued
      assert third_grant.queued_at != nil

      assert :ok = QueueManager.release(second_grant)
      assert :ok = QueueManager.release(third_grant)
    end)
  end

  test "SPEC.md §3.6 immediate grant holder death releases lane before explicit release" do
    db_request = create_request!("req_queue_immediate_holder_death", state: :admitted)

    {:ok, _pid} =
      RequestServer.start(
        request_id: db_request.id,
        public_id: db_request.public_id,
        initial_state: :admitted
      )

    caller = spawn(fn -> Process.sleep(:infinity) end)

    assert {:ok, grant} =
             QueueManager.acquire(
               admission_request("req-a",
                 request_id: db_request.id,
                 public_id: db_request.public_id,
                 caller_pid: caller
               ),
               config: queue_config()
             )

    assert grant.queue_result == :immediate

    Process.exit(caller, :kill)
    assert wait_until(fn -> Requests.get_request!(db_request.id).state == :cancelled end)

    request = Requests.get_request!(db_request.id)
    assert request.error_code == "request_caller_disconnect"
    assert_queue_metadata(request, "interrupted_before_dispatch")

    assert {:ok, next_grant} =
             QueueManager.acquire(admission_request("req-c"), config: queue_config())

    assert next_grant.queue_result == :immediate
    assert :ok = QueueManager.release(next_grant)
    assert :ok = QueueManager.release(grant)
  end

  test "SPEC.md §3.6 scheduled grant-owner death parks lane until terminal" do
    assert_in_flight_owner_death_parks_until_terminal(:scheduled)
  end

  test "SPEC.md §3.6 dispatching grant-owner death parks lane until terminal" do
    assert_in_flight_owner_death_parks_until_terminal(:dispatching)
  end

  test "SPEC.md §3.6 running grant-owner death parks lane until terminal" do
    assert_in_flight_owner_death_parks_until_terminal(:running)
  end

  test "SPEC.md §3.6 streaming grant-owner death parks lane until terminal" do
    assert_in_flight_owner_death_parks_until_terminal(:streaming)
  end

  test "grant and ticket calls resolve a restarted named manager" do
    manager = unique_manager_name()
    manager_pid = start_supervised!({QueueManager, name: manager, owner_runtime: false})

    assert {:ok, grant} =
             QueueManager.acquire(admission_request("req-stable-grant"),
               server: manager,
               config: queue_config()
             )

    assert grant.server == manager

    assert {:queued, ticket} =
             QueueManager.acquire(admission_request("req-stable-ticket"),
               server: manager,
               config: queue_config(max_wait_ms: 500)
             )

    assert ticket.server == manager

    Process.exit(manager_pid, :kill)
    assert wait_until(fn -> manager_restarted?(manager, manager_pid) end)

    assert :ok = QueueManager.release(grant)
    assert {:error, :queue_timeout, metadata} = QueueManager.await(ticket)
    assert metadata.queue_result == :queue_timeout
  end

  test "blocked await resolves through a restarted named manager" do
    manager = unique_manager_name()
    manager_pid = start_supervised!({QueueManager, name: manager, owner_runtime: false})

    assert {:ok, grant} =
             QueueManager.acquire(admission_request("req-await-held"),
               server: manager,
               config: queue_config()
             )

    assert {:queued, ticket} =
             QueueManager.acquire(admission_request("req-await-restarted"),
               server: manager,
               config: queue_config(max_wait_ms: 500)
             )

    awaiter = Task.async(fn -> QueueManager.await(ticket) end)
    assert wait_until(fn -> queue_entry_awaiting?(ticket, manager) end)

    Process.exit(manager_pid, :kill)
    assert wait_until(fn -> manager_restarted?(manager, manager_pid) end)

    assert {:error, :queue_timeout, metadata} = Task.await(awaiter, 2_000)
    assert metadata.queue_result == :queue_timeout
    assert :ok = QueueManager.release(grant)
  end

  test "acquire resolves through a restarted named manager" do
    manager = unique_manager_name()
    manager_pid = start_supervised!({QueueManager, name: manager, owner_runtime: false})

    :ok = :sys.suspend(manager)

    acquire_task =
      Task.async(fn ->
        QueueManager.acquire(admission_request("req-acquire-restarted"),
          server: manager,
          config: queue_config()
        )
      end)

    Process.sleep(20)
    Process.exit(manager_pid, :kill)
    assert wait_until(fn -> manager_restarted?(manager, manager_pid) end)

    assert {:ok, grant} = Task.await(acquire_task, 2_000)
    assert grant.queue_result == :immediate
    assert grant.server == manager
    assert :ok = QueueManager.release(grant)
  end

  test "returns queue_full when tenant queued cap is exhausted" do
    assert {:ok, grant} = QueueManager.acquire(admission_request("req-a"), config: queue_config())

    assert {:error, :queue_full, metadata} =
             QueueManager.acquire(admission_request("req-b"),
               config: Keyword.put(queue_config(), :max_queued_per_tenant, 0)
             )

    assert metadata.queueing_enabled == true
    assert metadata.queue_key == "queue-model@v1"
    assert metadata.queue_result == :queue_full
    assert :ok = QueueManager.release(grant)
  end

  test "bounded queued waits return queue_timeout metadata" do
    assert {:ok, grant} = QueueManager.acquire(admission_request("req-a"), config: queue_config())

    assert {:queued, ticket} =
             QueueManager.acquire(admission_request("req-b"),
               config: Keyword.put(queue_config(), :max_wait_ms, 10)
             )

    assert {:error, :queue_timeout, metadata} = QueueManager.await(ticket)
    assert metadata.queue_result == :queue_timeout
    assert metadata.queued_at != nil
    assert metadata.queue_wait_ms >= 0
    refute ticket_result?(ticket)

    assert :ok = QueueManager.release(grant)
  end

  test "pre-await queue timeout result is retained until consumed" do
    db_request = create_request!("req_queue_timeout_pre_await")
    {:ok, _pid} = RequestServer.start(request_id: db_request.id, public_id: db_request.public_id)

    assert {:ok, grant} = QueueManager.acquire(admission_request("req-a"), config: queue_config())

    assert {:queued, ticket} =
             QueueManager.acquire(
               admission_request("req-b",
                 request_id: db_request.id,
                 public_id: db_request.public_id
               ),
               config: Keyword.put(queue_config(), :max_wait_ms, 10)
             )

    assert wait_until(fn -> Requests.get_request!(db_request.id).state == :timed_out end)
    assert ticket_result?(ticket)

    assert {:error, :queue_timeout, metadata} = QueueManager.await(ticket)
    assert metadata.queue_result == :queue_timeout
    refute ticket_result?(ticket)

    assert :ok = QueueManager.release(grant)
  end

  test "SPEC.md §3.6 queue timeout persistence failure retains queue until retry succeeds" do
    request_id = Ecto.UUID.generate()
    public_id = "req_queue_timeout_persistence_retry"

    assert {:ok, held_grant} =
             QueueManager.acquire(admission_request("req-timeout-retry-held"),
               config: queue_config()
             )

    assert {:queued, timeout_ticket} =
             QueueManager.acquire(
               admission_request("req-timeout-retry",
                 request_id: request_id,
                 public_id: public_id
               ),
               config: queue_config(max_wait_ms: 20, poll_interval_ms: 50)
             )

    assert {:queued, next_ticket} =
             QueueManager.acquire(admission_request("req-timeout-retry-next"),
               config: queue_config(max_wait_ms: 2_000)
             )

    next_awaiter = Task.async(fn -> QueueManager.await(next_ticket) end)
    assert wait_until(fn -> queue_entry_awaiting?(next_ticket) end)
    assert wait_until(fn -> queue_entry_terminal_pending?(timeout_ticket) end)
    assert :ok = QueueManager.abandon(timeout_ticket)
    assert queue_entry_terminal_pending?(timeout_ticket)

    assert :ok = QueueManager.release(held_grant)
    refute Task.yield(next_awaiter, 100)

    db_request = insert_request_with_id!(request_id, public_id, state: :queued)

    assert wait_until(fn -> Requests.get_request!(db_request.id).state == :timed_out end)
    assert {:error, :queue_timeout, metadata} = QueueManager.await(timeout_ticket)
    assert metadata.queue_result == :queue_timeout

    request = Requests.get_request!(db_request.id)
    assert request.error_code == "queue_timeout"
    assert_queue_metadata(request, "queue_timeout", queued?: true)

    assert {:ok, next_grant} = Task.await(next_awaiter, 2_000)
    assert next_grant.queue_result == :queued
    assert :ok = QueueManager.release(next_grant)
  end

  test "SPEC.md §3.6 timeout persistence retry keeps timeout after caller death" do
    request_id = Ecto.UUID.generate()
    public_id = "req_queue_timeout_retry_then_disconnect"
    caller = spawn(fn -> Process.sleep(:infinity) end)

    assert {:ok, held_grant} =
             QueueManager.acquire(admission_request("req-timeout-retry-death-held"),
               config: queue_config()
             )

    assert {:queued, timeout_ticket} =
             QueueManager.acquire(
               admission_request("req-timeout-retry-death",
                 request_id: request_id,
                 public_id: public_id,
                 caller_pid: caller
               ),
               config: queue_config(max_wait_ms: 20, poll_interval_ms: 50)
             )

    assert wait_until(fn -> queue_entry_terminal_pending?(timeout_ticket) end)
    Process.exit(caller, :kill)
    assert wait_until(fn -> queue_entry_terminal_pending?(timeout_ticket) end)

    db_request = insert_request_with_id!(request_id, public_id, state: :queued)

    assert wait_until(fn -> Requests.get_request!(db_request.id).state == :timed_out end)
    assert {:error, :queue_timeout, metadata} = QueueManager.await(timeout_ticket)
    assert metadata.queue_result == :queue_timeout

    request = Requests.get_request!(db_request.id)
    assert request.error_code == "queue_timeout"
    assert_queue_metadata(request, "queue_timeout", queued?: true)

    assert :ok = QueueManager.release(held_grant)
  end

  test "SPEC.md §3.6 queue timeout terminalizes when RequestServer is missing or terminal" do
    Enum.each([:missing_request_server, :already_terminal_request_server], fn mode ->
      db_request = create_request!("req_queue_timeout_#{mode}", state: :queued)

      if mode == :already_terminal_request_server do
        {:ok, _pid} =
          RequestServer.start(
            request_id: db_request.id,
            public_id: db_request.public_id,
            initial_state: :timed_out
          )
      end

      assert {:ok, grant} =
               QueueManager.acquire(admission_request("req-timeout-held-#{mode}"),
                 config: queue_config()
               )

      assert {:queued, ticket} =
               QueueManager.acquire(
                 admission_request("req-timeout-#{mode}",
                   request_id: db_request.id,
                   public_id: db_request.public_id
                 ),
                 config: Keyword.put(queue_config(), :max_wait_ms, 10)
               )

      assert {:error, :queue_timeout, metadata} = QueueManager.await(ticket)
      assert metadata.queue_result == :queue_timeout

      request = Requests.get_request!(db_request.id)
      assert request.state == :timed_out
      assert request.error_code == "queue_timeout"
      assert_queue_metadata(request, "queue_timeout", queued?: true)

      assert :ok = QueueManager.release(grant)
    end)
  end

  test "queued caller disconnect is removed and terminalized before dispatch" do
    db_request = create_request!("req_queue_disconnect")
    {:ok, _pid} = RequestServer.start(request_id: db_request.id, public_id: db_request.public_id)

    assert {:ok, grant} = QueueManager.acquire(admission_request("req-a"), config: queue_config())

    caller = spawn(fn -> Process.sleep(:infinity) end)

    assert {:queued, ticket} =
             QueueManager.acquire(
               admission_request("req-b",
                 request_id: db_request.id,
                 public_id: db_request.public_id,
                 caller_pid: caller
               ),
               config: queue_config()
             )

    Process.exit(caller, :kill)
    assert wait_until(fn -> Requests.get_request!(db_request.id).state == :cancelled end)

    assert {:error, :request_caller_disconnect, metadata} = QueueManager.await(ticket)
    assert metadata.queue_result == :interrupted_before_dispatch
    assert metadata.queued_at != nil
    refute ticket_result?(ticket)

    request = Requests.get_request!(db_request.id)
    assert request.state == :cancelled
    assert request.error_code == "request_caller_disconnect"
    assert_queue_metadata(request, "interrupted_before_dispatch", queued?: true)

    assert :ok = QueueManager.release(grant)
  end

  test "SPEC.md §3.6 queued disconnect persistence failure retains queue until retry succeeds" do
    request_id = Ecto.UUID.generate()
    public_id = "req_queue_disconnect_persistence_retry"

    assert {:ok, held_grant} =
             QueueManager.acquire(admission_request("req-disconnect-retry-held"),
               config: queue_config()
             )

    caller = spawn(fn -> Process.sleep(:infinity) end)

    assert {:queued, disconnect_ticket} =
             QueueManager.acquire(
               admission_request("req-disconnect-retry",
                 request_id: request_id,
                 public_id: public_id,
                 caller_pid: caller
               ),
               config: queue_config(poll_interval_ms: 50)
             )

    assert {:queued, next_ticket} =
             QueueManager.acquire(admission_request("req-disconnect-retry-next"),
               config: queue_config(max_wait_ms: 2_000)
             )

    next_awaiter = Task.async(fn -> QueueManager.await(next_ticket) end)
    assert wait_until(fn -> queue_entry_awaiting?(next_ticket) end)

    Process.exit(caller, :kill)
    assert wait_until(fn -> queue_entry_terminal_pending?(disconnect_ticket) end)

    assert :ok = QueueManager.release(held_grant)
    refute Task.yield(next_awaiter, 100)

    db_request = insert_request_with_id!(request_id, public_id, state: :queued)

    assert wait_until(fn -> Requests.get_request!(db_request.id).state == :cancelled end)

    assert {:error, :request_caller_disconnect, metadata} =
             QueueManager.await(disconnect_ticket)

    assert metadata.queue_result == :interrupted_before_dispatch

    request = Requests.get_request!(db_request.id)
    assert request.error_code == "request_caller_disconnect"
    assert_queue_metadata(request, "interrupted_before_dispatch", queued?: true)

    assert {:ok, next_grant} = Task.await(next_awaiter, 2_000)
    assert next_grant.queue_result == :queued
    assert :ok = QueueManager.release(next_grant)
  end

  test "SPEC.md §3.6 disconnect persistence retry keeps disconnect after timeout" do
    request_id = Ecto.UUID.generate()
    public_id = "req_queue_disconnect_retry_then_timeout"

    assert {:ok, held_grant} =
             QueueManager.acquire(admission_request("req-disconnect-retry-timeout-held"),
               config: queue_config()
             )

    caller = spawn(fn -> Process.sleep(:infinity) end)

    assert {:queued, disconnect_ticket} =
             QueueManager.acquire(
               admission_request("req-disconnect-retry-timeout",
                 request_id: request_id,
                 public_id: public_id,
                 caller_pid: caller
               ),
               config: queue_config(max_wait_ms: 50, poll_interval_ms: 50)
             )

    Process.exit(caller, :kill)
    assert wait_until(fn -> queue_entry_terminal_pending?(disconnect_ticket) end)
    Process.sleep(80)
    assert queue_entry_terminal_pending?(disconnect_ticket)

    db_request = insert_request_with_id!(request_id, public_id, state: :queued)

    assert wait_until(fn -> Requests.get_request!(db_request.id).state == :cancelled end)

    assert {:error, :request_caller_disconnect, metadata} =
             QueueManager.await(disconnect_ticket)

    assert metadata.queue_result == :interrupted_before_dispatch

    request = Requests.get_request!(db_request.id)
    assert request.error_code == "request_caller_disconnect"
    assert_queue_metadata(request, "interrupted_before_dispatch", queued?: true)

    assert :ok = QueueManager.release(held_grant)
  end

  test "SPEC.md §3.6 queued caller disconnect terminalizes when RequestServer is missing or terminal" do
    Enum.each([:missing_request_server, :already_terminal_request_server], fn mode ->
      db_request = create_request!("req_queue_disconnect_#{mode}", state: :queued)

      if mode == :already_terminal_request_server do
        {:ok, _pid} =
          RequestServer.start(
            request_id: db_request.id,
            public_id: db_request.public_id,
            initial_state: :cancelled
          )
      end

      assert {:ok, grant} =
               QueueManager.acquire(admission_request("req-disconnect-held-#{mode}"),
                 config: queue_config()
               )

      caller = spawn(fn -> Process.sleep(:infinity) end)

      assert {:queued, ticket} =
               QueueManager.acquire(
                 admission_request("req-disconnect-#{mode}",
                   request_id: db_request.id,
                   public_id: db_request.public_id,
                   caller_pid: caller
                 ),
                 config: queue_config()
               )

      Process.exit(caller, :kill)
      assert wait_until(fn -> Requests.get_request!(db_request.id).state == :cancelled end)

      assert {:error, :request_caller_disconnect, metadata} = QueueManager.await(ticket)
      assert metadata.queue_result == :interrupted_before_dispatch

      request = Requests.get_request!(db_request.id)
      assert request.error_code == "request_caller_disconnect"
      assert_queue_metadata(request, "interrupted_before_dispatch", queued?: true)

      assert :ok = QueueManager.release(grant)
    end)
  end

  test "startup reconciliation interrupts stale pre-dispatch requests" do
    admitted =
      create_request!("req_queue_restarted_admitted",
        state: :admitted,
        scheduler_decision: %{queueing_enabled: true, queue_key: "queue-model@v1"}
      )

    queued =
      create_request!("req_queue_restarted_queued",
        state: :queued,
        scheduler_decision: %{
          queueing_enabled: true,
          queue_key: "queue-model@v1",
          queued_at: DateTime.utc_now() |> DateTime.to_iso8601()
        }
      )

    start_supervised!({QueueManager, name: unique_manager_name(), owner_runtime: true})

    admitted = Requests.get_request!(admitted.id)
    queued = Requests.get_request!(queued.id)

    assert admitted.state == :interrupted
    assert admitted.error_code == "request_controller_restarted"
    assert_queue_metadata(admitted, "interrupted_controller_restarted")

    assert queued.state == :interrupted
    assert queued.error_code == "request_controller_restarted"
    assert_queue_metadata(queued, "interrupted_controller_restarted", queued?: true)
  end

  test "startup reconciliation is gated behind owner runtime flag" do
    admitted =
      create_request!("req_queue_non_owner_admitted",
        state: :admitted,
        scheduler_decision: %{queueing_enabled: true, queue_key: "queue-model@v1"}
      )

    start_supervised!({QueueManager, name: unique_manager_name(), owner_runtime: false})

    admitted = Requests.get_request!(admitted.id)
    assert admitted.state == :admitted
    assert admitted.error_code == nil
  end

  test "startup reconciliation reclaims pre-dispatch rows after boot-token child restart" do
    boot_token = {__MODULE__, System.unique_integer([:positive])}

    stale =
      create_request!("req_queue_boot_token_stale",
        state: :admitted,
        scheduler_decision: %{queueing_enabled: true, queue_key: "queue-model@v1"}
      )

    create_request!("req_queue_boot_token_running",
      state: :running,
      scheduler_decision: %{
        queueing_enabled: true,
        queue_key: "queue-model@v1",
        queue_result: "immediate",
        queue_grant_id: "grant-boot-token-running",
        queue_granted_at: DateTime.utc_now() |> DateTime.to_iso8601()
      }
    )

    manager = unique_manager_name()

    manager_pid =
      start_supervised!(
        {QueueManager,
         name: manager, owner_runtime: true, startup_reconciliation: {:once, boot_token}}
      )

    stale = Requests.get_request!(stale.id)
    assert stale.state == :interrupted
    assert stale.error_code == "request_controller_restarted"

    live =
      create_request!("req_queue_boot_token_child_restart",
        state: :queued,
        scheduler_decision: pre_dispatch_scheduler_decision(:queued)
      )

    {:ok, _pid} =
      RequestServer.start(
        request_id: live.id,
        public_id: live.public_id,
        initial_state: :queued
      )

    Process.exit(manager_pid, :kill)
    assert wait_until(fn -> manager_restarted?(manager, manager_pid) end)

    live = Requests.get_request!(live.id)
    assert live.state == :interrupted
    assert live.error_code == "request_controller_restarted"
    assert_queue_metadata(live, "interrupted_controller_restarted", queued?: true)

    assert :ok = QueueManager.release("grant-boot-token-running", server: manager)

    assert {:ok, grant} =
             QueueManager.acquire(admission_request("req-after-child-restart"),
               server: manager,
               config: queue_config(max_wait_ms: 500)
             )

    assert grant.queue_result == :immediate
    assert :ok = QueueManager.release(grant)
  end

  test "startup reconciliation interrupts pre-dispatch rows after child restart" do
    assert_pre_dispatch_interrupted_after_child_restart(:admitted)
    assert_pre_dispatch_interrupted_after_child_restart(:queued)
  end

  test "startup reconciliation reconstructs active grant ownership" do
    create_request!("req_queue_recovered_active",
      state: :scheduled,
      scheduler_decision: %{
        queueing_enabled: true,
        queue_key: "queue-model@v1",
        queue_result: "immediate",
        queue_grant_id: "grant-recovered",
        queue_granted_at: DateTime.utc_now() |> DateTime.to_iso8601()
      }
    )

    manager = unique_manager_name()
    start_supervised!({QueueManager, name: manager, owner_runtime: true})

    assert {:queued, ticket} =
             QueueManager.acquire(admission_request("req-after-restart"),
               server: manager,
               config: queue_config(max_wait_ms: 200)
             )

    assert :ok = QueueManager.release("grant-recovered", server: manager)
    assert {:ok, grant} = QueueManager.await(ticket)
    assert grant.queue_result == :queued

    assert :ok = QueueManager.release(grant)
  end

  test "reconstructed legacy in-flight lane remains occupied until terminal" do
    request =
      create_request!("req_queue_recovered_legacy",
        state: :running,
        scheduler_decision: %{strategy: "single_node"}
      )

    manager = unique_manager_name()
    start_supervised!({QueueManager, name: manager, owner_runtime: true})

    assert {:queued, ticket} =
             QueueManager.acquire(admission_request("req-after-legacy-recovery"),
               server: manager,
               config: queue_config(max_wait_ms: 500)
             )

    assert {:ok, _request} =
             Requests.mark_terminal(request, %{state: :completed, output_tokens: 1})

    assert {:ok, grant} = QueueManager.await(ticket)
    assert grant.queue_result == :queued

    assert :ok = QueueManager.release(grant)
  end

  test "await timeout removes queued entry before later lane release" do
    assert {:ok, grant} = QueueManager.acquire(admission_request("req-a"), config: queue_config())

    assert {:queued, ticket} =
             QueueManager.acquire(admission_request("req-b"),
               config: Keyword.put(queue_config(), :max_wait_ms, 10)
             )

    assert {:error, :queue_timeout, metadata} = QueueManager.await(ticket)
    assert metadata.queue_result == :queue_timeout

    assert :ok = QueueManager.release(grant)

    assert {:ok, next_grant} =
             QueueManager.acquire(admission_request("req-c"), config: queue_config())

    assert next_grant.queue_result == :immediate
    assert :ok = QueueManager.release(next_grant)
  end

  test "abandoned awaiter removes queued entry and terminalizes before dispatch" do
    db_request = create_request!("req_queue_abandoned_waiter")
    {:ok, _pid} = RequestServer.start(request_id: db_request.id, public_id: db_request.public_id)

    assert {:ok, grant} = QueueManager.acquire(admission_request("req-a"), config: queue_config())

    caller = spawn(fn -> Process.sleep(:infinity) end)

    assert {:queued, ticket} =
             QueueManager.acquire(
               admission_request("req-b",
                 request_id: db_request.id,
                 public_id: db_request.public_id,
                 caller_pid: caller
               ),
               config: queue_config()
             )

    awaiter = spawn(fn -> QueueManager.await(ticket) end)
    assert Process.alive?(awaiter)
    assert wait_until(fn -> queue_entry_awaiting?(ticket) end)
    Process.exit(awaiter, :kill)

    assert wait_until(fn ->
             request = Requests.get_request!(db_request.id)
             request.state == :cancelled and request.error_code == "request_caller_disconnect"
           end)

    request = Requests.get_request!(db_request.id)
    assert request.error_code == "request_caller_disconnect"
    assert_queue_metadata(request, "interrupted_before_dispatch", queued?: true)

    assert :ok = QueueManager.release(grant)

    assert {:ok, next_grant} =
             QueueManager.acquire(admission_request("req-c"), config: queue_config())

    assert :ok = QueueManager.release(next_grant)

    Process.exit(caller, :kill)
  end

  test "SPEC.md §3.6 release before dead awaiter DOWN cancels without active grant" do
    db_request = create_request!("req_queue_dead_waiter_grant", state: :queued)

    {:ok, _pid} =
      RequestServer.start(
        request_id: db_request.id,
        public_id: db_request.public_id,
        initial_state: :queued
      )

    assert {:ok, grant} = QueueManager.acquire(admission_request("req-a"), config: queue_config())

    caller = spawn(fn -> Process.sleep(:infinity) end)

    assert {:queued, ticket} =
             QueueManager.acquire(
               admission_request("req-b",
                 request_id: db_request.id,
                 public_id: db_request.public_id,
                 caller_pid: caller
               ),
               config: queue_config(max_wait_ms: 1_000)
             )

    awaiter = spawn(fn -> QueueManager.await(ticket) end)
    assert wait_until(fn -> queue_entry_awaiting?(ticket) end)

    :ok = :sys.suspend(QueueManager)

    try do
      release_task =
        Task.async(fn ->
          QueueManager.release(grant)
        end)

      Process.sleep(20)
      Process.exit(awaiter, :kill)
      resume_manager(QueueManager)

      assert :ok = Task.await(release_task, 2_000)
      assert wait_until(fn -> Requests.get_request!(db_request.id).state == :cancelled end)

      request = Requests.get_request!(db_request.id)
      assert request.error_code == "request_caller_disconnect"
      assert_queue_metadata(request, "interrupted_before_dispatch", queued?: true)

      assert {:ok, next_grant} =
               QueueManager.acquire(admission_request("req-c"), config: queue_config())

      assert :ok = QueueManager.release(next_grant)

      Process.exit(caller, :kill)
    after
      resume_manager(QueueManager)
    end
  end

  test "SPEC.md §3.6 pre-dispatch grant-owner disconnect terminalizes when RequestServer is missing or terminal" do
    Enum.each([:missing_request_server, :already_terminal_request_server], fn mode ->
      db_request = create_request!("req_queue_grant_owner_disconnect_#{mode}", state: :admitted)

      if mode == :already_terminal_request_server do
        {:ok, _pid} =
          RequestServer.start(
            request_id: db_request.id,
            public_id: db_request.public_id,
            initial_state: :cancelled
          )
      end

      caller = spawn(fn -> Process.sleep(:infinity) end)

      assert {:ok, grant} =
               QueueManager.acquire(
                 admission_request("req-grant-owner-disconnect-#{mode}",
                   request_id: db_request.id,
                   public_id: db_request.public_id,
                   caller_pid: caller
                 ),
                 config: queue_config()
               )

      Process.exit(caller, :kill)
      assert wait_until(fn -> Requests.get_request!(db_request.id).state == :cancelled end)

      request = Requests.get_request!(db_request.id)
      assert request.error_code == "request_caller_disconnect"
      assert_queue_metadata(request, "interrupted_before_dispatch")

      assert {:ok, next_grant} =
               QueueManager.acquire(admission_request("req-after-grant-owner-#{mode}"),
                 config: queue_config()
               )

      assert :ok = QueueManager.release(next_grant)
      assert :ok = QueueManager.release(grant)
    end)
  end

  test "SPEC.md §3.6 awaiter death after queued grant drops grant and cancels" do
    db_request = create_request!("req_queue_post_grant_waiter_death", state: :queued)

    {:ok, _pid} =
      RequestServer.start(
        request_id: db_request.id,
        public_id: db_request.public_id,
        initial_state: :queued
      )

    assert {:ok, grant} = QueueManager.acquire(admission_request("req-a"), config: queue_config())

    caller = spawn(fn -> Process.sleep(:infinity) end)

    assert {:queued, ticket} =
             QueueManager.acquire(
               admission_request("req-b",
                 request_id: db_request.id,
                 public_id: db_request.public_id,
                 caller_pid: caller
               ),
               config: queue_config(max_wait_ms: 1_000)
             )

    parent = self()

    spawn(fn ->
      result = QueueManager.await(ticket)
      send(parent, {:post_grant_await_result, result})
    end)

    assert wait_until(fn -> queue_entry_awaiting?(ticket) end)
    assert :ok = QueueManager.release(grant)
    assert_receive {:post_grant_await_result, {:ok, %QueueManager.Grant{}}}, 1_000
    assert wait_until(fn -> Requests.get_request!(db_request.id).state == :cancelled end)

    request = Requests.get_request!(db_request.id)
    assert request.error_code == "request_caller_disconnect"
    assert_queue_metadata(request, "interrupted_before_dispatch", queued?: true)

    assert {:ok, next_grant} =
             QueueManager.acquire(admission_request("req-c"), config: queue_config())

    assert :ok = QueueManager.release(next_grant)

    Process.exit(caller, :kill)
  end

  test "SPEC.md §3.6 awaiter death after timeout reply terminalizes pre-dispatch request" do
    db_request = create_request!("req_queue_post_timeout_waiter_death", state: :queued)

    {:ok, _pid} =
      RequestServer.start(
        request_id: db_request.id,
        public_id: db_request.public_id,
        initial_state: :queued
      )

    assert {:ok, grant} = QueueManager.acquire(admission_request("req-a"), config: queue_config())

    caller = spawn(fn -> Process.sleep(:infinity) end)

    assert {:queued, ticket} =
             QueueManager.acquire(
               admission_request("req-b",
                 request_id: db_request.id,
                 public_id: db_request.public_id,
                 caller_pid: caller
               ),
               config: queue_config(max_wait_ms: 20)
             )

    parent = self()

    spawn(fn ->
      result = QueueManager.await(ticket)
      send(parent, {:post_timeout_await_result, result})
    end)

    assert_receive {:post_timeout_await_result, {:error, :queue_timeout, metadata}}, 1_000
    assert metadata.queue_result == :queue_timeout
    assert wait_until(fn -> Requests.get_request!(db_request.id).state == :timed_out end)

    request = Requests.get_request!(db_request.id)
    assert request.error_code == "queue_timeout"
    assert_queue_metadata(request, "queue_timeout", queued?: true)

    assert :ok = QueueManager.release(grant)

    assert {:ok, next_grant} =
             QueueManager.acquire(admission_request("req-c"), config: queue_config())

    assert :ok = QueueManager.release(next_grant)

    Process.exit(caller, :kill)
  end

  test "SPEC.md §3.6 timeout before dead awaiter DOWN terminalizes pre-dispatch request" do
    db_request = create_request!("req_queue_dead_waiter_timeout", state: :queued)

    {:ok, _pid} =
      RequestServer.start(
        request_id: db_request.id,
        public_id: db_request.public_id,
        initial_state: :queued
      )

    assert {:ok, grant} = QueueManager.acquire(admission_request("req-a"), config: queue_config())

    caller = spawn(fn -> Process.sleep(:infinity) end)

    assert {:queued, ticket} =
             QueueManager.acquire(
               admission_request("req-b",
                 request_id: db_request.id,
                 public_id: db_request.public_id,
                 caller_pid: caller
               ),
               config: queue_config(max_wait_ms: 200)
             )

    awaiter = spawn(fn -> QueueManager.await(ticket) end)
    assert wait_until(fn -> queue_entry_awaiting?(ticket) end)

    :ok = :sys.suspend(QueueManager)

    try do
      Process.sleep(250)
      Process.exit(awaiter, :kill)
      resume_manager(QueueManager)

      assert wait_until(fn -> Requests.get_request!(db_request.id).state == :cancelled end)

      request = Requests.get_request!(db_request.id)
      assert request.error_code == "request_caller_disconnect"
      assert_queue_metadata(request, "interrupted_before_dispatch", queued?: true)

      assert :ok = QueueManager.release(grant)

      assert {:ok, next_grant} =
               QueueManager.acquire(admission_request("req-c"), config: queue_config())

      assert :ok = QueueManager.release(next_grant)

      Process.exit(caller, :kill)
    after
      resume_manager(QueueManager)
    end
  end

  defp assert_in_flight_owner_death_parks_until_terminal(request_state) do
    public_id = "req_queue_#{request_state}_owner_death"
    db_request = create_request!(public_id, state: request_state)

    assert_dead_owner_parks_grant_until_terminal(db_request,
      state_before_terminal: request_state,
      terminal_attrs: %{state: :completed, output_tokens: 1}
    )
  end

  defp assert_pre_dispatch_interrupted_after_child_restart(request_state) do
    boot_token = {__MODULE__, request_state, System.unique_integer([:positive])}
    manager = unique_manager_name()

    manager_pid =
      start_supervised!(
        {QueueManager,
         name: manager, owner_runtime: true, startup_reconciliation: {:once, boot_token}},
        id: {QueueManager, manager}
      )

    live =
      create_request!("req_queue_child_restart_#{request_state}",
        state: request_state,
        scheduler_decision: pre_dispatch_scheduler_decision(request_state)
      )

    {:ok, _pid} =
      RequestServer.start(
        request_id: live.id,
        public_id: live.public_id,
        initial_state: request_state
      )

    Process.exit(manager_pid, :kill)
    assert wait_until(fn -> manager_restarted?(manager, manager_pid) end)

    live = Requests.get_request!(live.id)
    assert live.state == :interrupted
    assert live.error_code == "request_controller_restarted"

    assert_queue_metadata(live, "interrupted_controller_restarted",
      queued?: request_state == :queued
    )

    assert {:ok, grant} =
             QueueManager.acquire(admission_request("req-after-#{request_state}-restart"),
               server: manager,
               config: queue_config(max_wait_ms: 500)
             )

    assert grant.queue_result == :immediate
    assert :ok = QueueManager.release(grant)
  end

  defp pre_dispatch_scheduler_decision(:admitted) do
    %{
      queueing_enabled: true,
      queue_key: "queue-model@v1",
      queue_result: "immediate",
      queue_grant_id: "grant-child-restart-admitted",
      queue_granted_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp pre_dispatch_scheduler_decision(:queued) do
    %{
      queueing_enabled: true,
      queue_key: "queue-model@v1",
      queue_result: "queued",
      queued_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp assert_dead_owner_parks_grant_until_terminal(db_request, opts) do
    caller = spawn(fn -> Process.sleep(:infinity) end)

    assert {:ok, grant} =
             QueueManager.acquire(
               admission_request("#{db_request.public_id}-held",
                 request_id: db_request.id,
                 public_id: db_request.public_id,
                 caller_pid: caller
               ),
               config: queue_config()
             )

    Process.exit(caller, :kill)
    assert wait_until(fn -> grant_parked?(grant) end)

    request = Requests.get_request!(db_request.id)
    assert request.state == Keyword.fetch!(opts, :state_before_terminal)

    assert {:queued, ticket} =
             QueueManager.acquire(
               admission_request("#{db_request.public_id}-next"),
               config: queue_config(max_wait_ms: 1_000)
             )

    awaiter = Task.async(fn -> QueueManager.await(ticket) end)
    assert wait_until(fn -> queue_entry_awaiting?(ticket) end)

    assert {:ok, _request} =
             Requests.mark_terminal(db_request, Keyword.fetch!(opts, :terminal_attrs))

    assert {:ok, next_grant} = Task.await(awaiter, 2_000)
    assert next_grant.queue_result == :queued
    assert :ok = QueueManager.release(next_grant)
    assert :ok = QueueManager.release(grant)
  end

  defp admission_request(public_id, overrides \\ []) do
    %{
      request_id: Keyword.get(overrides, :request_id, Ecto.UUID.generate()),
      public_id: Keyword.get(overrides, :public_id, public_id),
      tenant_id: Keyword.get(overrides, :tenant_id, Ecto.UUID.generate()),
      model_id: Keyword.get(overrides, :model_id, "queue-model"),
      version: Keyword.get(overrides, :version, "v1"),
      caller_pid: Keyword.get(overrides, :caller_pid, self())
    }
  end

  defp queue_config(overrides \\ []) do
    Keyword.merge(
      [
        enabled: true,
        max_wait_ms: 500,
        max_queued_per_tenant: 32,
        poll_interval_ms: 1,
        capacity: 1,
        owner_runtime: true
      ],
      overrides
    )
  end

  defp with_queue_admission_config(queue_admission_config, fun) do
    previous = Application.fetch_env!(:orchard_controller, :inference)

    previous
    |> Keyword.put(:queue_admission, queue_admission_config)
    |> then(&Application.put_env(:orchard_controller, :inference, &1))

    try do
      fun.()
    after
      QueueManager.reset()
      Application.put_env(:orchard_controller, :inference, previous)
    end
  end

  defp wait_until(fun, attempts \\ 50)
  defp wait_until(_fun, 0), do: false

  defp wait_until(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(20)
      wait_until(fun, attempts - 1)
    end
  end

  defp queue_entry_awaiting?(ticket, manager \\ QueueManager) do
    manager
    |> :sys.get_state()
    |> Map.get(:entries)
    |> Map.get(ticket.ticket_ref)
    |> case do
      %{await_from: await_from} when await_from != nil -> true
      _other -> false
    end
  end

  defp ticket_result?(ticket) do
    QueueManager
    |> :sys.get_state()
    |> Map.get(:ticket_results)
    |> Map.has_key?(ticket.ticket_ref)
  end

  defp queue_entry_terminal_pending?(ticket) do
    QueueManager
    |> :sys.get_state()
    |> Map.get(:entries)
    |> Map.get(ticket.ticket_ref)
    |> case do
      %{terminal_operation: operation, terminal_retry_ref: retry_ref}
      when operation != nil and is_reference(retry_ref) ->
        true

      _other ->
        false
    end
  end

  defp grant_parked?(grant) do
    QueueManager
    |> :sys.get_state()
    |> Map.get(:grants)
    |> Map.get(grant.grant_id)
    |> case do
      %{recovered?: true} -> true
      _other -> false
    end
  end

  defp manager_restarted?(manager, previous_pid) do
    case GenServer.whereis(manager) do
      pid when is_pid(pid) and pid != previous_pid -> true
      _other -> false
    end
  end

  defp resume_manager(manager) do
    :sys.resume(manager)
  catch
    :exit, _reason -> :ok
  end

  defp unique_manager_name do
    Module.concat(__MODULE__, "Manager#{System.unique_integer([:positive])}")
  end

  defp create_request!(public_id, overrides \\ []) do
    attrs = request_attrs(public_id, overrides)

    {:ok, request} = Requests.create_request(attrs)

    request
  end

  defp insert_request_with_id!(request_id, public_id, overrides) do
    %Request{id: request_id}
    |> Request.create_changeset(request_attrs(public_id, overrides))
    |> Repo.insert!()
  end

  defp request_attrs(public_id, overrides) do
    Keyword.merge(
      [
        public_id: public_id,
        endpoint: :chat_completions,
        tenant_id: Ecto.UUID.generate(),
        requested_model: "queue-model@v1",
        state: :received,
        stream: false,
        payload_capture_mode: :metadata
      ],
      overrides
    )
    |> Map.new()
  end
end
