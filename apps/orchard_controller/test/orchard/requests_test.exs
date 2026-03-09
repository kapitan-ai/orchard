defmodule Orchard.RequestsTest do
  use Orchard.DataCase, async: false

  alias Orchard.Models
  alias Orchard.Requests

  test "create_request/1 supports early lifecycle rows before model resolution and canonicalization" do
    assert {:ok, request} = Requests.create_request(early_request_attrs())

    assert request.state == :received
    assert request.model_id == nil
    assert request.canonical_request == nil
    assert request.requested_model == "mlx-community/phi-3@main"
  end

  test "append_request_event/2 auto-assigns per-request sequence numbers" do
    assert {:ok, request} =
             Requests.create_request(early_request_attrs(%{public_id: "req_event_test"}))

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

    assert Enum.map(Requests.list_request_events(request), & &1.event_type) == [
             "request.received",
             "request.validated"
           ]
  end

  test "append_request_event/2 ignores caller-supplied sequence numbers" do
    assert {:ok, request} =
             Requests.create_request(early_request_attrs(%{public_id: "req_event_override_test"}))

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
             Requests.create_request(
               early_request_attrs(%{public_id: "req_event_string_keys_test"})
             )

    assert {:ok, event} =
             Requests.append_request_event(request.id, %{
               "event_type" => "request.received",
               "state" => :received,
               "payload" => %{"phase" => "ingress"}
             })

    assert event.seq == 1
    assert event.event_type == "request.received"
    assert event.payload == %{"phase" => "ingress"}
  end

  test "append_request_event/2 returns a handled error for unknown requests" do
    assert {:error, :request_not_found} =
             Requests.append_request_event(Ecto.UUID.generate(), %{
               event_type: "request.received",
               state: :received
             })
  end

  test "mark_terminal/2 only accepts terminal states and stamps completion time" do
    {:ok, model} = Models.create_model(model_attrs())

    {:ok, request} =
      Requests.create_request(
        early_request_attrs(%{
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
    {:ok, model} = Models.create_model(model_attrs())

    {:ok, request} =
      Requests.create_request(
        early_request_attrs(%{
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
    {:ok, model} = Models.create_model(model_attrs())

    {:ok, request} =
      Requests.create_request(
        early_request_attrs(%{
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

  defp early_request_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        public_id: "req_123",
        endpoint: :chat_completions,
        tenant_id: Ecto.UUID.generate(),
        requested_model: "mlx-community/phi-3@main",
        state: :received,
        stream: true,
        payload_capture_mode: :metadata,
        sampling_params: %{"temperature" => 0.7},
        response_format: %{"type" => "text"},
        input_tokens: 0,
        output_tokens: 0,
        reserved_output_tokens: 128,
        timeout_at: ~U[2026-03-10 00:00:00.000000Z]
      },
      overrides
    )
  end

  defp model_attrs do
    %{
      model_id: "mlx-community/phi-3",
      version: "main",
      state: :active,
      format: "mlx",
      capabilities: ["chat"],
      tokenizer: %{"kind" => "huggingface_tokenizer_json", "path" => "tokenizer.json"},
      artifact_uri: "file:///tmp/phi-3",
      artifact_sha256: String.duplicate("b", 64),
      artifact_size_bytes: 1_024,
      resident_memory_bytes: 2_048,
      kv_cache_bytes_per_token: 16,
      prefill_workspace_bytes_per_token: 8,
      max_context_tokens: 32_768,
      default_parameters: %{},
      runtime_requirements: %{"adapter" => "mlx_lm", "min_agent_capability" => "mlx"}
    }
  end
end
