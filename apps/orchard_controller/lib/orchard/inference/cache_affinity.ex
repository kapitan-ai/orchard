defmodule Orchard.Inference.CacheAffinity do
  @moduledoc """
  Controller-local cache-affinity helpers for conservative scheduler hints.
  """

  alias Orchard.CanonicalRequest
  alias Orchard.Requests

  @domain "orchard:v1:cache-affinity:prompt-prefix"
  @default_max_prefix_bytes 8_192
  @default_max_age_ms 300_000
  @default_max_recent_requests 32
  @default_config [
    enabled: false,
    max_prefix_bytes: @default_max_prefix_bytes,
    max_age_ms: @default_max_age_ms,
    max_recent_requests: @default_max_recent_requests,
    hmac_secret: nil
  ]

  @type config :: keyword()
  @type context :: %{
          required(:enabled?) => boolean(),
          optional(:affinity_key) => String.t(),
          optional(:recent_node_ids) => [Ecto.UUID.t()]
        }

  @spec normalize_config(term()) :: config()
  def normalize_config(raw_config) when is_list(raw_config) do
    merged = Keyword.merge(@default_config, raw_config)

    [
      enabled: merged[:enabled] == true,
      max_prefix_bytes:
        positive_integer_or_default(merged[:max_prefix_bytes], @default_max_prefix_bytes),
      max_age_ms: non_negative_integer_or_default(merged[:max_age_ms], @default_max_age_ms),
      max_recent_requests:
        positive_integer_or_default(merged[:max_recent_requests], @default_max_recent_requests),
      hmac_secret: non_empty_binary_or_nil(merged[:hmac_secret])
    ]
  end

  def normalize_config(_raw_config), do: @default_config

  @spec enabled?(config()) :: boolean()
  def enabled?(config) when is_list(config), do: Keyword.get(config, :enabled) == true
  def enabled?(_config), do: false

  @spec derive_key(CanonicalRequest.t(), config()) :: {:ok, String.t()} | :unavailable
  def derive_key(%CanonicalRequest{rendered_prompt: rendered_prompt}, config)
      when is_binary(rendered_prompt) and byte_size(rendered_prompt) > 0 do
    normalized_config = normalize_config(config)

    with {:ok, secret} <- hmac_secret(normalized_config) do
      max_prefix_bytes =
        Keyword.get(normalized_config, :max_prefix_bytes, @default_max_prefix_bytes)

      prefix = bounded_prefix(rendered_prompt, max_prefix_bytes)
      digest = :crypto.mac(:hmac, :sha256, secret, [@domain, <<0>>, prefix])

      {:ok, "hmac-sha256:" <> Base.encode16(digest, case: :lower)}
    end
  end

  def derive_key(%CanonicalRequest{}, _config), do: :unavailable

  @spec prepare(CanonicalRequest.t(), [map()], config()) :: {[map()], context()}
  def prepare(%CanonicalRequest{} = request, candidates, config) when is_list(candidates) do
    normalized = normalize_config(config)

    if enabled?(normalized) do
      prepare_enabled(request, candidates, normalized)
    else
      {candidates, %{enabled?: false}}
    end
  end

  @spec scheduler_metadata(context(), [map()], map()) :: map()
  def scheduler_metadata(
        %{enabled?: true, affinity_key: affinity_key} = context,
        candidates,
        selected
      ) do
    recent_node_ids = Map.get(context, :recent_node_ids, [])
    hint_available? = recent_node_ids != []
    selected_match? = Map.get(selected, :cache_affinity_match?, false)
    matching_candidates = Enum.count(candidates, &Map.get(&1, :cache_affinity_match?, false))

    %{
      cache_affinity_enabled: true,
      cache_affinity_key: affinity_key,
      cache_affinity_hint_available: hint_available?,
      cache_affinity_selected_match: selected_match?,
      cache_affinity_source: cache_affinity_source(hint_available?),
      cache_affinity_candidate_count: matching_candidates,
      selected_cache_tier: selected_cache_tier(hint_available?, selected_match?)
    }
  end

  def scheduler_metadata(_context, _candidates, _selected), do: %{}

  @spec annotate_candidates([map()], [Ecto.UUID.t()]) :: [map()]
  def annotate_candidates(candidates, recent_node_ids) when is_list(candidates) do
    affinity_nodes = MapSet.new(recent_node_ids)

    Enum.map(candidates, fn candidate ->
      Map.put(
        candidate,
        :cache_affinity_match?,
        MapSet.member?(affinity_nodes, candidate.node_id)
      )
    end)
  end

  defp prepare_enabled(request, candidates, config) do
    case derive_key(request, config) do
      {:ok, affinity_key} ->
        recent_node_ids = recent_node_ids(request, affinity_key, config)

        {annotate_candidates(candidates, recent_node_ids),
         %{enabled?: true, affinity_key: affinity_key, recent_node_ids: recent_node_ids}}

      :unavailable ->
        {candidates, %{enabled?: false}}
    end
  end

  defp recent_node_ids(%CanonicalRequest{} = request, affinity_key, config) do
    Requests.recent_cache_affinity_nodes(
      request.tenant_id,
      request.model_ref.model_id,
      request.model_ref.version,
      affinity_key,
      max_age_ms: Keyword.get(config, :max_age_ms, @default_max_age_ms),
      max_recent_requests: Keyword.get(config, :max_recent_requests, @default_max_recent_requests)
    )
  rescue
    _error -> []
  end

  defp hmac_secret(config) do
    # Prefer the explicit cache-affinity secret when configured; otherwise preserve
    # existing behavior by falling back to the endpoint secret_key_base.
    case Keyword.get(config, :hmac_secret) || endpoint_secret_key_base() do
      secret when is_binary(secret) and secret != "" -> {:ok, secret}
      _other -> :unavailable
    end
  end

  defp endpoint_secret_key_base do
    :orchard_controller
    |> Application.get_env(Orchard.API.Endpoint, [])
    |> Keyword.get(:secret_key_base)
  end

  defp bounded_prefix(prompt, max_prefix_bytes) do
    binary_part(prompt, 0, min(byte_size(prompt), max_prefix_bytes))
  end

  defp cache_affinity_source(true), do: "recent_completed_request"
  defp cache_affinity_source(false), do: nil

  defp selected_cache_tier(true, true), do: "warm_prefix"
  defp selected_cache_tier(true, false), do: "hint_not_selected"
  defp selected_cache_tier(false, _selected_match?), do: "no_hint"

  defp positive_integer_or_default(value, _default) when is_integer(value) and value > 0,
    do: value

  defp positive_integer_or_default(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _other -> default
    end
  end

  defp positive_integer_or_default(_value, default), do: default

  defp non_negative_integer_or_default(value, _default) when is_integer(value) and value >= 0,
    do: value

  defp non_negative_integer_or_default(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed >= 0 -> parsed
      _other -> default
    end
  end

  defp non_negative_integer_or_default(_value, default), do: default

  defp non_empty_binary_or_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp non_empty_binary_or_nil(_value), do: nil
end
