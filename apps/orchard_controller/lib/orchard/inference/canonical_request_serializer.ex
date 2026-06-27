defmodule Orchard.Inference.CanonicalRequestSerializer do
  @moduledoc """
  Serializes canonical requests into plain maps for durable persistence.
  """

  alias Orchard.CanonicalRequest

  @spec serialize(CanonicalRequest.t()) :: map()
  def serialize(%CanonicalRequest{} = canonical) do
    %{
      "internal_id" => canonical.internal_id,
      "public_id" => canonical.public_id,
      "endpoint" => Atom.to_string(canonical.endpoint),
      "tenant_id" => canonical.tenant_id,
      "principal_type" => Atom.to_string(canonical.principal_type),
      "principal_id" => canonical.principal_id,
      "service_account_id" => canonical.service_account_id,
      "api_key_id" => canonical.api_key_id,
      "model_ref" => serialize_model_ref(canonical.model_ref),
      "input_items" => normalize_plain_data(canonical.input_items),
      "rendered_prompt" => canonical.rendered_prompt,
      "input_token_count" => canonical.input_token_count,
      "stream" => canonical.stream?,
      "stream_include_usage" => canonical.stream_include_usage,
      "sampling" => sampling_params(canonical.sampling),
      "response_format" => serialize_response_format(canonical.response_format),
      "tooling" => serialize_tooling(canonical.tooling),
      "metadata" => normalize_plain_data(canonical.metadata),
      "admission" => serialize_admission(canonical.admission),
      "resolved_policy" => serialize_resolved_policy(canonical.resolved_policy)
    }
  end

  @spec sampling_params(CanonicalRequest.Sampling.t()) :: map()
  def sampling_params(%CanonicalRequest.Sampling{} = sampling) do
    %{
      "temperature" => sampling.temperature,
      "top_p" => sampling.top_p,
      "max_output_tokens" => sampling.max_output_tokens,
      "stop" => normalize_plain_data(sampling.stop),
      "seed" => sampling.seed
    }
  end

  defp serialize_model_ref(%CanonicalRequest.ModelRef{} = model_ref) do
    %{
      "model_id" => model_ref.model_id,
      "version" => model_ref.version
    }
  end

  defp serialize_response_format(%CanonicalRequest.ResponseFormat{} = response_format) do
    %{"type" => Atom.to_string(response_format.type)}
  end

  defp serialize_tooling(%CanonicalRequest.Tooling{} = tooling) do
    %{
      "tools" => normalize_plain_data(tooling.tools),
      "requested_tools" => normalize_plain_data(tooling.requested_tools),
      "tool_choice" => normalize_plain_data(tooling.tool_choice),
      "registry_snapshot" => normalize_plain_data(tooling.registry_snapshot),
      "execution_snapshot" => normalize_plain_data(tooling.execution_snapshot)
    }
  end

  defp serialize_admission(%CanonicalRequest.Admission{} = admission) do
    %{
      "timeout_ms" => admission.timeout_ms,
      "queue_wait_ms" => admission.queue_wait_ms,
      "max_cold_start_ms" => admission.max_cold_start_ms
    }
  end

  defp serialize_resolved_policy(%CanonicalRequest.ResolvedPolicy{} = resolved_policy) do
    %{
      "quota_id" => resolved_policy.quota_id,
      "routing_policy_id" => resolved_policy.routing_policy_id,
      "allowed_pool_ids" => normalize_plain_data(resolved_policy.allowed_pool_ids),
      "max_active_requests" => resolved_policy.max_active_requests,
      "residency_preference" => Atom.to_string(resolved_policy.residency_preference)
    }
  end

  defp normalize_plain_data(nil), do: nil

  defp normalize_plain_data(value) when is_binary(value) or is_number(value) or is_boolean(value),
    do: value

  defp normalize_plain_data(value) when is_atom(value), do: Atom.to_string(value)

  defp normalize_plain_data(values) when is_list(values),
    do: Enum.map(values, &normalize_plain_data/1)

  defp normalize_plain_data(%{__struct__: struct_name}) do
    raise ArgumentError,
          "expected plain map data while serializing canonical request, got struct: #{inspect(struct_name)}"
  end

  defp normalize_plain_data(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      {normalize_map_key(key), normalize_plain_data(value)}
    end)
  end

  defp normalize_map_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_map_key(key) when is_binary(key), do: key
  defp normalize_map_key(key), do: to_string(key)
end
