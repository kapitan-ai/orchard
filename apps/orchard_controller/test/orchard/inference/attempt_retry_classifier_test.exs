defmodule Orchard.Inference.AttemptRetryClassifierTest do
  use ExUnit.Case, async: true

  alias Orchard.Inference.AttemptRetryClassifier

  @runtime_codes ~w(
    node_unavailable node_timeout runtime_unavailable resource_exhausted timeout
    worker_unavailable worker_down
  )
  @model_load_cases [
    {:acquisition_failed, "acquisition_failed"},
    {:runtime_unavailable, "runtime_unavailable"},
    {:resource_exhausted, "resource_exhausted"},
    {:timeout, "load_timeout"}
  ]
  @pre_acceptance_codes ~w(node_unavailable node_timeout runtime_unavailable rpc_unavailable)

  test "SPEC.md §5.8 classifies every retry-eligible failure before alternate scheduling" do
    cases =
      Enum.map(@runtime_codes, &{"runtime_failure", &1, nil, true}) ++
        Enum.map(@model_load_cases, fn {category, code} ->
          {"model_load_failure", code, category, nil}
        end) ++
        Enum.map(@pre_acceptance_codes, &{"pre_acceptance_unavailable", &1, nil, false}) ++
        [{"worker_or_node_loss", "worker_down", nil, nil}]

    for {failure_class, failure_code, model_load_category, runtime_retryable} <- cases do
      boundary =
        boundary(%{
          failure_class: failure_class,
          failure_code: failure_code,
          model_load_category: model_load_category,
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
        {failure_class, failure_code, model_load_category} <- [
          {"model_load_failure", "load_timeout", :timeout},
          {"pre_acceptance_unavailable", "rpc_unavailable", nil}
        ] do
      assert classify(%{
               failure_class: failure_class,
               failure_code: failure_code,
               model_load_category: model_load_category,
               runtime_retryable: runtime_retryable
             }) == :eligible_for_alternate
    end
  end

  test "SPEC.md §5.8 authorizes model-load retry from the normalized category only" do
    assert classify(%{
             failure_class: "model_load_failure",
             failure_code: "load_timeout",
             model_load_category: :model_invalid,
             runtime_retryable: nil
           }) == {:declined, :not_retryable}

    assert classify(%{
             failure_class: "model_load_failure",
             failure_code: "internal_error",
             model_load_category: :timeout,
             runtime_retryable: nil
           }) == :eligible_for_alternate
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
      {"model_load_failure", "model_invalid", :model_invalid},
      {"model_load_failure", "internal_error", :internal},
      {"pre_acceptance_unavailable", "internal_error", nil},
      {"terminal_conformance", "runtime_endpoint_terminal_invalid", nil},
      {"capacity_rejection", "model_busy", nil},
      {"controller_failure", "orchestration_error", nil},
      {"controller_failure", "request_controller_restarted", nil},
      {"unknown", "internal_error", nil},
      {"cancellation", "request_cancelled", nil},
      {"deadline", "request_timeout", nil}
    ]

    for {failure_class, failure_code, model_load_category} <- cases do
      assert classify(%{
               failure_class: failure_class,
               failure_code: failure_code,
               model_load_category: model_load_category,
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

  test "SPEC.md §5.8 resolves identity before occupancy for combined unresolved evidence" do
    assert classify(%{
             failure_class: "occupancy_unresolved",
             failure_code: "internal_error",
             runtime_retryable: nil,
             identity_resolution: :unresolved,
             execution_resolution: :unresolved,
             capacity_release_outcome: :unresolved
           }) == {:declined, :identity_unresolved}
  end

  test "SPEC.md §§3.7.1, 5.8, and 7.5.3a preserves the typed acceptance-proof exception" do
    acceptance_proof_failure = %{
      failure_class: "pre_acceptance_unavailable",
      failure_code: "runtime_incompatible",
      runtime_retryable: false
    }

    assert classify(acceptance_proof_failure) == {:declined, :not_retryable}

    assert classify(Map.put(acceptance_proof_failure, :attempt, 2)) ==
             {:declined, :not_retryable}

    assert classify(Map.merge(acceptance_proof_failure, %{attempt: 2, caller_status: :cancelled})) ==
             {:declined, :cancelled}

    assert classify(
             Map.merge(acceptance_proof_failure, %{attempt: 2, deadline_status: :exhausted})
           ) == {:declined, :retry_exhausted}

    assert classify(Map.merge(acceptance_proof_failure, %{attempt: 2, output_committed: true})) ==
             {:declined, :retry_exhausted}

    assert classify(%{
             attempt: 2,
             failure_class: "runtime_failure",
             failure_code: "runtime_incompatible",
             runtime_retryable: false
           }) == {:declined, :retry_exhausted}

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
      model_load_category: nil,
      runtime_retryable: true,
      identity_resolution: :resolved,
      execution_resolution: :terminated,
      capacity_release_outcome: :released
    }
  end
end
