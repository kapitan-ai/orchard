defmodule Orchard.Dispatch.AttemptOutcomeTest do
  use ExUnit.Case, async: true

  alias Orchard.Dispatch.AttemptOutcome
  alias Orchard.Requests.InferenceAttemptFailure

  test "SPEC 3.7.1 validates narrow typed single-attempt evidence" do
    started_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    ended_at = DateTime.add(started_at, 5, :millisecond)
    first_token_at = DateTime.add(started_at, 2, :millisecond)
    node_id = Ecto.UUID.generate()

    failure =
      InferenceAttemptFailure.normalize(%{
        category: :runtime_failure,
        code: :worker_down
      })

    assert {:ok, outcome} =
             AttemptOutcome.new(%{
               attempt_outcome: :failed,
               node_id: node_id,
               accepted: true,
               events: [],
               failure: failure,
               execution_resolution: :terminated,
               capacity_release_outcome: :released,
               started_at: started_at,
               ended_at: ended_at,
               first_token_at: first_token_at
             })

    assert %AttemptOutcome{} = outcome
    assert outcome.node_id == node_id
    assert outcome.failure == failure
    assert outcome.first_token_at == first_token_at

    assert {:error, :invalid_attempt_outcome} =
             AttemptOutcome.new(%{
               attempt_outcome: :unknown,
               node_id: nil,
               accepted: false,
               events: [],
               failure: nil,
               execution_resolution: :not_started,
               capacity_release_outcome: :not_applicable,
               started_at: started_at,
               ended_at: ended_at,
               first_token_at: nil
             })
  end
end
