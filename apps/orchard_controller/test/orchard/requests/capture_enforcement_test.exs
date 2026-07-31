defmodule Orchard.Requests.CaptureEnforcementTest do
  use Orchard.DataCase, async: false

  alias Ecto.Adapters.SQL
  alias Orchard.Governance
  alias Orchard.Governance.Tenant
  alias Orchard.Repo
  alias Orchard.Requests
  alias Postgrex.Error, as: PostgrexError

  @private_prompt "private prompt must not survive"
  @private_response "private response must not survive"

  test "SPEC.md §10.10 metadata is enforced across creation, events, and terminal writes" do
    suffix = System.unique_integer([:positive])

    {:ok, tenant} =
      Governance.create_tenant(%{
        slug: "capture-snapshot-#{suffix}",
        name: "Capture Snapshot #{suffix}",
        request_body_capture_mode: :metadata
      })

    {:ok, request} = Requests.create_request(request_attrs(:metadata, tenant.id))

    assert request.canonical_request == nil
    assert request.request_payload == nil
    assert request.request_shape["capture_mode"] == "metadata"
    refute inspect(request) =~ @private_prompt

    tenant
    |> Tenant.changeset(%{request_body_capture_mode: :full})
    |> Repo.update!()

    assert {:ok, scheduled} =
             Requests.record_schedule(request, %{
               strategy: :multi_node,
               node_id: Ecto.UUID.generate(),
               prompt: @private_prompt,
               diagnostics: %{"error_message" => @private_prompt}
             })

    assert scheduled.scheduler_decision["strategy"] == "multi_node"
    refute inspect(scheduled.scheduler_decision) =~ @private_prompt

    assert {:ok, smuggling_attempt} =
             Requests.record_schedule(request, %{
               candidate_count: @private_prompt,
               fallback_used?: %{"secret" => @private_prompt},
               strategy: @private_prompt,
               selected_node_id: @private_prompt,
               scored_candidates: [
                 %{
                   node_id: @private_prompt,
                   eligible: @private_prompt,
                   score: @private_prompt,
                   reason_codes: [],
                   components: %{pool_bonus: @private_prompt}
                 }
               ]
             })

    refute inspect(smuggling_attempt.scheduler_decision) =~ @private_prompt

    assert {:ok, event} =
             Requests.append_request_event(request, %{
               event_type: "runtime.failed",
               payload: %{
                 "attempt" => @private_prompt,
                 "boundary" => @private_prompt,
                 "call_id" => @private_prompt,
                 "step_type" => @private_prompt,
                 "state" => "failed",
                 "result" => %{
                   "error_code" => @private_prompt,
                   "finish_reason" => @private_prompt,
                   "input_tokens" => @private_prompt,
                   "error_message" => @private_prompt,
                   "arguments_json" => ~s({"secret":"#{@private_prompt}"})
                 }
               },
               state: :failed
             })

    assert event.payload == %{"result" => %{}}
    refute inspect(event.payload) =~ @private_prompt

    assert {:ok, terminal} =
             Requests.mark_terminal(request, %{
               state: :failed,
               response_payload: %{"output_text" => @private_response},
               response_preview: @private_response,
               error_code: "runtime_failure",
               error_message: "runtime echoed #{@private_prompt}"
             })

    assert terminal.response_payload == nil
    assert terminal.response_preview == nil
    assert terminal.error_message == nil
    assert byte_size(terminal.response_hash) == 32
    refute inspect(terminal) =~ @private_response
    refute inspect(terminal) =~ @private_prompt
  end

  test "SPEC.md §10.10 none omits request shape while full retains approved content" do
    {:ok, none} = Requests.create_request(request_attrs(:none))
    assert none.request_shape == nil
    assert none.canonical_request == nil

    {:ok, full} = Requests.create_request(request_attrs(:full))
    assert full.canonical_request["rendered_prompt"] == @private_prompt
    assert full.request_payload == %{"prompt" => @private_prompt}

    assert {:ok, full} =
             Requests.mark_terminal(full, %{
               state: :completed,
               response_payload: %{"output_text" => @private_response},
               response_preview: @private_response
             })

    assert full.response_payload == %{"output_text" => @private_response}
    assert full.response_preview == @private_response
  end

  test "none and metadata schedule persistence accepts valid timestamps and drops malformed values" do
    timestamp = "2026-07-31T04:00:00Z"

    for mode <- [:none, :metadata] do
      {:ok, request} = Requests.create_request(request_attrs(mode))

      assert {:ok, scheduled} =
               Requests.record_schedule(request, %{
                 queue_granted_at: timestamp,
                 queued_at: %{"content" => @private_prompt}
               })

      assert scheduled.scheduler_decision["queue_granted_at"] == timestamp
      refute Map.has_key?(scheduled.scheduler_decision, "queued_at")
      refute inspect(scheduled.scheduler_decision) =~ @private_prompt

      assert {:ok, scheduled} =
               Requests.record_schedule(scheduled, %{
                 queue_granted_at: [@private_prompt],
                 queued_at: timestamp
               })

      assert scheduled.scheduler_decision["queued_at"] == timestamp
      refute Map.has_key?(scheduled.scheduler_decision, "queue_granted_at")
      refute inspect(scheduled.scheduler_decision) =~ @private_prompt
    end
  end

  test "database constraints reject policy bypasses and remain discoverable for drift checks" do
    {:ok, request} = Requests.create_request(request_attrs(:metadata))

    assert {:error, %PostgrexError{postgres: %{constraint: constraint}}} =
             Repo.transaction(fn ->
               case SQL.query(
                      Repo,
                      "UPDATE requests SET response_payload = $1 WHERE id::text = $2",
                      [%{"output_text" => @private_response}, request.id]
                    ) do
                 {:error, error} -> Repo.rollback(error)
                 {:ok, result} -> result
               end
             end)

    assert constraint == "requests_non_full_content_absent"

    %{rows: rows} =
      SQL.query!(
        Repo,
        """
        SELECT conname
        FROM pg_constraint
        WHERE conrelid = 'requests'::regclass
          AND conname LIKE 'requests_%'
        """,
        []
      )

    constraints = MapSet.new(rows, fn [name] -> name end)
    assert "requests_non_full_content_absent" in constraints
    assert "requests_none_shape_and_preview_absent" in constraints
    assert "requests_response_preview_bounded" in constraints
  end

  defp request_attrs(mode, tenant_id \\ Ecto.UUID.generate()) do
    suffix = System.unique_integer([:positive])

    %{
      public_id: "req_capture_#{suffix}",
      endpoint: :responses,
      tenant_id: tenant_id,
      requested_model: "capture-model@v1",
      state: :received,
      stream: false,
      payload_capture_mode: mode,
      body_hash: :crypto.hash(:sha256, "request-#{suffix}"),
      canonical_request: %{
        "endpoint" => "responses",
        "input_items" => [%{"role" => "user", "content" => @private_prompt}],
        "rendered_prompt" => @private_prompt,
        "sampling" => %{"stop" => ["private stop"]}
      },
      request_payload: %{"prompt" => @private_prompt},
      sampling_params: %{"temperature" => 0.5, "stop" => ["private stop"]},
      response_format: %{"type" => "text"}
    }
  end
end
