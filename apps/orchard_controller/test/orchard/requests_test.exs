defmodule Orchard.RequestsTest do
  use Orchard.DataCase, async: false

  import Orchard.TestSupport.ModelRequestFixtures

  alias Orchard.Governance
  alias Orchard.Models
  alias Orchard.Requests
  alias Orchard.Requests.{Request, RequestStepEvent}

  test "create_request/1 supports early lifecycle rows before model resolution and canonicalization" do
    attrs = request_attrs()
    assert {:ok, request} = Requests.create_request(attrs)

    assert request.state == :received
    assert request.model_id == nil
    assert request.canonical_request == nil
    assert request.requested_model == attrs.requested_model
  end

  test "create_request/1 rejects service-account provenance without service_account_id" do
    attrs =
      request_attrs(%{
        principal_type: :service_account,
        service_account_id: nil
      })

    assert {:error, changeset} = Requests.create_request(attrs)
    assert %{service_account_id: ["can't be blank"]} = errors_on(changeset)
  end

  test "create_request/1 retains valid service-account provenance" do
    {:ok, tenant} =
      Governance.create_tenant(%{
        slug: "request-service-account-#{System.unique_integer([:positive])}",
        name: "Request Service Account"
      })

    {:ok, api_client} =
      Governance.upsert_api_client(tenant, %{
        name: "request-api-client",
        owner_contact: "owner@example.com"
      })

    attrs =
      request_attrs(%{
        tenant_id: tenant.id,
        principal_type: :service_account,
        service_account_id: api_client.id
      })

    assert {:ok, request} = Requests.create_request(attrs)
    assert request.principal_type == :service_account
    assert request.service_account_id == api_client.id
  end

  test "append_request_event/2 auto-assigns per-request sequence numbers and default occurred_at" do
    assert {:ok, request} =
             Requests.create_request(request_attrs(%{public_id: "req_event_test"}))

    assert {:ok, first} =
             Requests.append_request_event(request, %{
               event_type: "request.received",
               state: :received
             })

    assert {:ok, second} =
             Requests.append_request_event(request.id, %{
               event_type: "request.validated",
               state: :validated
             })

    assert first.seq == 1
    assert second.seq == 2
    assert match?(%DateTime{}, first.occurred_at)
    assert match?(%DateTime{}, second.occurred_at)

    assert Enum.map(Requests.list_request_events(request), & &1.event_type) == [
             "request.received",
             "request.validated"
           ]
  end

  test "append_request_event/2 ignores caller-supplied sequence numbers" do
    assert {:ok, request} =
             Requests.create_request(request_attrs(%{public_id: "req_event_override_test"}))

    assert {:ok, first} =
             Requests.append_request_event(request, %{
               seq: 99,
               event_type: "request.received",
               state: :received
             })

    assert {:ok, second} =
             Requests.append_request_event(request, %{
               seq: 7,
               event_type: "request.validated",
               state: :validated
             })

    assert first.seq == 1
    assert second.seq == 2
  end

  test "append_request_event/2 accepts string-keyed event payload attrs without crashing" do
    assert {:ok, request} =
             Requests.create_request(request_attrs(%{public_id: "req_event_string_keys_test"}))

    occurred_at = ~U[2026-03-15 12:34:56.000000Z]

    assert {:ok, event} =
             Requests.append_request_event(request.id, %{
               "event_type" => "request.received",
               "state" => :received,
               "occurred_at" => occurred_at,
               "payload" => %{"phase" => "ingress"}
             })

    assert event.seq == 1
    assert event.event_type == "request.received"
    assert event.occurred_at == occurred_at
    assert event.payload == %{"phase" => "ingress"}
  end

  test "append_request_event/2 preserves atom-keyed occurred_at when provided" do
    assert {:ok, request} =
             Requests.create_request(
               request_attrs(%{public_id: "req_event_explicit_occurred_at_test"})
             )

    occurred_at = ~U[2026-03-15 01:02:03.000000Z]

    assert {:ok, event} =
             Requests.append_request_event(request.id, %{
               event_type: "request.received",
               state: :received,
               occurred_at: occurred_at
             })

    assert event.occurred_at == occurred_at
  end

  test "append_request_event/2 returns a handled error for unknown requests" do
    assert {:error, :request_not_found} =
             Requests.append_request_event(Ecto.UUID.generate(), %{
               event_type: "request.received",
               state: :received
             })
  end

  test "append_request_step_events/2 batch-appends typed step events with contiguous seq values without mutating request state" do
    request = create_request!(%{public_id: "req_step_batch_test", state: :received})

    assert {:ok, _validated} =
             Requests.append_request_event(request, %{
               event_type: "request.validated",
               state: :validated
             })

    assert {:ok, [started, proposed]} =
             Requests.append_request_step_events(request, [
               inference_turn_started_step_attrs(),
               tool_call_proposed_step_attrs()
             ])

    assert started.seq == 2
    assert proposed.seq == 3
    assert started.event_type == "request_step.started"
    assert proposed.event_type == "request_step.proposed"

    assert Enum.map(Requests.list_request_step_events(request), &{&1.seq, &1.step_id}) == [
             {2, "inference_turn:t1:a1"},
             {3, "tool_call:t1:ccall_1"}
           ]

    assert Enum.map(Requests.list_request_events(request), &{&1.seq, &1.event_type, &1.state}) ==
             [
               {1, "request.validated", :validated},
               {2, "request_step.started", nil},
               {3, "request_step.proposed", nil}
             ]

    assert Requests.get_request!(request.id).state == :validated

    assert {:ok, running} =
             Requests.append_request_event(request, %{
               event_type: "request.running",
               state: :running
             })

    assert running.seq == 4
    assert Requests.get_request!(request.id).state == :running
  end

  test "append_request_step_events/2 accepts RequestStepEvent structs" do
    request = create_request!(%{public_id: "req_step_batch_struct_test", state: :received})

    started_step = inference_turn_started_step_attrs() |> RequestStepEvent.new!()
    proposed_step = tool_call_proposed_step_attrs() |> RequestStepEvent.new!()

    assert {:ok, [started, proposed]} =
             Requests.append_request_step_events(request, [started_step, proposed_step])

    assert started.event_type == "request_step.started"
    assert proposed.event_type == "request_step.proposed"

    assert Enum.map(Requests.list_request_step_events(request), & &1.event_type) == [
             "request_step.started",
             "request_step.proposed"
           ]

    assert Requests.get_request!(request.id).state == :received
  end

  test "append_request_step_events/2 rejects invalid batches atomically" do
    request = create_request!(%{public_id: "req_step_batch_invalid_test", state: :received})

    assert {:error, {:invalid_step_event, 2, reason}} =
             Requests.append_request_step_events(request, [
               inference_turn_started_step_attrs(),
               inference_turn_started_step_attrs(%{state: :running})
             ])

    assert reason =~ "state: nil"
    assert Requests.list_request_events(request) == []
    assert Requests.list_request_step_events(request) == []
    assert Requests.get_request!(request.id).state == :received
  end

  test "list_request_step_events/1 returns only exact contract request_step event types" do
    request = create_request!(%{public_id: "req_step_exact_filter_test", state: :running})

    assert {:ok, _fake_step} =
             Requests.append_request_event(request, %{
               event_type: "request_step.completed.extra",
               payload: %{"ignored" => true}
             })

    assert {:ok, _valid_step_events} =
             Requests.append_request_step_events(request, [
               inference_turn_started_step_attrs()
             ])

    assert {:ok, _normal_event} =
             Requests.append_request_event(request, %{
               event_type: "request.running",
               state: :running
             })

    assert Enum.map(Requests.list_request_step_events(request), & &1.event_type) == [
             "request_step.started"
           ]

    assert Enum.map(Requests.list_request_events(request), & &1.event_type) == [
             "request_step.completed.extra",
             "request_step.started",
             "request.running"
           ]
  end

  describe "mark_terminal_with_step_events/3" do
    test "atomically commits success-shaped terminal step rows with the terminal request update" do
      request = create_request!(%{public_id: "req_terminal_steps_success", state: :running})

      assert {:ok, updated_request} =
               Requests.mark_terminal_with_step_events(
                 request,
                 %{state: :completed, output_tokens: 42},
                 [tool_call_proposed_step_attrs(), inference_turn_completed_step_attrs()]
               )

      assert updated_request.state == :completed
      assert updated_request.output_tokens == 42

      assert Enum.map(Requests.list_request_step_events(request), &{&1.event_type, &1.step_id}) ==
               [
                 {"request_step.proposed", "tool_call:t1:ccall_1"},
                 {"request_step.completed", "inference_turn:t1:a1"}
               ]

      assert Enum.map(Requests.list_request_events(request), &{&1.seq, &1.event_type, &1.state}) ==
               [
                 {1, "request_step.proposed", nil},
                 {2, "request_step.completed", nil}
               ]

      assert Requests.get_request!(request.id).state == :completed
    end

    test "atomically commits success-shaped terminal step rows when given RequestStepEvent structs" do
      request = create_request!(%{public_id: "req_terminal_steps_struct", state: :running})

      proposed_step = tool_call_proposed_step_attrs() |> RequestStepEvent.new!()
      completed_step = inference_turn_completed_step_attrs() |> RequestStepEvent.new!()

      assert {:ok, updated_request} =
               Requests.mark_terminal_with_step_events(
                 request,
                 %{state: :completed, output_tokens: 11},
                 [proposed_step, completed_step]
               )

      assert updated_request.state == :completed
      assert updated_request.output_tokens == 11

      assert Enum.map(Requests.list_request_step_events(request), & &1.event_type) == [
               "request_step.proposed",
               "request_step.completed"
             ]
    end

    test "atomically commits failure-shaped terminal step rows with the terminal request update" do
      request = create_request!(%{public_id: "req_terminal_steps_failure", state: :running})

      assert {:ok, updated_request} =
               Requests.mark_terminal_with_step_events(
                 request.id,
                 %{state: :failed, error_code: "tool_choice_not_satisfied"},
                 [inference_turn_failed_step_attrs()]
               )

      assert updated_request.state == :failed
      assert updated_request.error_code == "tool_choice_not_satisfied"

      assert Enum.map(Requests.list_request_step_events(request), &{&1.event_type, &1.step_id}) ==
               [
                 {"request_step.failed", "inference_turn:t1:a1"}
               ]

      assert Requests.get_request!(request.id).state == :failed
    end

    test "rolls back inserted step rows when the terminal request update fails" do
      request = create_request!(%{public_id: "req_terminal_steps_rollback", state: :running})

      assert {:error, changeset} =
               Requests.mark_terminal_with_step_events(
                 request,
                 %{state: :running},
                 [inference_turn_completed_step_attrs()]
               )

      assert %{state: ["must be terminal"]} = errors_on(changeset)
      assert Requests.list_request_events(request) == []
      assert Requests.list_request_step_events(request) == []
      assert Requests.get_request!(request.id).state == :running
    end

    test "does not update the request row when the terminal step batch is invalid" do
      request = create_request!(%{public_id: "req_terminal_steps_invalid_batch", state: :running})

      assert {:error, {:invalid_step_event, 2, reason}} =
               Requests.mark_terminal_with_step_events(
                 request,
                 %{state: :completed},
                 [
                   inference_turn_completed_step_attrs(),
                   inference_turn_completed_step_attrs(%{state: :completed})
                 ]
               )

      assert reason =~ "state: nil"
      assert Requests.list_request_events(request) == []
      assert Requests.list_request_step_events(request) == []
      assert Requests.get_request!(request.id).state == :running
    end

    test "same-terminal idempotent re-entry does not duplicate proposal or terminal step rows" do
      request = create_request!(%{public_id: "req_terminal_steps_idempotent", state: :running})

      attrs = %{state: :completed, output_tokens: 7}
      step_events = [tool_call_proposed_step_attrs(), inference_turn_completed_step_attrs()]

      assert {:ok, first_terminal} =
               Requests.mark_terminal_with_step_events(request, attrs, step_events)

      assert first_terminal.state == :completed

      assert {:ok, second_terminal} =
               Requests.mark_terminal_with_step_events(
                 request.id,
                 %{state: :completed, output_tokens: 9},
                 step_events
               )

      assert second_terminal.state == :completed
      assert second_terminal.output_tokens == 9

      assert Enum.map(Requests.list_request_step_events(request), &{&1.event_type, &1.step_id}) ==
               [
                 {"request_step.proposed", "tool_call:t1:ccall_1"},
                 {"request_step.completed", "inference_turn:t1:a1"}
               ]
    end

    test "rejects stale terminal overwrites without appending terminal step rows" do
      request = create_request!(%{public_id: "req_terminal_steps_stale", state: :running})

      assert {:ok, _terminal} =
               Requests.mark_terminal_with_step_events(
                 request,
                 %{state: :completed},
                 [inference_turn_completed_step_attrs()]
               )

      assert {:error, :already_terminal} =
               Requests.mark_terminal_with_step_events(
                 request.id,
                 %{state: :failed, error_code: "late_failure"},
                 [inference_turn_failed_step_attrs()]
               )

      assert Enum.map(Requests.list_request_step_events(request), &{&1.event_type, &1.step_id}) ==
               [
                 {"request_step.completed", "inference_turn:t1:a1"}
               ]

      assert Requests.get_request!(request.id).state == :completed
    end
  end

  test "mark_terminal/2 only accepts terminal states and stamps completion time" do
    {:ok, model} = Models.create_model(model_attrs(%{state: :active}))

    {:ok, request} =
      Requests.create_request(
        request_attrs(%{
          public_id: "req_terminal_test",
          state: :running,
          model_id: model.id,
          canonical_request: %{"public_id" => "req_terminal_test"}
        })
      )

    assert {:error, changeset} = Requests.mark_terminal(request, %{state: :running})
    assert %{state: ["must be terminal"]} = errors_on(changeset)

    assert {:ok, terminal} =
             Requests.mark_terminal(request, %{
               state: :completed,
               output_tokens: 42,
               response_payload: %{"object" => "chat.completion"}
             })

    assert terminal.state == :completed
    assert terminal.output_tokens == 42
    assert terminal.completed_at != nil
  end

  test "mark_terminal/2 does not allow immutable request fields to change" do
    {:ok, model} = Models.create_model(model_attrs(%{state: :active}))

    {:ok, request} =
      Requests.create_request(
        request_attrs(%{
          public_id: "req_terminal_immutable_test",
          state: :running,
          model_id: model.id,
          canonical_request: %{"public_id" => "req_terminal_immutable_test"}
        })
      )

    assert {:ok, terminal} =
             Requests.mark_terminal(request, %{
               state: :completed,
               public_id: "req_mutated_public_id",
               tenant_id: Ecto.UUID.generate()
             })

    assert terminal.public_id == "req_terminal_immutable_test"
    assert terminal.tenant_id == request.tenant_id
    assert terminal.state == :completed
  end

  test "mark_terminal/2 rejects stale terminal overwrites" do
    {:ok, model} = Models.create_model(model_attrs(%{state: :active}))

    {:ok, request} =
      Requests.create_request(
        request_attrs(%{
          public_id: "req_terminal_stale_test",
          state: :running,
          model_id: model.id,
          canonical_request: %{"public_id" => "req_terminal_stale_test"}
        })
      )

    assert {:ok, terminal} = Requests.mark_terminal(request, %{state: :completed})
    assert terminal.state == :completed

    assert {:error, :already_terminal} =
             Requests.mark_terminal(request, %{state: :failed, error_code: "late_failure"})
  end

  test "active_states/0 returns non-terminal states in canonical order" do
    active = Request.active_states()
    assert active == Request.states() -- Request.terminal_states()
    assert :running in active
    assert :streaming in active
    refute :completed in active
    refute :failed in active
  end

  test "summary/0 returns zero-filled counts when DB is empty" do
    summary = Requests.summary()

    assert summary.total == 0
    assert summary.active == 0
    assert summary.terminal == 0

    for state <- Request.states() do
      assert Map.has_key?(summary.by_state, state), "missing state: #{state}"
      assert summary.by_state[state] == 0
    end
  end

  test "summary/0 returns grouped counts with active/terminal derivation" do
    create_request!(%{public_id: "r1", state: :received})
    create_request!(%{public_id: "r2", state: :running})
    create_request!(%{public_id: "r3", state: :running})
    create_request!(%{public_id: "r4", state: :completed})
    create_request!(%{public_id: "r5", state: :failed})

    summary = Requests.summary()

    assert summary.total == 5
    assert summary.active == 3
    assert summary.terminal == 2
    assert summary.by_state.received == 1
    assert summary.by_state.running == 2
    assert summary.by_state.completed == 1
    assert summary.by_state.failed == 1
    assert summary.by_state.streaming == 0
    assert summary.active + summary.terminal == summary.total
  end

  describe "performance_summary/0" do
    test "returns zero sample_size and nil metrics on empty DB" do
      summary = Requests.performance_summary()

      assert summary.sample_size == 0
      assert is_nil(summary.avg_ttft_ms)
      assert is_nil(summary.avg_generation_ms)
      assert is_nil(summary.avg_total_latency_ms)
      assert is_nil(summary.avg_tokens_per_second)
    end

    test "filters to completed rows with valid timestamps and positive output" do
      # Eligible row A: TTFT 1s, generation 5s, total 6s, tok/s 4.0
      a =
        create_request!(%{
          public_id: "perf_a",
          state: :completed,
          input_tokens: 10,
          output_tokens: 20,
          first_token_at: ~U[2026-03-15 12:00:01.000000Z],
          completed_at: ~U[2026-03-15 12:00:06.000000Z]
        })

      patch_inserted_at(a, ~U[2026-03-15 12:00:00.000000Z])

      # Eligible row B: TTFT 2s, generation 8s, total 10s, tok/s 5.0
      b =
        create_request!(%{
          public_id: "perf_b",
          state: :completed,
          input_tokens: 15,
          output_tokens: 40,
          first_token_at: ~U[2026-03-15 12:00:02.000000Z],
          completed_at: ~U[2026-03-15 12:00:10.000000Z]
        })

      patch_inserted_at(b, ~U[2026-03-15 12:00:00.000000Z])

      # Ineligible: non-completed state
      create_request!(%{public_id: "perf_running", state: :running, output_tokens: 10})

      # Ineligible: no first_token_at
      create_request!(%{
        public_id: "perf_no_ft",
        state: :completed,
        output_tokens: 5,
        completed_at: ~U[2026-03-15 12:00:05.000000Z]
      })

      # Ineligible: zero output_tokens
      create_request!(%{
        public_id: "perf_zero_out",
        state: :completed,
        output_tokens: 0,
        first_token_at: ~U[2026-03-15 12:00:01.000000Z],
        completed_at: ~U[2026-03-15 12:00:05.000000Z]
      })

      summary = Requests.performance_summary()

      assert summary.sample_size == 2
      assert_in_delta summary.avg_ttft_ms, 1500.0, 1.0
      assert_in_delta summary.avg_generation_ms, 6500.0, 1.0
      assert_in_delta summary.avg_total_latency_ms, 8000.0, 1.0
      assert_in_delta summary.avg_tokens_per_second, 4.5, 0.01
    end

    test "excludes zero and negative generation durations" do
      # Valid row: 500ms generation
      valid =
        create_request!(%{
          public_id: "perf_valid",
          state: :completed,
          output_tokens: 10,
          first_token_at: ~U[2026-03-15 12:00:00.500000Z],
          completed_at: ~U[2026-03-15 12:00:01.000000Z]
        })

      patch_inserted_at(valid, ~U[2026-03-15 12:00:00.000000Z])

      # Zero generation: completed_at == first_token_at
      create_request!(%{
        public_id: "perf_zero_gen",
        state: :completed,
        output_tokens: 5,
        first_token_at: ~U[2026-03-15 12:00:01.000000Z],
        completed_at: ~U[2026-03-15 12:00:01.000000Z]
      })

      # Negative generation: completed_at < first_token_at
      create_request!(%{
        public_id: "perf_neg_gen",
        state: :completed,
        output_tokens: 5,
        first_token_at: ~U[2026-03-15 12:00:02.000000Z],
        completed_at: ~U[2026-03-15 12:00:01.000000Z]
      })

      summary = Requests.performance_summary()

      assert summary.sample_size == 1
      assert_in_delta summary.avg_generation_ms, 500.0, 1.0
    end

    test "returns float types for all average fields" do
      req =
        create_request!(%{
          public_id: "perf_types",
          state: :completed,
          output_tokens: 10,
          first_token_at: ~U[2026-03-15 12:00:00.250000Z],
          completed_at: ~U[2026-03-15 12:00:01.250000Z]
        })

      patch_inserted_at(req, ~U[2026-03-15 12:00:00.000000Z])

      summary = Requests.performance_summary()

      assert summary.sample_size == 1
      assert is_integer(summary.sample_size)
      assert is_float(summary.avg_ttft_ms)
      assert is_float(summary.avg_generation_ms)
      assert is_float(summary.avg_total_latency_ms)
      assert is_float(summary.avg_tokens_per_second)
    end
  end

  describe "get_request_by_public_id/1" do
    test "preloads retry_of_request association" do
      parent = create_request!(%{public_id: "req_parent_preload"})

      child =
        create_request!(%{
          public_id: "req_child_preload",
          retry_of_request_id: parent.id
        })

      fetched = Requests.get_request_by_public_id(child.public_id)

      assert fetched != nil
      assert fetched.retry_of_request.id == parent.id
      assert fetched.retry_of_request.public_id == parent.public_id
    end

    test "returns nil retry_of_request when no retry source" do
      request = create_request!(%{public_id: "req_no_retry"})

      fetched = Requests.get_request_by_public_id(request.public_id)

      assert fetched != nil
      assert fetched.retry_of_request == nil
    end

    test "preloads tenant and api_key associations when present" do
      {:ok, tenant} =
        Governance.create_tenant(%{
          slug: "request-preload-#{System.unique_integer([:positive])}",
          name: "Request Preload"
        })

      {:ok, %{api_key: api_key}} = Governance.create_api_key(tenant.id, %{name: "Primary"})

      request =
        create_request!(%{
          public_id: "req_preload_assoc",
          tenant_id: tenant.id,
          api_key_id: api_key.id
        })

      fetched = Requests.get_request_by_public_id(request.public_id)

      assert fetched.tenant.id == tenant.id
      assert fetched.api_key.id == api_key.id
    end

    test "returns nil tenant and api_key associations when absent" do
      request = create_request!(%{public_id: "req_no_assoc", api_key_id: nil})

      fetched = Requests.get_request_by_public_id(request.public_id)

      assert fetched.tenant == nil
      assert fetched.api_key == nil
    end

    test "returns nil for unknown public_id" do
      assert Requests.get_request_by_public_id("nonexistent-id") == nil
    end
  end

  describe "recent_cache_affinity_nodes/5" do
    test "returns matching completed nodes in recency order within tenant model and version scope" do
      tenant_id = Ecto.UUID.generate()
      other_tenant_id = Ecto.UUID.generate()
      model_id = "mlx-community/cache-affinity"
      affinity_key = "hmac-sha256:#{String.duplicate("a", 64)}"
      now = ~U[2026-04-23 12:00:00.000000Z]
      recent_node_id = Ecto.UUID.generate()
      older_node_id = Ecto.UUID.generate()

      create_request!(%{
        tenant_id: tenant_id,
        requested_model: "#{model_id}@v1",
        state: :completed,
        node_id: older_node_id,
        completed_at: DateTime.add(now, -2, :second),
        scheduler_decision: %{"cache_affinity_key" => affinity_key}
      })

      create_request!(%{
        tenant_id: tenant_id,
        requested_model: "#{model_id}@v1",
        state: :completed,
        node_id: recent_node_id,
        completed_at: DateTime.add(now, -1, :second),
        scheduler_decision: %{"cache_affinity_key" => affinity_key}
      })

      create_request!(%{
        tenant_id: other_tenant_id,
        requested_model: "#{model_id}@v1",
        state: :completed,
        node_id: Ecto.UUID.generate(),
        completed_at: DateTime.add(now, -1, :second),
        scheduler_decision: %{"cache_affinity_key" => affinity_key}
      })

      create_request!(%{
        tenant_id: tenant_id,
        requested_model: "#{model_id}@v2",
        state: :completed,
        node_id: Ecto.UUID.generate(),
        completed_at: DateTime.add(now, -1, :second),
        scheduler_decision: %{"cache_affinity_key" => affinity_key}
      })

      create_request!(%{
        tenant_id: tenant_id,
        requested_model: "#{model_id}@v1",
        state: :completed,
        node_id: Ecto.UUID.generate(),
        completed_at: DateTime.add(now, -10, :minute),
        scheduler_decision: %{"cache_affinity_key" => affinity_key}
      })

      assert Requests.recent_cache_affinity_nodes(tenant_id, model_id, "v1", affinity_key,
               max_age_ms: 300_000,
               max_recent_requests: 8,
               now: now
             ) == [recent_node_id, older_node_id]
    end

    test "bounds matching rows by max_recent_requests" do
      tenant_id = Ecto.UUID.generate()
      model_id = "mlx-community/cache-affinity-bound"
      affinity_key = "hmac-sha256:#{String.duplicate("b", 64)}"
      now = ~U[2026-04-23 12:00:00.000000Z]
      newest_node_id = Ecto.UUID.generate()

      Enum.each(1..3, fn index ->
        node_id = if index == 1, do: newest_node_id, else: Ecto.UUID.generate()

        create_request!(%{
          tenant_id: tenant_id,
          requested_model: "#{model_id}@v1",
          state: :completed,
          node_id: node_id,
          completed_at: DateTime.add(now, -index, :second),
          scheduler_decision: %{"cache_affinity_key" => affinity_key}
        })
      end)

      assert Requests.recent_cache_affinity_nodes(tenant_id, model_id, "v1", affinity_key,
               max_age_ms: 300_000,
               max_recent_requests: 1,
               now: now
             ) == [newest_node_id]
    end
  end

  describe "record_schedule/2" do
    test "persists scheduler_decision as normalized JSON-safe map" do
      request = create_request!(%{public_id: "req_schedule_1"})

      schedule = %{
        strategy: :single_node,
        request_id: "req_schedule_1",
        runtime_client_target: [host: "127.0.0.1", port: 50_071],
        request_timeout_ms: 5_000,
        model_load_timeout_ms: 120_000,
        node_id: nil
      }

      assert {:ok, updated} = Requests.record_schedule(request, schedule)
      decision = updated.scheduler_decision

      assert decision["strategy"] == "single_node"
      assert decision["runtime_client_target"] == %{"host" => "127.0.0.1", "port" => 50_071}
      assert decision["request_timeout_ms"] == 5_000
      assert decision["node_id"] == nil
    end

    test "sets node_id when schedule contains a UUID" do
      request = create_request!(%{public_id: "req_schedule_2"})
      node_id = Ecto.UUID.generate()

      schedule = %{
        strategy: :single_node,
        request_id: "req_schedule_2",
        runtime_client_target: [host: "10.0.0.1", port: 9444],
        request_timeout_ms: 5_000,
        model_load_timeout_ms: 120_000,
        node_id: node_id
      }

      assert {:ok, updated} = Requests.record_schedule(request, schedule)
      assert updated.node_id == node_id
    end

    test "recursively normalizes multi-node metadata into JSON-safe values" do
      request = create_request!(%{public_id: "req_schedule_nested"})
      node_id = Ecto.UUID.generate()

      schedule = %{
        strategy: :multi_node,
        request_id: "req_schedule_nested",
        runtime_client_target: [host: "10.0.0.1", port: 9444],
        request_timeout_ms: 5_000,
        model_load_timeout_ms: 120_000,
        node_id: node_id,
        candidate_count: 2,
        selected_tier: :loaded,
        fallback_used?: false,
        selection_context: %{
          tiers: [:loaded, :healthy],
          eligible?: true,
          targets: [
            [host: "10.0.0.1", port: 9444],
            [host: "10.0.0.2", port: 9445]
          ],
          flags: [degraded_allowed?: true, preferred?: false]
        }
      }

      assert {:ok, updated} = Requests.record_schedule(request, schedule)

      assert updated.scheduler_decision == %{
               "strategy" => "multi_node",
               "request_id" => "req_schedule_nested",
               "runtime_client_target" => %{"host" => "10.0.0.1", "port" => 9444},
               "request_timeout_ms" => 5_000,
               "model_load_timeout_ms" => 120_000,
               "node_id" => node_id,
               "candidate_count" => 2,
               "selected_tier" => "loaded",
               "fallback_used?" => false,
               "selection_context" => %{
                 "tiers" => ["loaded", "healthy"],
                 "eligible?" => true,
                 "targets" => [
                   %{"host" => "10.0.0.1", "port" => 9444},
                   %{"host" => "10.0.0.2", "port" => 9445}
                 ],
                 "flags" => %{
                   "degraded_allowed?" => true,
                   "preferred?" => false
                 }
               }
             }
    end

    test "rejects scheduler explanations with reason codes outside the accepted vocabulary" do
      request = create_request!(%{public_id: "req_schedule_invalid_reason"})

      schedule = %{
        request_id: request.public_id,
        selected_node_id: "node-a",
        selection_tier: :loaded,
        scored_candidates: [],
        rejected_candidates: [
          %{node_id: "node-b", reason_codes: [:made_up_reason]}
        ],
        skipped_candidates: []
      }

      assert {:error,
              {:invalid_scheduler_explanation,
               {:unknown_code, :scheduler_rejection, "made_up_reason"}}} =
               Requests.record_schedule(request, schedule)

      assert Repo.get!(Orchard.Requests.Request, request.id).scheduler_decision == nil
    end

    test "preserves nil node_id when schedule has no node" do
      request = create_request!(%{public_id: "req_schedule_3"})

      schedule = %{
        strategy: :single_node,
        request_id: "req_schedule_3",
        runtime_client_target: [host: "10.0.0.1", port: 9444],
        request_timeout_ms: 5_000,
        model_load_timeout_ms: 120_000,
        node_id: nil
      }

      assert {:ok, updated} = Requests.record_schedule(request, schedule)
      assert updated.node_id == nil
    end

    test "returns error for unknown request" do
      assert {:error, :request_not_found} =
               Requests.record_schedule(Ecto.UUID.generate(), %{
                 strategy: :single_node,
                 request_id: "none",
                 runtime_client_target: [host: "10.0.0.1", port: 9444],
                 request_timeout_ms: 5_000,
                 model_load_timeout_ms: 120_000,
                 node_id: nil
               })
    end
  end

  describe "list_recent_requests/1" do
    test "returns empty list when no requests" do
      assert Requests.list_recent_requests() == []
    end

    test "returns requests in reverse chronological order" do
      r1 = create_request!(%{public_id: "req_list_1"})
      r2 = create_request!(%{public_id: "req_list_2"})
      r3 = create_request!(%{public_id: "req_list_3"})

      result = Requests.list_recent_requests()
      ids = Enum.map(result, & &1.id)

      # Most recent first
      assert ids == [r3.id, r2.id, r1.id]
    end

    test "respects limit parameter" do
      create_request!(%{public_id: "req_limit_1"})
      create_request!(%{public_id: "req_limit_2"})
      create_request!(%{public_id: "req_limit_3"})

      result = Requests.list_recent_requests(2)
      assert length(result) == 2
    end

    test "tie-breaks on id DESC for equal inserted_at" do
      r1 = create_request!(%{public_id: "req_tie_1"})
      r2 = create_request!(%{public_id: "req_tie_2"})

      # Force identical inserted_at
      fixed_time = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      import Ecto.Query

      Repo.update_all(
        from(r in Request, where: r.id in [^r1.id, ^r2.id]),
        set: [inserted_at: fixed_time]
      )

      result = Requests.list_recent_requests()
      ids = Enum.map(result, & &1.id)

      # Higher UUID (later binary sort) comes first with DESC
      expected = Enum.sort([r1.id, r2.id], :desc)
      assert ids == expected
    end

    test "does not preload associations" do
      create_request!(%{public_id: "req_preload_1"})

      [request] = Requests.list_recent_requests()
      assert %Ecto.Association.NotLoaded{} = request.tenant
      assert %Ecto.Association.NotLoaded{} = request.api_key
    end

    test "normalizes invalid limit to 50" do
      create_request!(%{public_id: "req_norm_1"})

      assert [_] = Requests.list_recent_requests(-1)
      assert [_] = Requests.list_recent_requests(0)
      assert [_] = Requests.list_recent_requests("bad")
    end
  end

  describe "assign_node/2" do
    test "writes runtime-resolved node UUID" do
      request = create_request!(%{public_id: "req_assign_1"})
      node_id = Ecto.UUID.generate()

      assert {:ok, updated} = Requests.assign_node(request, node_id)
      assert updated.node_id == node_id
    end

    test "idempotently accepts same UUID" do
      request = create_request!(%{public_id: "req_assign_2"})
      node_id = Ecto.UUID.generate()

      assert {:ok, _} = Requests.assign_node(request, node_id)
      assert {:ok, updated} = Requests.assign_node(request.id, node_id)
      assert updated.node_id == node_id
    end

    test "overwrites scheduler-attributed node_id" do
      scheduler_id = Ecto.UUID.generate()
      request = create_request!(%{public_id: "req_assign_3", node_id: scheduler_id})
      runtime_id = Ecto.UUID.generate()

      assert {:ok, updated} = Requests.assign_node(request, runtime_id)
      assert updated.node_id == runtime_id
    end

    test "returns error for unknown request" do
      assert {:error, :request_not_found} =
               Requests.assign_node(Ecto.UUID.generate(), Ecto.UUID.generate())
    end
  end

  # ---------------------------------------------------------------------------
  # Test helpers
  # ---------------------------------------------------------------------------

  defp patch_inserted_at(request, %DateTime{} = dt) do
    {1, _} =
      Repo.update_all(
        from(r in Request, where: r.id == ^request.id),
        set: [inserted_at: dt]
      )
  end

  defp inference_turn_started_step_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        event_type: "request_step.started",
        step_id: RequestStepEvent.inference_turn_step_id(1, 1),
        step_type: "inference_turn",
        turn_index: 1,
        attempt: 1,
        parent_step_id: nil,
        boundary: "pre_side_effect",
        result: %{}
      },
      overrides
    )
  end

  defp tool_call_proposed_step_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        event_type: "request_step.proposed",
        step_id: RequestStepEvent.tool_call_step_id(1, "call_1"),
        step_type: "tool_call",
        turn_index: 1,
        attempt: 1,
        parent_step_id: RequestStepEvent.inference_turn_step_id(1, 1),
        boundary: "post_observation",
        result: %{"finish_reason" => "tool_calls"},
        call_id: "call_1",
        tool_name: "lookup_weather",
        arguments_json: "{\"city\":\"Singapore\"}"
      },
      overrides
    )
  end

  defp inference_turn_completed_step_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        event_type: "request_step.completed",
        step_id: RequestStepEvent.inference_turn_step_id(1, 1),
        step_type: "inference_turn",
        turn_index: 1,
        attempt: 1,
        parent_step_id: nil,
        boundary: "post_observation",
        result: %{"finish_reason" => "stop"}
      },
      overrides
    )
  end

  defp inference_turn_failed_step_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        event_type: "request_step.failed",
        step_id: RequestStepEvent.inference_turn_step_id(1, 1),
        step_type: "inference_turn",
        turn_index: 1,
        attempt: 1,
        parent_step_id: nil,
        boundary: "post_observation",
        result: %{"code" => "tool_choice_not_satisfied", "message" => "tool choice not satisfied"}
      },
      overrides
    )
  end
end
