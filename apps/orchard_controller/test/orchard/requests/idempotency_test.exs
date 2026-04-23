defmodule Orchard.Requests.IdempotencyTest do
  use Orchard.DataCase, async: false

  import Orchard.TestSupport.ModelRequestFixtures

  alias Orchard.Requests
  alias Orchard.Requests.{Idempotency, RequestStepEvent}

  test "build_context/3 produces the same body hash for equivalent map key orderings" do
    tenant_id = Ecto.UUID.generate()
    key = "idem-key"

    params_a = %{
      "model" => "test@v1",
      "messages" => [%{"content" => "hello", "role" => "user"}],
      "stream_options" => %{"include_usage" => true}
    }

    params_b = %{
      "stream_options" => %{"include_usage" => true},
      "messages" => [%{"role" => "user", "content" => "hello"}],
      "model" => "test@v1"
    }

    assert {:ok, context_a} = Idempotency.build_context(tenant_id, key, params_a)
    assert {:ok, context_b} = Idempotency.build_context(tenant_id, key, params_b)
    assert context_a.body_hash == context_b.body_hash
  end

  test "resolve/1 returns :proceed when no row exists for the tenant and key" do
    assert {:ok, context} =
             Idempotency.build_context(Ecto.UUID.generate(), "idem-missing", %{
               "model" => "test@v1"
             })

    assert :proceed = Idempotency.resolve(context)
  end

  test "resolve/1 replays completed non-stream rows with matching body hash" do
    tenant_id = Ecto.UUID.generate()
    key = "idem-replay"
    params = %{"model" => "test@v1", "messages" => [%{"role" => "user", "content" => "hi"}]}

    assert {:ok, context} = Idempotency.build_context(tenant_id, key, params)

    request =
      create_request!(%{
        tenant_id: tenant_id,
        idempotency_key: key,
        body_hash: context.body_hash,
        stream: false,
        state: :completed,
        response_payload: %{"id" => "req_replay", "object" => "chat.completion"}
      })

    request_id = request.id
    assert {:replay, %{id: ^request_id}} = Idempotency.resolve(context)
  end

  test "resolve/1 replay behavior is unchanged when request_step events exist" do
    tenant_id = Ecto.UUID.generate()
    key = "idem-replay-step-events"
    params = %{"model" => "test@v1", "messages" => [%{"role" => "user", "content" => "hi"}]}

    assert {:ok, context} = Idempotency.build_context(tenant_id, key, params)

    request =
      create_request!(%{
        tenant_id: tenant_id,
        idempotency_key: key,
        body_hash: context.body_hash,
        stream: false,
        state: :completed,
        response_payload: %{"id" => "req_replay_steps", "object" => "chat.completion"}
      })

    inference_turn_step_id = RequestStepEvent.inference_turn_step_id(1, 1)

    assert {:ok, _step_events} =
             Requests.append_request_step_events(request, [
               %{
                 event_type: "request_step.started",
                 step_id: inference_turn_step_id,
                 step_type: "inference_turn",
                 turn_index: 1,
                 attempt: 1,
                 parent_step_id: nil,
                 boundary: "pre_side_effect",
                 result: %{}
               },
               %{
                 event_type: "request_step.completed",
                 step_id: inference_turn_step_id,
                 step_type: "inference_turn",
                 turn_index: 1,
                 attempt: 1,
                 parent_step_id: nil,
                 boundary: "post_observation",
                 result: %{"finish_reason" => "stop"}
               }
             ])

    request_id = request.id
    assert {:replay, %{id: ^request_id}} = Idempotency.resolve(context)
  end

  test "resolve/1 returns request_in_progress for matching active rows" do
    tenant_id = Ecto.UUID.generate()
    key = "idem-active"
    params = %{"model" => "test@v1"}

    assert {:ok, context} = Idempotency.build_context(tenant_id, key, params)

    create_request!(%{
      tenant_id: tenant_id,
      idempotency_key: key,
      body_hash: context.body_hash,
      state: :running
    })

    assert {:conflict, :request_in_progress, _request} = Idempotency.resolve(context)
  end

  test "SPEC.md §3.9 treats admitted and queued rows as request_in_progress" do
    for state <- [:admitted, :queued] do
      tenant_id = Ecto.UUID.generate()
      key = "idem-#{state}"
      params = %{"model" => "test@v1", "state" => state}

      assert {:ok, context} = Idempotency.build_context(tenant_id, key, params)

      create_request!(%{
        tenant_id: tenant_id,
        idempotency_key: key,
        body_hash: context.body_hash,
        state: state
      })

      assert {:conflict, :request_in_progress, _request} = Idempotency.resolve(context)
    end
  end

  test "resolve/1 conflict behavior is unchanged when request_step events exist" do
    tenant_id = Ecto.UUID.generate()
    key = "idem-active-step-events"
    params = %{"model" => "test@v1"}

    assert {:ok, context} = Idempotency.build_context(tenant_id, key, params)

    request =
      create_request!(%{
        tenant_id: tenant_id,
        idempotency_key: key,
        body_hash: context.body_hash,
        state: :running
      })

    assert {:ok, _step_events} =
             Requests.append_request_step_events(request, [
               %{
                 event_type: "request_step.started",
                 step_id: RequestStepEvent.inference_turn_step_id(1, 1),
                 step_type: "inference_turn",
                 turn_index: 1,
                 attempt: 1,
                 parent_step_id: nil,
                 boundary: "pre_side_effect",
                 result: %{}
               }
             ])

    assert {:conflict, :request_in_progress, _request} = Idempotency.resolve(context)
  end

  test "resolve/1 returns idempotency_mismatch for the same tenant and key with a different body" do
    tenant_id = Ecto.UUID.generate()
    key = "idem-mismatch"

    assert {:ok, original} = Idempotency.build_context(tenant_id, key, %{"model" => "test@v1"})
    assert {:ok, retry} = Idempotency.build_context(tenant_id, key, %{"model" => "other@v1"})

    create_request!(%{
      tenant_id: tenant_id,
      idempotency_key: key,
      body_hash: original.body_hash,
      state: :completed,
      stream: false,
      response_payload: %{"id" => "req_original"}
    })

    assert {:conflict, :idempotency_mismatch, _request} = Idempotency.resolve(retry)
  end

  test "resolve/1 is tenant scoped for the same idempotency key" do
    key = "idem-tenant-scope"
    params = %{"model" => "test@v1"}
    tenant_a = Ecto.UUID.generate()
    tenant_b = Ecto.UUID.generate()

    assert {:ok, context_a} = Idempotency.build_context(tenant_a, key, params)
    assert {:ok, context_b} = Idempotency.build_context(tenant_b, key, params)

    create_request!(%{
      tenant_id: tenant_a,
      idempotency_key: key,
      body_hash: context_a.body_hash,
      stream: false,
      state: :completed,
      response_payload: %{"id" => "req_tenant_a"}
    })

    assert {:replay, _request} = Idempotency.resolve(context_a)
    assert :proceed = Idempotency.resolve(context_b)
  end

  test "resolve/1 returns idempotency_not_replayable for completed streaming rows" do
    tenant_id = Ecto.UUID.generate()
    key = "idem-stream"
    params = %{"model" => "test@v1", "stream" => true}

    assert {:ok, context} = Idempotency.build_context(tenant_id, key, params)

    create_request!(%{
      tenant_id: tenant_id,
      idempotency_key: key,
      body_hash: context.body_hash,
      stream: true,
      state: :completed
    })

    assert {:conflict, :idempotency_not_replayable, _request} = Idempotency.resolve(context)
  end

  test "build_context/3 rejects unsupported request shapes" do
    assert {:error, :invalid_request_shape} =
             Idempotency.build_context(Ecto.UUID.generate(), "idem-invalid", %{
               "model" => %URI{scheme: "file", path: "/tmp/test"}
             })
  end
end
