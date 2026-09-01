defmodule Orchard.Metrics.Normalizer do
  @moduledoc false

  alias Orchard.Metrics.Catalog
  alias Orchard.Requests.{InferenceAttemptFailure, InferenceAttemptResult}

  @values %{
    http_endpoint: ~w(public_api operator_api admin_api console health metrics static unmatched),
    method: ~w(GET POST PUT PATCH DELETE OPTIONS OTHER),
    http_status: ~w(informational success redirect client_error server_error),
    inference_endpoint: ~w(chat_completions responses),
    inference_status: ~w(completed failed cancelled timed_out interrupted),
    scheduler_result: ~w(selected no_active_nodes cluster_busy model_busy),
    scheduler_tier: ~w(loaded cached cold none),
    scheduler_reason:
      ~w(no_active_nodes cluster_busy model_busy queue_full queue_timeout request_caller_disconnect internal),
    quota_reason:
      ~w(requests_per_minute input_tokens_per_day output_tokens_per_day tenant_concurrency),
    audit_action:
      ~w(tenant api_key service_account role_binding routing_policy tenant_model_access support_bundle node_admission node_lifecycle circuit_breaker cluster portal_user),
    audit_outcome: ~w(succeeded failed denied)
  }

  @spec normalize(atom(), map()) :: {:ok, map()} | {:error, :invalid_labels}
  def normalize(family, labels) when is_map(labels) do
    with {:ok, descriptor} <- Catalog.descriptor(family),
         true <- MapSet.new(Map.keys(labels)) == MapSet.new(descriptor.labels),
         {:ok, normalized} <- normalize_labels(family, labels),
         true <- valid_pair?(family, normalized) do
      {:ok, normalized}
    else
      _error -> {:error, :invalid_labels}
    end
  end

  def normalize(_family, _labels), do: {:error, :invalid_labels}

  defp normalize_labels(family, labels) do
    Enum.reduce_while(labels, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case normalize_value(family, key, value) do
        {:ok, normalized} -> {:cont, {:ok, Map.put(acc, key, normalized)}}
        :error -> {:halt, {:error, :invalid_labels}}
      end
    end)
  end

  defp normalize_value(_family, key, value) when key in [:tenant, :model, :node] do
    if is_binary(value) and value != "", do: {:ok, value}, else: :error
  end

  defp normalize_value(:http_requests, :endpoint, value), do: bounded(:http_endpoint, value)

  defp normalize_value(:http_request_duration, :endpoint, value),
    do: bounded(:http_endpoint, value)

  defp normalize_value(:http_requests, :method, value), do: method(value)

  defp normalize_value(family, :status, value)
       when family in [:http_requests, :http_request_duration], do: http_status(value)

  defp normalize_value(:inference_requests, :endpoint, value),
    do: bounded(:inference_endpoint, value)

  defp normalize_value(family, :status, value)
       when family in [:inference_requests, :inference_request_duration],
       do: bounded(:inference_status, value)

  defp normalize_value(family, :attempt, value)
       when family in [:inference_attempts, :inference_attempt_duration],
       do: bounded_values(~w(1 2), value)

  defp normalize_value(family, :outcome, value)
       when family in [:inference_attempts, :inference_attempt_duration],
       do: bounded_values(InferenceAttemptResult.attempt_outcomes(), value)

  defp normalize_value(:inference_attempts, :failure_class, value) do
    bounded_values(InferenceAttemptFailure.failure_classes() ++ ["none"], value)
  end

  defp normalize_value(:inference_retries, :reason, value),
    do: bounded_values(InferenceAttemptResult.attempt_one_retry_decisions(), value)

  defp normalize_value(:inference_retries, :result, value),
    do: bounded_values(~w(succeeded failed declined), value)

  defp normalize_value(:scheduler_decisions, :result, value),
    do: bounded(:scheduler_result, value)

  defp normalize_value(:scheduler_decisions, :tier, value), do: bounded(:scheduler_tier, value)

  defp normalize_value(:scheduler_rejections, :reason, value),
    do: bounded(:scheduler_reason, value)

  defp normalize_value(:quota_rejections, :reason, value), do: bounded(:quota_reason, value)
  defp normalize_value(:audit_events, :action, value), do: bounded(:audit_action, value)
  defp normalize_value(:audit_events, :outcome, value), do: bounded(:audit_outcome, value)
  defp normalize_value(_family, _key, _value), do: :error

  defp bounded(kind, value) do
    bounded_values(Map.fetch!(@values, kind), value)
  end

  defp bounded_values(values, value) do
    value = to_string(value)
    if value in values, do: {:ok, value}, else: :error
  end

  defp method(value) do
    normalized = value |> to_string() |> String.upcase()
    {:ok, if(normalized in @values.method, do: normalized, else: "OTHER")}
  end

  defp http_status(value) when is_integer(value) and value in 100..599 do
    {:ok, Enum.at(@values.http_status, div(value, 100) - 1)}
  end

  defp http_status(value), do: bounded(:http_status, value)

  defp valid_pair?(:scheduler_decisions, %{result: "selected", tier: tier}),
    do: tier in ~w(loaded cached cold)

  defp valid_pair?(:scheduler_decisions, %{tier: "none"}), do: true
  defp valid_pair?(:scheduler_decisions, _labels), do: false

  defp valid_pair?(:inference_attempts, %{outcome: "completed", failure_class: "none"}),
    do: true

  defp valid_pair?(:inference_attempts, %{outcome: outcome, failure_class: failure_class}),
    do: outcome != "completed" and failure_class != "none"

  defp valid_pair?(:inference_retries, %{reason: "retried", result: result}),
    do: result in ~w(succeeded failed)

  defp valid_pair?(:inference_retries, %{reason: reason, result: "declined"}),
    do: reason != "retried"

  defp valid_pair?(:inference_retries, _labels), do: false
  defp valid_pair?(_family, _labels), do: true
end
