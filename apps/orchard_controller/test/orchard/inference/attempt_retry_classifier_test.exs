defmodule Orchard.Inference.AttemptRetryClassifierTest do
  use ExUnit.Case, async: true

  alias Orchard.Inference.AttemptRetryClassifier

  @runtime_codes ~w(
    node_unavailable node_timeout runtime_unavailable resource_exhausted timeout
    worker_unavailable worker_down
  )
  @model_load_codes ~w(acquisition_failed runtime_unavailable resource_exhausted load_timeout)
  @pre_acceptance_codes ~w(node_unavailable node_timeout runtime_unavailable rpc_unavailable)

  test "SPEC.md §5.8 classifies every retry-eligible failure row through the alternate gate" do
    cases =
      Enum.map(@runtime_codes, &{"runtime_failure", &1, true}) ++
        Enum.map(@model_load_codes, &{"model_load_failure", &1, nil}) ++
        Enum.map(@pre_acceptance_codes, &{"pre_acceptance_unavailable", &1, false}) ++
        [{"worker_or_node_loss", "worker_down", nil}]

    for {failure_class, failure_code, runtime_retryable} <- cases do
      assert decide(%{
               failure_class: failure_class,
               failure_code: failure_code,
               runtime_retryable: runtime_retryable,
               alternate_available?: true
             }) == :retried

      assert decide(%{
               failure_class: failure_class,
               failure_code: failure_code,
               runtime_retryable: runtime_retryable,
               alternate_available?: false
             }) == :no_alternative_node
    end
  end

  test "SPEC.md §5.8 requires both the runtime retry flag and an allowlisted transient code" do
    for failure_code <- @runtime_codes, runtime_retryable <- [nil, false] do
      assert decide(%{
               failure_class: "runtime_failure",
               failure_code: failure_code,
               runtime_retryable: runtime_retryable,
               alternate_available?: true
             }) == :not_retryable
    end

    for runtime_retryable <- [nil, false, true] do
      assert decide(%{
               failure_class: "runtime_failure",
               failure_code: "model_invalid",
               runtime_retryable: runtime_retryable,
               alternate_available?: true
             }) == :not_retryable
    end
  end

  test "SPEC.md §5.8 ignores the runtime flag for model-load and pre-acceptance eligibility" do
    for runtime_retryable <- [nil, false, true],
        {failure_class, failure_code} <- [
          {"model_load_failure", "load_timeout"},
          {"pre_acceptance_unavailable", "rpc_unavailable"},
          {"worker_or_node_loss", "worker_down"}
        ] do
      assert decide(%{
               failure_class: failure_class,
               failure_code: failure_code,
               runtime_retryable: runtime_retryable,
               alternate_available?: true
             }) == :retried
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
      assert decide(%{
               failure_class: failure_class,
               failure_code: failure_code,
               runtime_retryable: true,
               alternate_available?: true
             }) == :not_retryable
    end
  end

  test "SPEC.md §5.8 preserves named unresolved failure classes" do
    assert decide(%{failure_class: "identity_unresolved"}) == :identity_unresolved
    assert decide(%{failure_class: "occupancy_unresolved"}) == :occupancy_unresolved
  end

  test "SPEC.md §5.8 applies attempt 1 decline gates in order" do
    eligible = %{
      failure_class: "worker_or_node_loss",
      failure_code: "worker_down",
      runtime_retryable: true,
      alternate_available?: true
    }

    assert decide(
             Map.merge(eligible, %{
               output_committed: true,
               budget_remaining?: false,
               cancelled?: true
             })
           ) ==
             :output_committed

    assert decide(Map.merge(eligible, %{budget_remaining?: false, cancelled?: true})) ==
             :budget_exhausted

    assert decide(Map.put(eligible, :cancelled?, true)) == :cancelled

    assert decide(%{
             failure_class: "identity_unresolved",
             failure_code: "internal_error",
             runtime_retryable: nil,
             alternate_available?: true,
             cancelled?: true
           }) == :cancelled
  end

  test "SPEC.md §7.2.7 bounds attempt 2 to cancellation or retry exhaustion" do
    assert decide(%{attempt: 2, cancelled?: true}) == :cancelled
    assert decide(%{attempt: 2, cancelled?: false}) == :retry_exhausted
  end

  test "classifier rejects raw source codes and crashes on incomplete or mistyped facts" do
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
      apply(AttemptRetryClassifier, :new, [Map.delete(base_facts(), :failure_code)])
    end

    assert_raise FunctionClauseError, fn ->
      AttemptRetryClassifier.new(Map.put(base_facts(), :attempt, 3))
    end
  end

  defp decide(overrides) do
    base_facts()
    |> Map.merge(overrides)
    |> AttemptRetryClassifier.new()
    |> AttemptRetryClassifier.decide()
  end

  defp base_facts do
    %{
      attempt: 1,
      output_committed: false,
      budget_remaining?: true,
      cancelled?: false,
      failure_class: "runtime_failure",
      failure_code: "runtime_unavailable",
      runtime_retryable: true,
      alternate_available?: false
    }
  end
end
