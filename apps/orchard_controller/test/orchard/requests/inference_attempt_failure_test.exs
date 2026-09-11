defmodule Orchard.Requests.InferenceAttemptFailureTest do
  use ExUnit.Case, async: true

  alias Orchard.Inference.ModelLoadFailure
  alias Orchard.Requests.InferenceAttemptFailure

  test "normalizes structured source categories without inspecting messages" do
    assert InferenceAttemptFailure.normalize(%{
             category: :model_load,
             code: :acquisition_failed,
             message: "arbitrary private text"
           }) == %{
             "failure_class" => "model_load_failure",
             "failure_code" => "acquisition_failed"
           }

    assert InferenceAttemptFailure.normalize(%{category: :deadline, code: :foreign_timeout}) == %{
             "failure_class" => "deadline",
             "failure_code" => "request_timeout",
             "raw_source_code" => "foreign_timeout"
           }
  end

  test "capacity cancellation, identity, and occupancy retain closed classifications" do
    assert normalized(:capacity, :dispatch_capacity_caller_down) ==
             {"cancellation", "request_caller_disconnect"}

    assert normalized(:capacity, :dispatch_capacity_node_identity_mismatch) ==
             {"identity_unresolved", "unexpected_placement_state"}

    assert normalized(:capacity, :dispatch_capacity_request_already_claimed) ==
             {"occupancy_unresolved", "orchestration_error"}
  end

  test "normalizes every durable source category to a closed failure class and code" do
    cases = [
      {%{category: :runtime, code: :runtime_unavailable},
       {"runtime_failure", "runtime_unavailable"}},
      {%{category: :model_load, code: :model_invalid}, {"model_load_failure", "model_invalid"}},
      {%{category: :model_load, code: :timeout}, {"model_load_failure", "load_timeout"}},
      {%{category: :model_load, code: :load_timeout}, {"model_load_failure", "load_timeout"}},
      {%{category: :capacity, code: :dispatch_capacity_acceptance_gate_busy},
       {"capacity_rejection", "resource_exhausted"}},
      {%{category: :cancellation, code: :request_client_disconnect},
       {"cancellation", "request_caller_disconnect"}},
      {%{category: :deadline, code: :deadline_exceeded}, {"deadline", "deadline_exceeded"}},
      {%{category: :terminal_conformance, code: :private_terminal_code},
       {"terminal_conformance", "orchestration_error"}},
      {%{category: :controller, code: :request_interrupted},
       {"controller_failure", "request_interrupted"}},
      {%{category: :worker_or_node_loss, code: :worker_down},
       {"worker_or_node_loss", "worker_down"}},
      {%{category: :unknown, code: :private_code}, {"controller_failure", "internal_error"}}
    ]

    for {source, expected} <- cases do
      assert normalized(source.category, source.code) == expected
    end
  end

  test "SPEC.md §7.5.3a maps only closed reasoning conformance codes to internal_error" do
    for code <- [
          :reasoning_parser_conformance_failed,
          :reasoning_policy_conformance_failed
        ] do
      assert InferenceAttemptFailure.normalize(%{
               category: :terminal_conformance,
               code: code,
               message: "<think>untrusted model output</think>"
             }) == %{
               "failure_class" => "terminal_conformance",
               "failure_code" => "internal_error"
             }

      assert InferenceAttemptFailure.reasoning_conformance_code?(Atom.to_string(code))
    end

    refute InferenceAttemptFailure.reasoning_conformance_code?(
             "runtime_endpoint_missing_terminal"
           )
  end

  test "untrusted pre-acceptance codes do not acquire retryable stable codes" do
    assert InferenceAttemptFailure.normalize(%{
             category: :pre_acceptance,
             code: :private_transport_code
           }) == %{
             "failure_class" => "pre_acceptance_unavailable",
             "failure_code" => "internal_error",
             "raw_source_code" => "private_transport_code"
           }
  end

  test "SPEC.md §7.2.7 preserves runtime-incompatible pre-acceptance evidence" do
    evidence =
      InferenceAttemptFailure.normalize(%{
        category: :pre_acceptance,
        code: :runtime_incompatible
      })

    assert evidence == %{
             "failure_class" => "pre_acceptance_unavailable",
             "failure_code" => "runtime_incompatible"
           }

    assert InferenceAttemptFailure.acceptance_proof_failure?(
             evidence["failure_class"],
             evidence["failure_code"]
           )
  end

  test "SPEC.md §7.5.3a closes the shared acceptance-proof evidence pair" do
    for {failure_class, failure_code} <- [
          {"pre_acceptance_unavailable", "runtime_unavailable"},
          {"runtime_failure", "runtime_incompatible"},
          {"pre_acceptance_unavailable", "internal_error"}
        ] do
      refute InferenceAttemptFailure.acceptance_proof_failure?(failure_class, failure_code)
    end
  end

  test "unknown source failures fail closed" do
    assert InferenceAttemptFailure.normalize(%{category: :unknown, code: :private_code}) == %{
             "failure_class" => "controller_failure",
             "failure_code" => "internal_error",
             "raw_source_code" => "private_code"
           }
  end

  test "exposes the complete durable model-load code vocabulary" do
    assert MapSet.new(InferenceAttemptFailure.model_load_codes()) ==
             MapSet.new([
               "load_timeout",
               "acquisition_failed",
               "runtime_unavailable",
               "resource_exhausted",
               "model_invalid",
               "internal_error"
             ])
  end

  test "every durable model-load code maps to its intended public category" do
    expected_categories = %{
      "load_timeout" => :timeout,
      "acquisition_failed" => :acquisition_failed,
      "runtime_unavailable" => :runtime_unavailable,
      "resource_exhausted" => :resource_exhausted,
      "model_invalid" => :model_invalid,
      "internal_error" => :internal
    }

    for code <- InferenceAttemptFailure.model_load_codes() do
      failure = ModelLoadFailure.from_model_load_code(code)
      assert failure.category == Map.fetch!(expected_categories, code)
      assert failure.code == code
    end
  end

  defp normalized(category, code) do
    evidence = InferenceAttemptFailure.normalize(%{category: category, code: code})
    {evidence["failure_class"], evidence["failure_code"]}
  end
end
