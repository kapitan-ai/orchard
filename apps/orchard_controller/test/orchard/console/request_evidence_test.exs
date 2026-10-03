defmodule OrchardConsole.RequestEvidenceTest do
  use ExUnit.Case, async: true

  alias Orchard.Requests.RequestEvent
  alias OrchardConsole.RequestEvidence

  @created ~U[2026-09-11 14:32:05.000000Z]

  test "SPEC §3.7.1 separates attempts and keeps legacy timing unknown" do
    events = [
      event(4, 2, "completed"),
      event(2, 1, "failed"),
      event(3, 2, "started"),
      event(1, 1, "started")
    ]

    assert [first, second] = RequestEvidence.attempts(events)
    assert {first.number, first.outcome} == {1, "failed"}
    assert {second.number, second.outcome} == {2, "completed"}
    assert first.started_at == DateTime.add(@created, 100, :millisecond)
    assert second.started_at == DateTime.add(@created, 300, :millisecond)
    assert first.ended_at == nil
    assert second.ended_at == nil
  end

  test "missing starts, conflicting terminals, and non-step events do not fabricate timing" do
    assert [attempt] = RequestEvidence.attempts([event(2, 1, "failed"), event(3, 1, "completed")])
    assert attempt.outcome == "Conflicting terminal evidence"
    assert attempt.started_at == nil
    assert attempt.ended_at == nil

    assert RequestEvidence.attempts([
             %RequestEvent{event_type: "state_transition", state: :completed}
           ]) == []

    assert [active] = RequestEvidence.attempts([event(1, 1, "started")])
    assert active.outcome == "Terminal outcome not recorded"
  end

  test "timeline uses the Request scale, not the attempt span" do
    assert %{left: 20.0, width: 50.0} ==
             RequestEvidence.bar(@created, at(5000), at(1000), at(3500))

    for {start, finish} <- [
          {nil, at(3500)},
          {at(1000), nil},
          {at(-1), at(3500)},
          {at(1000), at(5001)},
          {at(3500), at(1000)}
        ] do
      assert RequestEvidence.bar(@created, at(5000), start, finish) == nil
    end

    assert RequestEvidence.bar(@created, nil, at(1000), at(3500)) == nil
    assert RequestEvidence.bar(@created, @created, @created, @created) == nil

    assert %{left: 20.0, width: 0.0} ==
             RequestEvidence.bar(@created, at(5000), at(1000), at(1000))
  end

  test "TTFT precision and missing measurements remain distinct from measured zero" do
    assert RequestEvidence.duration(nil) == "Not recorded"
    assert RequestEvidence.duration(0) == "0 ms"
    assert RequestEvidence.duration(999) == "999 ms"
    assert RequestEvidence.duration(1000) == "1.00 s"
    assert RequestEvidence.duration(1680) == "1.68 s"
  end

  test "SPEC §5.8 public-output timestamps must lie within the Request interval" do
    request = %{inserted_at: @created, first_token_at: at(1680), completed_at: at(4820)}
    assert RequestEvidence.ttft_ms(request) == 1680
    assert RequestEvidence.ttft_ms(%{request | completed_at: nil}) == 1680
    assert RequestEvidence.ttft_ms(%{request | first_token_at: nil}) == nil
    assert RequestEvidence.ttft_ms(%{request | first_token_at: at(-1)}) == nil
    assert RequestEvidence.ttft_ms(%{request | first_token_at: at(4821)}) == nil
    assert RequestEvidence.ttft_ms(%{request | first_token_at: @created}) == 0
    assert RequestEvidence.ttft_ms(%{request | first_token_at: at(4820)}) == 4820
  end

  defp at(ms), do: DateTime.add(@created, ms, :millisecond)

  defp event(seq, attempt, outcome) do
    %RequestEvent{
      seq: seq,
      event_type: "request_step.#{outcome}",
      occurred_at: at(seq * 100),
      payload: %{
        "step_id" => "inference_turn:t1:a#{attempt}",
        "step_type" => "inference_turn",
        "turn_index" => 1,
        "attempt" => attempt,
        "parent_step_id" => nil,
        "boundary" => if(outcome == "started", do: "pre_side_effect", else: "post_observation"),
        "result" => %{}
      }
    }
  end
end
