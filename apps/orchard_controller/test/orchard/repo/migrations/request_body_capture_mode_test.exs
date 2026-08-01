defmodule Orchard.Repo.Migrations.RequestBodyCaptureModeTest do
  use Orchard.DataCase, async: false

  alias Ecto.Adapters.SQL
  alias Orchard.Repo
  alias Orchard.Repo.Migrations.RequestBodyCaptureMode
  alias Orchard.Requests
  alias Orchard.Requests.{CapturePolicy, RequestStepEvent}

  import Orchard.TestSupport.ModelRequestFixtures

  @secret "private tool argument that must not survive the purge"

  @migration_path Path.expand(
                    "../../../../priv/repo/migrations/20260731010000_request_body_capture_mode.exs",
                    __DIR__
                  )

  Code.require_file(@migration_path)

  test "legacy purge retains only typed cache-affinity feedback" do
    affinity_key = "hmac-sha256:#{String.duplicate("a", 64)}"

    request =
      create_request!(%{
        payload_capture_mode: :metadata,
        scheduler_decision: %{
          "cache_affinity_enabled" => true,
          "cache_affinity_key" => affinity_key,
          "cache_affinity_hint_available" => true,
          "cache_affinity_selected_match" => false,
          "cache_affinity_source" => "recent_completed_request",
          "cache_affinity_candidate_count" => 2,
          "prompt" => "must be purged",
          "scored_candidates" => [%{"diagnostics" => "must be purged"}]
        }
      })

    run_legacy_scheduler_purge!(request.id)

    assert Repo.reload!(request).scheduler_decision == %{
             "cache_affinity_enabled" => true,
             "cache_affinity_key" => affinity_key,
             "cache_affinity_hint_available" => true,
             "cache_affinity_selected_match" => false,
             "cache_affinity_source" => "recent_completed_request",
             "cache_affinity_candidate_count" => 2
           }
  end

  test "legacy purge drops malformed cache-affinity values" do
    request =
      create_request!(%{
        payload_capture_mode: :none,
        scheduler_decision: %{
          "cache_affinity_enabled" => "true",
          "cache_affinity_key" => "hmac-sha256:#{String.duplicate("g", 64)}",
          "cache_affinity_hint_available" => %{"content" => "secret"},
          "cache_affinity_selected_match" => ["secret"],
          "cache_affinity_source" => "caller-controlled",
          "cache_affinity_candidate_count" => -1
        }
      })

    run_legacy_scheduler_purge!(request.id)

    assert Repo.reload!(request).scheduler_decision == %{}
  end

  test "legacy purge normalizes runtime-controlled error codes with application parity" do
    assert MapSet.new(RequestBodyCaptureMode.stable_error_codes()) ==
             MapSet.new(CapturePolicy.stable_error_codes())

    request =
      create_request!(%{
        payload_capture_mode: :full,
        error_code: "runtime echoed private content"
      })

    SQL.query!(
      Repo,
      """
      UPDATE requests
      SET payload_capture_mode = 'metadata',
          error_code = #{RequestBodyCaptureMode.legacy_stable_error_code_sql()}
      WHERE id::text = $1
      """,
      [request.id]
    )

    assert Repo.reload!(request).error_code == "internal_error"
  end

  test "legacy purge keeps request_step events readable without model-generated content" do
    assert MapSet.new(RequestBodyCaptureMode.step_event_types()) ==
             MapSet.new(RequestStepEvent.step_event_types())

    request = create_request!(%{payload_capture_mode: :metadata})

    {:ok, _step_events} =
      Requests.append_request_step_events(request, [
        %{
          event_type: "request_step.proposed",
          step_id: RequestStepEvent.tool_call_step_id(1, "call_1"),
          step_type: "tool_call",
          turn_index: 1,
          attempt: 1,
          parent_step_id: RequestStepEvent.inference_turn_step_id(1, 1),
          boundary: "post_observation",
          call_id: "call_1",
          tool_name: "lookup",
          arguments_json: ~s({"city":"#{@secret}"}),
          result: %{"finish_reason" => "tool_calls"}
        }
      ])

    restore_legacy_step_payload!(request.id)
    run_legacy_step_event_purge!(request.id)

    assert [step_event] = Requests.list_request_step_events(request)
    assert step_event.step_type == "tool_call"
    assert step_event.turn_index == 1
    assert step_event.attempt == 1
    assert step_event.boundary == "post_observation"
    assert step_event.parent_step_id == RequestStepEvent.inference_turn_step_id(1, 1)
    assert step_event.result == %{"finish_reason" => "tool_calls"}
    assert step_event.arguments_json == nil
    refute step_event.call_id == "call_1"
    refute inspect(step_event) =~ @secret
  end

  test "legacy inference result purge matches restricted runtime sanitization" do
    cases = [
      %{"error_code" => "request_cancelled", "error_message" => @secret},
      %{"error_code" => @secret, "error_message" => @secret},
      %{"finish_reason" => "stop"},
      %{"finish_reason" => nil},
      %{},
      @secret
    ]

    for {result, index} <- Enum.with_index(cases, 1) do
      request =
        create_request!(%{
          public_id: "legacy-inference-result-#{index}",
          payload_capture_mode: :full
        })

      event_attrs = legacy_inference_event_attrs(result)
      assert {:ok, _event} = Requests.append_request_event(request, event_attrs)

      expected_payload = CapturePolicy.event_attrs(:metadata, event_attrs).payload

      run_legacy_step_event_purge!(request.id)

      assert [event] = Requests.list_request_events(request)
      assert event.payload == expected_payload
      refute inspect(event.payload) =~ @secret
    end
  end

  defp legacy_inference_event_attrs(result) do
    %{
      event_type: "request_step.completed",
      payload: %{
        "step_id" => RequestStepEvent.inference_turn_step_id(1, 1),
        "step_type" => "inference_turn",
        "turn_index" => 1,
        "attempt" => 1,
        "parent_step_id" => nil,
        "boundary" => "post_observation",
        "result" => result
      }
    }
  end

  defp restore_legacy_step_payload!(request_id) do
    SQL.query!(
      Repo,
      """
      UPDATE request_events
      SET payload = payload || jsonb_build_object(
            'call_id', 'call_1'::text,
            'tool_name', 'lookup'::text,
            'arguments_json', $2::text,
            'step_id', 'tool_call:t1:ccall_1'::text,
            'result', jsonb_build_object(
              'finish_reason', 'tool_calls'::text,
              'error_message', $2::text
            )
          )
      WHERE request_id::text = $1
      """,
      [request_id, ~s({"city":"#{@secret}"})]
    )
  end

  defp run_legacy_step_event_purge!(request_id) do
    SQL.query!(
      Repo,
      """
      UPDATE request_events AS event
      SET payload = #{RequestBodyCaptureMode.legacy_step_event_payload_sql()}
      WHERE event.request_id::text = $1
      """,
      [request_id]
    )
  end

  defp run_legacy_scheduler_purge!(request_id) do
    SQL.query!(
      Repo,
      """
      UPDATE requests
      SET scheduler_decision = #{RequestBodyCaptureMode.legacy_cache_affinity_metadata_sql()}
      WHERE id::text = $1
      """,
      [request_id]
    )
  end
end
