defmodule Orchard.Node.TensorFoldProjection do
  @moduledoc """
  Binds an explicitly selected experiment history to a fresh Node-owned Worker offer.
  Offers remain outside generic status and are never retained across preparation.
  """

  alias Orchard.Cluster.V1.ExecuteInferenceRequest

  @binding_keys ~w(schema_version profile_id model_id version artifact_sha256 template_sha256 tokenizer_config_sha256 enable_thinking reasoning_effort output_projection)
  @error {:error, :tensorfold_projection_rejected}
  @max_history_bytes 1_048_576

  @spec config() :: map() | nil
  def config, do: Application.get_env(:orchard_node_agent, :tensorfold_experiment_profile)

  @spec selected?(ExecuteInferenceRequest.t(), term()) :: boolean()
  def selected?(request, config) when is_map(config) do
    request.model_id == config["model_id"] and request.version == config["version"]
  end

  def selected?(_request, _config), do: false

  @spec lookup_timeout(ExecuteInferenceRequest.t(), term()) ::
          {:ok, pos_integer()} | {:error, atom()}
  def lookup_timeout(request, config) when is_map(config) do
    remaining = request.deadline_unix_ms - System.system_time(:millisecond)
    timeout = Map.get(config, "offer_timeout_ms", 1_000)

    if valid_config?(config) and selected?(request, config) and remaining > 0 and
         is_integer(timeout) and timeout in 1..1_000 do
      {:ok, min(timeout, remaining)}
    else
      @error
    end
  end

  def lookup_timeout(_request, _config), do: @error

  @spec bind(ExecuteInferenceRequest.t(), binary(), term()) ::
          {:ok, ExecuteInferenceRequest.t()} | {:error, atom()}
  def bind(request, offer_json, config) when is_map(config) do
    with {:ok, _timeout} <- lookup_timeout(request, config),
         {:ok, history} <-
           decode(request.tensorfold_history_projection_json, config["max_projection_bytes"]),
         {:ok, offer} <- decode(offer_json, 4_096),
         true <- is_map(history) and is_map(offer),
         expected = Map.take(config, @binding_keys),
         true <- Map.take(history, @binding_keys) === expected,
         true <- Enum.sort(Map.keys(history)) == Enum.sort(@binding_keys ++ ["messages", "tools"]),
         true <- Map.take(offer, @binding_keys) === expected,
         true <- Enum.sort(Map.keys(offer)) == Enum.sort(@binding_keys ++ ["incarnation"]),
         true <- valid_incarnation?(offer["incarnation"]),
         true <- valid_history?(history),
         {:ok, payload} <- Jason.encode(Map.put(history, "incarnation", offer["incarnation"])),
         true <- byte_size(payload) <= config["max_projection_bytes"] do
      {:ok, %{request | tensorfold_history_projection_json: payload}}
    else
      _other -> @error
    end
  end

  def bind(_request, _offer, _config), do: @error

  defp valid_config?(config) do
    config["schema_version"] === 1 and config["enable_thinking"] === true and
      config["reasoning_effort"] == "medium" and config["output_projection"] == "legacy_blended" and
      Enum.all?(~w(profile_id model_id), &bounded_string?(config[&1], 256)) and
      Enum.all?(
        ~w(version artifact_sha256 template_sha256 tokenizer_config_sha256),
        &digest?(config[&1])
      ) and
      is_integer(config["max_projection_bytes"]) and
      config["max_projection_bytes"] in 1..@max_history_bytes
  end

  defp bounded_string?(value, limit), do: is_binary(value) and byte_size(value) in 1..limit
  defp digest?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  defp valid_incarnation?(value),
    do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{32}\z/, value)

  defp valid_history?(%{"messages" => [_ | _] = messages, "tools" => tools})
       when is_list(tools) do
    Enum.all?(messages, fn message ->
      is_map(message) and message["role"] in ~w(system developer user assistant tool) and
        valid_content?(message) and
        not Enum.any?(
          ~w(reasoning reasoning_content reasoning_details thinking),
          &Map.has_key?(message, &1)
        )
    end)
  end

  defp valid_history?(_history), do: false

  defp valid_content?(%{"content" => content}) when is_binary(content) or is_list(content),
    do: true

  defp valid_content?(%{"role" => "assistant", "content" => nil, "tool_calls" => [_ | _]}),
    do: true

  defp valid_content?(_message), do: false

  defp decode(payload, limit)
       when is_binary(payload) and byte_size(payload) > 0 and byte_size(payload) <= limit do
    with {:ok, object} <- Jason.decode(payload, objects: :ordered_objects) do
      flatten(object, 0)
    end
  end

  defp decode(_payload, _limit), do: @error

  defp flatten(_value, depth) when depth > 64, do: @error

  defp flatten(%Jason.OrderedObject{values: pairs}, depth) do
    Enum.reduce_while(pairs, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case flatten(value, depth + 1) do
        {:ok, decoded} when not is_map_key(acc, key) -> {:cont, {:ok, Map.put(acc, key, decoded)}}
        _other -> {:halt, @error}
      end
    end)
  end

  defp flatten(values, depth) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case flatten(value, depth + 1) do
        {:ok, decoded} -> {:cont, {:ok, [decoded | acc]}}
        _other -> {:halt, @error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp flatten(value, _depth), do: {:ok, value}
end
