defmodule Orchard.Requests.InferenceAttemptFailure do
  @moduledoc """
  Normalizes structured attempt failures to the closed durable evidence vocabulary.
  """

  @stable_error_codes ~w(
    acquisition_failed artifact_not_found cancelled checksum_mismatch cluster_busy
    deadline_exceeded insufficient_memory internal_error load_timeout manifest_not_found
    mlx_backend_unavailable model_busy model_invalid node_timeout node_unavailable
    orchestration_error queue_full queue_timeout request_cancelled request_caller_disconnect
    request_client_disconnect request_controller_restarted request_interrupted request_timeout
    resource_exhausted rpc_error rpc_resource_exhausted rpc_unavailable runtime_incompatible
    runtime_unavailable timed_out timeout tool_execution_cancelled tool_execution_failed
    tool_execution_indeterminate_cancel_ack_missing
    tool_execution_indeterminate_controller_restarted
    tool_execution_indeterminate_executor_unreachable
    tool_execution_indeterminate_result_not_observed
    tool_execution_indeterminate_timeout_after_start tool_execution_timed_out tool_failed
    tool_timeout tooling_not_supported unexpected_placement_state worker_down worker_unavailable
    worker_unloaded
  )

  @failure_classes ~w(
    pre_acceptance_unavailable model_load_failure worker_or_node_loss runtime_failure
    terminal_conformance capacity_rejection cancellation deadline controller_failure
    occupancy_unresolved identity_unresolved
  )
  @model_load_codes ~w(
    load_timeout acquisition_failed runtime_unavailable resource_exhausted model_invalid internal_error
  )
  @acceptance_proof_failure_class "pre_acceptance_unavailable"
  @acceptance_proof_failure_code "runtime_incompatible"
  @type evidence :: %{required(String.t()) => String.t()}

  @spec stable_error_codes() :: [String.t()]
  def stable_error_codes, do: @stable_error_codes

  @spec failure_classes() :: [String.t()]
  def failure_classes, do: @failure_classes

  @spec model_load_codes() :: [String.t()]
  def model_load_codes, do: @model_load_codes

  @spec acceptance_proof_failure?(String.t(), String.t()) :: boolean()
  def acceptance_proof_failure?(
        @acceptance_proof_failure_class,
        @acceptance_proof_failure_code
      ),
      do: true

  def acceptance_proof_failure?(_failure_class, _failure_code), do: false

  @spec normalize(map()) :: evidence()
  def normalize(source) when is_map(source) do
    category = value(source, :category)
    code = normalize_code(value(source, :code))
    phase = value(source, :phase)

    {failure_class, failure_code} = classify(category, code, phase)

    %{"failure_class" => failure_class, "failure_code" => failure_code}
    |> maybe_put_raw_source_code(code, failure_code)
  end

  def normalize(_source),
    do: %{"failure_class" => "controller_failure", "failure_code" => "internal_error"}

  defp classify(category, code, phase) do
    case classify_primary(category, code) do
      nil -> classify_secondary(category, code, phase)
      classification -> classification
    end
  end

  defp classify_primary(category, code) do
    cond do
      category in [:cancellation, "cancellation", :caller_disconnect, "caller_disconnect"] ->
        {"cancellation", cancellation_code(code)}

      category in [:deadline, "deadline", :timeout, "timeout"] ->
        {"deadline", deadline_code(code)}

      category in [:terminal_conformance, "terminal_conformance"] ->
        {"terminal_conformance", "orchestration_error"}

      category in [:capacity, "capacity", :capacity_rejection, "capacity_rejection"] ->
        {capacity_failure_class(code), capacity_code(code)}

      true ->
        nil
    end
  end

  defp classify_secondary(category, code, phase) do
    cond do
      category in [:model_load, "model_load"] or phase in [:model_load, "model_load"] ->
        {"model_load_failure", model_load_code(code)}

      category in [:worker_or_node_loss, "worker_or_node_loss", :node_loss, "node_loss"] ->
        {"worker_or_node_loss", allowlisted_or_internal(code)}

      category in [:runtime, "runtime", :runtime_failure, "runtime_failure"] ->
        {"runtime_failure", allowlisted_or_internal(code)}

      category in [:pre_acceptance, "pre_acceptance", :transport, "transport"] ->
        {"pre_acceptance_unavailable", pre_acceptance_code(code)}

      category in [:identity_unresolved, "identity_unresolved"] ->
        {"identity_unresolved", allowlisted_or_internal(code)}

      category in [:occupancy_unresolved, "occupancy_unresolved"] ->
        {"occupancy_unresolved", allowlisted_or_internal(code)}

      true ->
        {"controller_failure", controller_code(code)}
    end
  end

  defp normalize_code(code) when is_atom(code), do: Atom.to_string(code)
  defp normalize_code(code) when is_binary(code) and code != "", do: code
  defp normalize_code(_code), do: nil

  defp allowlisted_or_internal(code) when code in @stable_error_codes, do: code
  defp allowlisted_or_internal(_code), do: "internal_error"

  defp cancellation_code(code)
       when code in ["request_caller_disconnect", "request_client_disconnect"],
       do: "request_caller_disconnect"

  defp cancellation_code("request_cancelled"), do: "request_cancelled"
  defp cancellation_code(_code), do: "request_cancelled"

  defp deadline_code(code)
       when code in ["deadline_exceeded", "request_timeout", "timeout", "timed_out"],
       do: code

  defp deadline_code(_code), do: "request_timeout"

  defp model_load_code("timeout"), do: "load_timeout"

  defp model_load_code(code)
       when code in @model_load_codes,
       do: code

  defp model_load_code(_code), do: "internal_error"

  defp pre_acceptance_code(code)
       when code in [
              "node_unavailable",
              "node_timeout",
              "runtime_incompatible",
              "runtime_unavailable",
              "rpc_unavailable"
            ],
       do: code

  defp pre_acceptance_code(_code), do: "internal_error"

  defp capacity_failure_class("dispatch_capacity_caller_down"), do: "cancellation"

  defp capacity_failure_class("dispatch_capacity_node_identity_mismatch"),
    do: "identity_unresolved"

  defp capacity_failure_class(code)
       when code in [
              "dispatch_capacity_request_already_claimed",
              "dispatch_capacity_quarantine_store_unavailable"
            ],
       do: "occupancy_unresolved"

  defp capacity_failure_class(_code), do: "capacity_rejection"

  defp capacity_code("dispatch_capacity_caller_down"), do: "request_caller_disconnect"
  defp capacity_code("dispatch_capacity_acceptance_gate_busy"), do: "resource_exhausted"
  defp capacity_code("dispatch_capacity_unavailable"), do: "resource_exhausted"
  defp capacity_code("dispatch_capacity_facts_unavailable"), do: "orchestration_error"
  defp capacity_code("dispatch_capacity_node_identity_mismatch"), do: "unexpected_placement_state"
  defp capacity_code("dispatch_capacity_request_already_claimed"), do: "orchestration_error"
  defp capacity_code("dispatch_capacity_quarantine_store_unavailable"), do: "orchestration_error"
  defp capacity_code(code), do: allowlisted_or_internal(code)

  defp controller_code(code) when code in ["orchestration_error", "request_interrupted"], do: code
  defp controller_code(_code), do: "internal_error"

  defp maybe_put_raw_source_code(evidence, nil, _stable), do: evidence
  defp maybe_put_raw_source_code(evidence, stable, stable), do: evidence

  defp maybe_put_raw_source_code(evidence, raw_source_code, _stable),
    do: Map.put(evidence, "raw_source_code", raw_source_code)

  defp value(source, key), do: Map.get(source, key, Map.get(source, Atom.to_string(key)))
end
