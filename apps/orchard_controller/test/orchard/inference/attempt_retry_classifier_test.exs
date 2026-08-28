defmodule Orchard.Inference.AttemptRetryClassifierTest do
  use ExUnit.Case, async: true

  alias Orchard.Inference.AttemptRetryClassifier

  @runtime_codes ~w(
    node_unavailable node_timeout runtime_unavailable resource_exhausted timeout
    worker_unavailable worker_down
  )
  @model_load_codes ~w(acquisition_failed runtime_unavailable resource_exhausted load_timeout)
  @pre_acceptance_codes ~w(node_unavailable node_timeout runtime_unavailable rpc_unavailable)

  test "SPEC.md §5.8 classifies every retry-eligible failure before alternate scheduling" do
    cases =
      Enum.map(@runtime_codes, &{"runtime_failure", &1, true}) ++
        Enum.map(@model_load_codes, &{"model_load_failure", &1, nil}) ++
        Enum.map(@pre_acceptance_codes, &{"pre_acceptance_unavailable", &1, false}) ++
        [{"worker_or_node_loss", "worker_down", nil}]

    for {failure_class, failure_code, runtime_retryable} <- cases do
      boundary =
        boundary(%{
          failure_class: failure_class,
          failure_code: failure_code,
          runtime_retryable: runtime_retryable
        })

      assert AttemptRetryClassifier.pre_schedule(boundary) == :eligible_for_alternate
      assert AttemptRetryClassifier.finalize_alternate(boundary, :different_node) == :retried

      assert AttemptRetryClassifier.finalize_alternate(boundary, :no_candidate) ==
               :no_alternative_node

      assert AttemptRetryClassifier.finalize_alternate(boundary, :identity_unresolved) ==
               :identity_unresolved
    end
  end

  test "SPEC.md §5.8 requires both the runtime retry flag and an allowlisted transient code" do
    for failure_code <- @runtime_codes, runtime_retryable <- [nil, false] do
      assert classify(%{
               failure_class: "runtime_failure",
               failure_code: failure_code,
               runtime_retryable: runtime_retryable
             }) == {:declined, :not_retryable}
    end

    for runtime_retryable <- [nil, false, true] do
      assert classify(%{
               failure_class: "runtime_failure",
               failure_code: "model_invalid",
               runtime_retryable: runtime_retryable
             }) == {:declined, :not_retryable}
    end
  end

  test "SPEC.md §5.8 ignores the runtime flag for model-load and pre-acceptance eligibility" do
    for runtime_retryable <- [nil, false, true],
        {failure_class, failure_code} <- [
          {"model_load_failure", "load_timeout"},
          {"pre_acceptance_unavailable", "rpc_unavailable"}
        ] do
      assert classify(%{
               failure_class: failure_class,
               failure_code: failure_code,
               runtime_retryable: runtime_retryable
             }) == :eligible_for_alternate
    end
  end

  test "SPEC.md §5.8 honors explicit runtime retry refusal for worker or node loss" do
    assert classify(%{
             failure_class: "worker_or_node_loss",
             failure_code: "worker_down",
             runtime_retryable: false
           }) == {:declined, :not_retryable}

    for runtime_retryable <- [nil, true] do
      assert classify(%{
               failure_class: "worker_or_node_loss",
               failure_code: "worker_down",
               runtime_retryable: runtime_retryable
             }) == :eligible_for_alternate
    end
  end

  test "SPEC.md §5.8 fails closed for deterministic and unknown taxonomy rows" do
    cases = [
      {"model_load_failure", "model_invalid"},
      {"model_load_failure", "internal_error"},
      {"pre_acceptance_unavailable", "internal_error"},
      {"terminal_conformance", "runtime_endpoint_terminal_invalid"},
      {"capacity_rejection", "model_busy"},
      {"controller_failure", "orchestration_error"},
      {"controller_failure", "request_controller_restarted"},
      {"unknown", "internal_error"},
      {"cancellation", "request_cancelled"},
      {"deadline", "request_timeout"}
    ]

    for {failure_class, failure_code} <- cases do
      assert classify(%{
               failure_class: failure_class,
               failure_code: failure_code,
               runtime_retryable: true
             }) == {:declined, :not_retryable}
    end
  end

  test "SPEC.md §5.8 preserves named unresolved failure classes" do
    assert classify(%{failure_class: "identity_unresolved"}) ==
             {:declined, :identity_unresolved}

    assert classify(%{failure_class: "occupancy_unresolved"}) ==
             {:declined, :occupancy_unresolved}
  end

  test "SPEC.md §5.8 applies attempt 1 decline gates in order" do
    eligible = %{
      failure_class: "worker_or_node_loss",
      failure_code: "worker_down",
      runtime_retryable: true
    }

    assert classify(
             Map.merge(eligible, %{
               output_committed: true,
               caller_status: :cancelled,
               deadline_status: :exhausted
             })
           ) ==
             {:declined, :output_committed}

    assert classify(
             Map.merge(eligible, %{caller_status: :cancelled, deadline_status: :exhausted})
           ) ==
             {:declined, :cancelled}

    assert classify(Map.put(eligible, :deadline_status, :exhausted)) ==
             {:declined, :budget_exhausted}

    assert classify(Map.put(eligible, :caller_status, :cancelled)) == {:declined, :cancelled}

    assert classify(%{
             failure_class: "identity_unresolved",
             failure_code: "internal_error",
             runtime_retryable: nil,
             caller_status: :cancelled
           }) == {:declined, :cancelled}
  end

  test "SPEC.md §5.8 uses exact identity, execution, and release evidence" do
    eligible = %{
      failure_class: "worker_or_node_loss",
      failure_code: "worker_down",
      runtime_retryable: true
    }

    assert classify(Map.put(eligible, :identity_resolution, :unresolved)) ==
             {:declined, :identity_unresolved}

    assert classify(Map.put(eligible, :execution_resolution, :unresolved)) ==
             {:declined, :occupancy_unresolved}

    assert classify(Map.put(eligible, :capacity_release_outcome, :unresolved)) ==
             {:declined, :occupancy_unresolved}

    assert classify(
             Map.merge(eligible, %{
               identity_resolution: :unresolved,
               execution_resolution: :unresolved,
               capacity_release_outcome: :unresolved
             })
           ) == {:declined, :identity_unresolved}

    assert classify(%{
             failure_class: "terminal_conformance",
             failure_code: "runtime_endpoint_terminal_invalid",
             runtime_retryable: true,
             execution_resolution: :unresolved
           }) == {:declined, :not_retryable}
  end

  test "SPEC.md §7.2.7 bounds attempt 2 to cancellation or retry exhaustion" do
    assert classify(%{attempt: 2, caller_status: :cancelled}) == {:declined, :cancelled}
    assert classify(%{attempt: 2, caller_status: :live}) == {:declined, :retry_exhausted}
  end

  test "constructor requires every exact fact and rejects raw source codes" do
    assert_raise ArgumentError, fn ->
      base_facts()
      |> Map.put(:raw_source_code, "upstream-free-text")
      |> AttemptRetryClassifier.new()
    end

    assert_raise ArgumentError, fn ->
      base_facts()
      |> Map.merge(%{"raw_source_code" => "upstream-free-text"})
      |> AttemptRetryClassifier.new()
    end

    assert_raise FunctionClauseError, fn ->
      # Dynamic dispatch avoids a compile-time type warning for this intentional invalid input.
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      apply(AttemptRetryClassifier, :new, [Map.delete(base_facts(), :capacity_release_outcome)])
    end

    assert_raise FunctionClauseError, fn ->
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      apply(AttemptRetryClassifier, :new, [Map.put(base_facts(), :identity_resolution, true)])
    end
  end

  defp classify(overrides), do: overrides |> boundary() |> AttemptRetryClassifier.pre_schedule()

  defp boundary(overrides),
    do: base_facts() |> Map.merge(overrides) |> AttemptRetryClassifier.new()

  defp base_facts do
    %{
      attempt: 1,
      output_committed: false,
      caller_status: :live,
      deadline_status: :remaining,
      failure_class: "runtime_failure",
      failure_code: "runtime_unavailable",
      runtime_retryable: true,
      identity_resolution: :resolved,
      execution_resolution: :terminated,
      capacity_release_outcome: :released
    }
  end
end
