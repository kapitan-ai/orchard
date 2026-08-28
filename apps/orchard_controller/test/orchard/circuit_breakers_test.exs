defmodule Orchard.CircuitBreakersTest do
  use Orchard.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Orchard.CircuitBreakers
  alias Orchard.CircuitBreakers.Decision
  alias Orchard.Models.Model
  alias Orchard.Nodes.Node

  @now ~U[2026-08-28 01:00:00.000000Z]

  setup do
    node = insert_node!()
    model = insert_model!()
    %{node: node, model: model}
  end

  describe "record_failure/2 and evaluate/2" do
    test "opens a Node breaker on the third eligible dispatch failure in 60 seconds", %{
      node: node
    } do
      for {seconds_ago, expected_count} <- [{59, 1}, {30, 2}] do
        assert {:ok, decision} =
                 CircuitBreakers.record_failure(
                   failure(node.id, "worker_or_node_loss", seconds_ago),
                   now: @now
                 )

        assert decision.kind == :node
        assert decision.node_id == node.id
        assert decision.state == :closed
        assert decision.contribution_count == expected_count
        refute decision.changed_state?
      end

      assert {:ok, opened} =
               CircuitBreakers.record_failure(
                 failure(node.id, "pre_acceptance_unavailable", 0),
                 now: @now
               )

      assert opened.state == :open
      assert opened.changed_state?
      assert opened.opened_at == @now
      assert opened.suppressed_until == ~U[2026-08-28 01:05:00.000000Z]

      assert {:ok, evaluated} = CircuitBreakers.evaluate({:node, node.id}, now: @now)
      assert evaluated.id == opened.id
      assert evaluated.state == :open
      assert evaluated.contribution_count == 3
    end

    test "opens a placement breaker from three decisions in ten minutes", %{
      node: node,
      model: model
    } do
      assert {:ok, :not_eligible} =
               CircuitBreakers.record_failure(failure(node.id, "capacity_rejection", 0),
                 now: @now
               )

      assert {:ok, first} =
               CircuitBreakers.record_failure(
                 failure(node.id, "model_load_failure", 601, %{model_id: model.id}),
                 now: @now
               )

      assert first.kind == :placement
      assert first.contribution_count == 1

      assert {:ok, second} =
               CircuitBreakers.record_failure(
                 failure(node.id, "model_load_failure", 599, %{model_id: model.id}),
                 now: @now
               )

      assert second.state == :closed

      assert {:ok, opened} =
               CircuitBreakers.record_failure(
                 failure(node.id, "model_load_failure", 300, %{model_id: model.id}),
                 now: @now
               )

      assert opened.state == :open
      assert opened.contribution_count == 3
      assert opened.suppressed_until == ~U[2026-08-28 01:15:00.000000Z]
      assert opened.contribution_disposition == :contributed
      assert opened.transition == :opened
    end

    test "uses a half-open rolling decision-time window", %{node: node} do
      boundary = DateTime.add(@now, -60, :second)

      assert {:ok, _outside} =
               CircuitBreakers.record_failure(
                 failure(node.id, "worker_or_node_loss", 120),
                 now: boundary
               )

      for seconds_ago <- [1, 0] do
        assert {:ok, decision} =
                 CircuitBreakers.record_failure(
                   failure(node.id, "worker_or_node_loss", seconds_ago),
                   now: @now
                 )

        assert decision.state == :closed
      end

      assert {:ok, decision} = CircuitBreakers.evaluate({:node, node.id}, now: @now)
      assert decision.contribution_count == 2
      assert decision.state == :closed
    end

    test "makes identical global failure delivery idempotent and rejects conflicting reuse", %{
      node: node
    } do
      attrs = failure(node.id, "worker_or_node_loss", 0)

      assert {:ok, recorded} = CircuitBreakers.record_failure(attrs, now: @now)
      assert recorded.delivery == :recorded
      assert recorded.contribution_count == 1

      assert {:ok, duplicate} = CircuitBreakers.record_failure(attrs, now: @now)
      assert duplicate.delivery == :duplicate
      assert duplicate.id == recorded.id
      assert duplicate.contribution_count == 1

      conflicting = %{attrs | failure_class: "pre_acceptance_unavailable"}

      assert {:error, :failure_identity_conflict} =
               CircuitBreakers.record_failure(conflicting, now: @now)
    end

    test "serializes concurrent contributions so one canonical breaker opens", %{node: node} do
      failures = for _ <- 1..8, do: failure(node.id, "worker_or_node_loss", 0)
      owner = self()

      results =
        failures
        |> Task.async_stream(
          fn attrs ->
            Sandbox.allow(Repo, owner, self())
            CircuitBreakers.record_failure(attrs, now: @now)
          end,
          max_concurrency: 8,
          ordered: false,
          timeout: 10_000
        )
        |> Enum.to_list()

      assert Enum.all?(results, &match?({:ok, {:ok, %Decision{}}}, &1))
      assert {:ok, decision} = CircuitBreakers.evaluate({:node, node.id}, now: @now)
      assert decision.state == :open
      assert decision.contribution_count == 8
    end

    test "uses the persisted deadline for lazy expiry", %{node: node} do
      opened = open_node_breaker(node.id)

      assert {:ok, expired} =
               CircuitBreakers.evaluate({:node, node.id},
                 now: DateTime.add(opened.suppressed_until, 1, :microsecond)
               )

      assert expired.id == opened.id
      assert expired.state == :closed
      assert expired.contribution_count == 0
      assert is_nil(expired.suppressed_until)
    end

    test "rejects future-dated contribution evidence", %{node: node} do
      assert {:error, :invalid_occurred_at} =
               CircuitBreakers.record_failure(
                 failure(node.id, "worker_or_node_loss", -1),
                 now: @now
               )
    end

    test "fences a delayed first delivery whose occurrence predates an Operator clear", %{
      node: node
    } do
      open_node_breaker(node.id)

      clear_time = DateTime.add(@now, 10, :second)
      assert {:ok, cleared} = CircuitBreakers.clear({:node, node.id}, now: clear_time)
      assert cleared.contribution_count == 0

      assert {:ok, fenced} =
               CircuitBreakers.record_failure(
                 failure(node.id, "worker_or_node_loss", 1),
                 now: DateTime.add(clear_time, 1, :second)
               )

      assert fenced.contribution_disposition == :fenced
      assert fenced.transition == :none
      assert fenced.contribution_count == 0
      assert fenced.state == :closed
    end
  end

  describe "clear/2" do
    test "clearing a closed pre-threshold breaker is already cleared without fencing evidence", %{
      node: node
    } do
      assert {:ok, recorded} =
               CircuitBreakers.record_failure(failure(node.id, "worker_or_node_loss", 0),
                 now: @now
               )

      assert recorded.state == :closed
      assert recorded.contribution_count == 1

      later = DateTime.add(@now, 10, :second)
      assert {:ok, already_cleared} = CircuitBreakers.clear({:node, node.id}, now: later)

      refute already_cleared.changed_state?
      assert already_cleared.state == :closed
      assert already_cleared.generation == 0
      assert is_nil(already_cleared.last_cleared_at)
      assert already_cleared.contribution_count == 1
    end

    test "advances the clear generation once, preserves identity, and audits repeated no-op clear",
         %{
           node: node
         } do
      opened = open_node_breaker(node.id)
      test_pid = self()

      audit = fn decision ->
        send(test_pid, {:audited, decision})
        :ok
      end

      assert {:ok, cleared} =
               CircuitBreakers.clear({:node, node.id}, now: @now, audit: audit)

      assert cleared.id == opened.id
      assert cleared.state == :closed
      assert cleared.changed_state?
      assert cleared.contribution_count == 0
      assert cleared.generation == 1
      assert cleared.last_cleared_at == @now
      assert cleared.decision_at == @now
      assert cleared.previous_state == :open
      assert_receive {:audited, ^cleared}

      later = DateTime.add(@now, 30, :second)
      assert {:ok, repeated} = CircuitBreakers.clear({:node, node.id}, now: later, audit: audit)
      refute repeated.changed_state?
      assert repeated.generation == 1
      assert repeated.last_cleared_at == @now
      assert repeated.decision_at == later
      assert repeated.previous_state == :closed
      assert_receive {:audited, ^repeated}
    end

    test "rolls a clear back when its atomic audit callback fails", %{node: node} do
      opened = open_node_breaker(node.id)

      assert {:error, :audit_failed} =
               CircuitBreakers.clear({:node, node.id},
                 now: @now,
                 audit: fn _decision -> {:error, :audit_failed} end
               )

      assert {:ok, still_open} = CircuitBreakers.inspect({:node, node.id}, now: @now)
      assert still_open.id == opened.id
      assert still_open.state == :open
      assert still_open.generation == 0
    end

    test "does not normalize unrelated programming errors from the transaction", %{node: node} do
      open_node_breaker(node.id)

      assert_raise Ecto.ChangeError, "programming defect", fn ->
        CircuitBreakers.clear({:node, node.id},
          now: @now,
          audit: fn _decision -> raise Ecto.ChangeError, message: "programming defect" end
        )
      end
    end

    test "normalizes a database connection exit from the transaction", %{node: node} do
      open_node_breaker(node.id)

      connection_error = DBConnection.ConnectionError.exception(message: "connection closed")

      assert {:error, :circuit_breaker_unavailable} =
               CircuitBreakers.clear({:node, node.id},
                 now: @now,
                 audit: fn _decision -> exit(connection_error) end
               )
    end
  end

  describe "fail-closed identities and write authority" do
    test "rejects malformed and unresolved canonical identities", %{node: node, model: model} do
      assert {:error, :invalid_failure_identity} =
               CircuitBreakers.record_failure(
                 failure(node.id, "worker_or_node_loss", 0, %{failure_id: "not-a-uuid"}),
                 now: @now
               )

      assert {:error, :node_not_found} =
               CircuitBreakers.evaluate({:node, Ecto.UUID.generate()}, now: @now)

      assert {:error, :model_not_active} =
               model
               |> Ecto.Changeset.change(state: :retired)
               |> Repo.update!()
               |> then(fn retired ->
                 CircuitBreakers.evaluate({:placement, node.id, retired.id}, now: @now)
               end)
    end

    test "accepts a deprecated placement Model while retired Models remain ineligible", %{
      node: node,
      model: model
    } do
      deprecated =
        model
        |> Ecto.Changeset.change(state: :deprecated)
        |> Repo.update!()

      assert {:ok, %Decision{state: :closed, model_id: model_id}} =
               CircuitBreakers.evaluate({:placement, node.id, deprecated.id}, now: @now)

      assert model_id == deprecated.id

      retired =
        deprecated
        |> Ecto.Changeset.change(state: :retired)
        |> Repo.update!()

      assert {:error, :model_not_active} =
               CircuitBreakers.evaluate({:placement, node.id, retired.id}, now: @now)
    end

    test "retains inspectable placement history after catalog Model deletion", %{
      node: node,
      model: model
    } do
      assert {:ok, recorded} =
               CircuitBreakers.record_failure(
                 failure(node.id, "model_load_failure", 0, %{model_id: model.id}),
                 now: @now
               )

      Repo.delete!(model)

      assert {:ok, retained} =
               CircuitBreakers.inspect({:placement, node.id, model.id}, now: @now)

      assert retained.id == recorded.id
      assert retained.contribution_count == 1
      assert retained.model_id == model.id

      assert {:error, :model_not_found} =
               CircuitBreakers.evaluate({:placement, node.id, model.id}, now: @now)
    end

    test "rejects an unknown placement Model when no retained breaker exists", %{node: node} do
      assert {:error, :model_not_found} =
               CircuitBreakers.inspect({:placement, node.id, Ecto.UUID.generate()}, now: @now)
    end

    test "standby Controllers cannot record or clear failures", %{node: node} do
      previous = Application.get_env(:orchard_controller, :control_plane)
      Application.put_env(:orchard_controller, :control_plane, role: :standby)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:orchard_controller, :control_plane, previous),
          else: Application.delete_env(:orchard_controller, :control_plane)
      end)

      assert {:error, :controller_standby} =
               CircuitBreakers.record_failure(failure(node.id, "worker_or_node_loss", 0),
                 now: @now
               )

      assert {:error, :controller_standby} =
               CircuitBreakers.clear({:node, node.id}, now: @now)
    end

    test "a fresh Standby process reads durable state after role handoff while writes fail", %{
      node: node
    } do
      opened = open_node_breaker(node.id)
      previous = Application.get_env(:orchard_controller, :control_plane)
      Application.put_env(:orchard_controller, :control_plane, role: :standby)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:orchard_controller, :control_plane, previous),
          else: Application.delete_env(:orchard_controller, :control_plane)
      end)

      read_task = Task.async(fn -> CircuitBreakers.evaluate({:node, node.id}, now: @now) end)

      assert {:ok, {:ok, read_back}} =
               Task.yield(read_task, 5_000)

      assert read_back.id == opened.id
      assert read_back.state == :open

      assert {:error, :controller_standby} =
               CircuitBreakers.record_failure(failure(node.id, "worker_or_node_loss", 0),
                 now: @now
               )
    end
  end

  describe "serialized database decision time and coherent reads" do
    test "batch evaluation preserves input order and one post-lock decision time", %{
      node: node,
      model: model
    } do
      open_node_breaker(node.id)

      assert {:ok, [placement, node_decision]} =
               CircuitBreakers.evaluate_many(
                 [{:placement, node.id, model.id}, {:node, node.id}],
                 now: @now
               )

      assert placement.kind == :placement
      assert placement.model_id == model.id
      assert placement.state == :closed
      assert node_decision.kind == :node
      assert node_decision.state == :open
      assert placement.decision_at == node_decision.decision_at
    end

    test "concurrent reversed batch evaluations acquire targets in one deterministic order", %{
      node: node,
      model: model
    } do
      owner = self()
      targets = [{:node, node.id}, {:placement, node.id, model.id}]

      results =
        [targets, Enum.reverse(targets)]
        |> Task.async_stream(
          fn ordered_targets ->
            Sandbox.allow(Repo, owner, self())
            CircuitBreakers.evaluate_many(ordered_targets, now: @now)
          end,
          max_concurrency: 2,
          timeout: 5_000
        )
        |> Enum.to_list()

      assert Enum.all?(results, fn
               {:ok, {:ok, [%Decision{}, %Decision{}]}} -> true
               _result -> false
             end)
    end

    test "batch evaluation fails closed as one result when any identity is unresolved", %{
      node: node
    } do
      assert {:error, :node_not_found} =
               CircuitBreakers.evaluate_many(
                 [{:node, node.id}, {:node, Ecto.UUID.generate()}],
                 now: @now
               )
    end

    test "a blocked recorder decides after the target lock and excludes the elapsed boundary" do
      node = begin_unboxed_node!()
      db_now = database_now()
      seed_time = DateTime.add(db_now, -59, :second)

      for _ <- 1..2 do
        attrs = failure_at(node.id, "worker_or_node_loss", seed_time)

        assert {:ok, %Decision{state: :closed}} =
                 Sandbox.unboxed_run(Repo, fn ->
                   CircuitBreakers.record_failure(attrs, now: seed_time)
                 end)
      end

      {holder, release_ref} = hold_target_lock(node.id)
      attrs = failure_at(node.id, "worker_or_node_loss", db_now)
      parent = self()

      recorder =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            backend_pid = backend_pid()
            send(parent, {:recorder_backend, backend_pid})
            CircuitBreakers.record_failure(attrs)
          end)
        end)

      assert_receive {:recorder_backend, recorder_backend}, 2_000
      assert_backend_waiting_on_lock(recorder_backend)
      Process.sleep(1_100)
      send(holder.pid, release_ref)
      assert {:ok, released_at} = Task.await(holder, 5_000)

      assert {:ok, %Decision{} = result} = Task.await(recorder, 5_000)
      assert DateTime.compare(result.decision_at, released_at) in [:eq, :gt]
      assert result.contribution_count == 1
      assert result.state == :closed
      assert result.transition == :none
    end

    test "evaluation waits for an in-flight opening transition and reads the committed state" do
      node = begin_unboxed_node!()

      for seconds_ago <- [2, 1] do
        assert {:ok, _decision} =
                 Sandbox.unboxed_run(Repo, fn ->
                   CircuitBreakers.record_failure(
                     failure(node.id, "worker_or_node_loss", seconds_ago),
                     now: @now
                   )
                 end)
      end

      {opener, release_ref} = paused_record(failure(node.id, "worker_or_node_loss", 0), @now)

      reader = start_unboxed_reader({:node, node.id}, @now)
      assert_receive {:reader_backend, reader_backend}, 2_000
      assert_backend_waiting_on_lock(reader_backend)
      send(opener.pid, release_ref)

      assert {:ok, %Decision{state: :open}} = Task.await(opener, 5_000)
      assert {:ok, %Decision{state: :open, contribution_count: 3}} = Task.await(reader, 5_000)
    end

    test "evaluation waits for an in-flight clear and reads one committed generation" do
      node = begin_unboxed_node!()

      opened =
        Sandbox.unboxed_run(Repo, fn ->
          for seconds_ago <- [2, 1] do
            assert {:ok, _decision} =
                     CircuitBreakers.record_failure(
                       failure(node.id, "worker_or_node_loss", seconds_ago),
                       now: @now
                     )
          end

          assert {:ok, result} =
                   CircuitBreakers.record_failure(
                     failure(node.id, "worker_or_node_loss", 0),
                     now: @now
                   )

          result
        end)

      {clearer, release_ref} = paused_clear(node.id, @now)
      reader = start_unboxed_reader({:node, node.id}, @now)
      assert_receive {:reader_backend, reader_backend}, 2_000
      assert_backend_waiting_on_lock(reader_backend)
      send(clearer.pid, release_ref)

      assert {:ok, %Decision{state: :closed, generation: 1}} = Task.await(clearer, 5_000)

      assert {:ok, %Decision{id: id, state: :closed, generation: 1, contribution_count: 0}} =
               Task.await(reader, 5_000)

      assert id == opened.id
    end

    test "database unavailability returns a stable error without partial clear or audit" do
      node = begin_unboxed_node!()

      Sandbox.unboxed_run(Repo, fn ->
        for seconds_ago <- [2, 1, 0] do
          assert {:ok, _decision} =
                   CircuitBreakers.record_failure(
                     failure(node.id, "worker_or_node_loss", seconds_ago),
                     now: @now
                   )
        end
      end)

      test_pid = self()

      audit = fn _decision ->
        send(test_pid, :unexpected_audit)
        :ok
      end

      assert {:error, :circuit_breaker_unavailable} =
               CircuitBreakers.inspect({:node, node.id}, now: @now)

      assert {:error, :circuit_breaker_unavailable} =
               CircuitBreakers.clear({:node, node.id}, now: @now, audit: audit)

      refute_receive :unexpected_audit

      assert {:ok, %Decision{state: :open, generation: 0}} =
               Sandbox.unboxed_run(Repo, fn ->
                 CircuitBreakers.inspect({:node, node.id}, now: @now)
               end)
    end
  end

  defp open_node_breaker(node_id) do
    for seconds_ago <- [2, 1] do
      assert {:ok, _decision} =
               CircuitBreakers.record_failure(
                 failure(node_id, "worker_or_node_loss", seconds_ago),
                 now: @now
               )
    end

    assert {:ok, opened} =
             CircuitBreakers.record_failure(
               failure(node_id, "worker_or_node_loss", 0),
               now: @now
             )

    opened
  end

  defp failure(node_id, failure_class, seconds_ago, overrides \\ %{}) do
    Map.merge(
      %{
        failure_id: Ecto.UUID.generate(),
        node_id: node_id,
        failure_class: failure_class,
        occurred_at: DateTime.add(@now, -seconds_ago, :second)
      },
      overrides
    )
  end

  defp failure_at(node_id, failure_class, occurred_at) do
    %{
      failure_id: Ecto.UUID.generate(),
      node_id: node_id,
      failure_class: failure_class,
      occurred_at: occurred_at
    }
  end

  defp begin_unboxed_node! do
    :ok = Sandbox.checkin(Repo)
    node = Sandbox.unboxed_run(Repo, &insert_node!/0)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.query!("DELETE FROM circuit_breaker_failures WHERE node_id = $1", [
          Ecto.UUID.dump!(node.id)
        ])

        Repo.query!("DELETE FROM circuit_breakers WHERE node_id = $1", [
          Ecto.UUID.dump!(node.id)
        ])

        Repo.delete_all(from(candidate in Node, where: candidate.id == ^node.id))
      end)
    end)

    node
  end

  defp hold_target_lock(node_id) do
    parent = self()
    release_ref = make_ref()

    task =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          hold_target_lock_transaction(node_id, parent, release_ref)
        end)
      end)

    assert_receive {:target_lock_held, _pid}, 2_000
    {task, release_ref}
  end

  defp hold_target_lock_transaction(node_id, parent, release_ref) do
    Repo.transaction(fn ->
      advisory_target_lock(node_id)
      send(parent, {:target_lock_held, self()})

      receive do
        ^release_ref -> database_now_direct()
      after
        5_000 -> raise "timed out waiting to release circuit-breaker target lock"
      end
    end)
  end

  defp paused_record(attrs, now) do
    parent = self()
    release_ref = make_ref()

    task =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          CircuitBreakers.record_failure(attrs,
            now: now,
            test_lock_observer: pause_on_target(parent, release_ref)
          )
        end)
      end)

    assert_receive {:domain_target_lock_held, _pid}, 2_000
    {task, release_ref}
  end

  defp paused_clear(node_id, now) do
    parent = self()
    release_ref = make_ref()

    task =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          CircuitBreakers.clear({:node, node_id},
            now: now,
            test_lock_observer: pause_on_target(parent, release_ref)
          )
        end)
      end)

    assert_receive {:domain_target_lock_held, _pid}, 2_000
    {task, release_ref}
  end

  defp pause_on_target(parent, release_ref) do
    fn
      :target ->
        send(parent, {:domain_target_lock_held, self()})

        receive do
          ^release_ref -> :ok
        after
          5_000 -> raise "timed out waiting to release domain target lock"
        end

      :failure ->
        :ok
    end
  end

  defp start_unboxed_reader(target, now) do
    parent = self()

    Task.async(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        send(parent, {:reader_backend, backend_pid()})
        CircuitBreakers.evaluate(target, now: now)
      end)
    end)
  end

  defp assert_backend_waiting_on_lock(backend_pid, attempts \\ 40)

  defp assert_backend_waiting_on_lock(_backend_pid, 0),
    do: flunk("backend did not wait on the circuit-breaker advisory lock")

  defp assert_backend_waiting_on_lock(backend_pid, attempts) do
    waiting? =
      Sandbox.unboxed_run(Repo, fn ->
        %{rows: rows} =
          Repo.query!(
            "SELECT 1 FROM pg_stat_activity WHERE pid = $1 AND wait_event_type = 'Lock'",
            [backend_pid]
          )

        rows != []
      end)

    if waiting? do
      :ok
    else
      Process.sleep(25)
      assert_backend_waiting_on_lock(backend_pid, attempts - 1)
    end
  end

  defp advisory_target_lock(node_id) do
    Repo.query!(
      "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
      ["orchard:circuit-breaker:node:#{node_id}:"]
    )
  end

  defp database_now do
    Sandbox.unboxed_run(Repo, &database_now_direct/0)
  end

  defp database_now_direct do
    %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp()")
    DateTime.truncate(now, :microsecond)
  end

  defp backend_pid do
    %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
    pid
  end

  defp insert_node! do
    unique = System.unique_integer([:positive])

    %Node{}
    |> Node.changeset(%{
      id: Ecto.UUID.generate(),
      hostname: "breaker-node-#{unique}.local",
      display_name: "breaker-node-#{unique}",
      advertise_addr: "10.254.#{rem(div(unique, 254), 254)}.#{rem(unique, 254) + 1}",
      rpc_port: 9444,
      state: :active,
      health: :healthy,
      capabilities: %{},
      tool_readiness: %{}
    })
    |> Repo.insert!()
  end

  defp insert_model! do
    unique = System.unique_integer([:positive])

    %Model{}
    |> Model.changeset(%{
      model_id: "breaker-model-#{unique}",
      version: "main",
      state: :active,
      format: "mlx",
      capabilities: ["text"],
      tokenizer: %{"type" => "huggingface", "ref" => "test/tokenizer"},
      artifact_uri: "file:///tmp/breaker-model-#{unique}",
      artifact_sha256: String.duplicate("a", 64),
      artifact_size_bytes: 1,
      resident_memory_bytes: 1,
      kv_cache_bytes_per_token: 1,
      prefill_workspace_bytes_per_token: 1,
      runtime_requirements: %{}
    })
    |> Repo.insert!()
  end
end
