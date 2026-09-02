defmodule Orchard.Node.WorkerCapabilityEvidence do
  @moduledoc """
  Pure classifier and evaluator for the additive `WorkerCapabilities` envelope
  carried on `GetStatus`.

  Receipt classification (`classify/3`) applies, in order: `:absent`,
  `:malformed` (structural rules), `:duplicate_or_conflicting` (identity rules),
  `:incompatible` (protocol major mismatch), `:valid`.

  Evaluation (`evaluate/4`) applies, in order: `:absent`, `:stale`, the
  retained invalid verdict, then the query result. A profile matches a query
  when every scalar dimension is inside `known_vocabulary/0` and equals the
  query, `max_concurrency` covers the requested minimum, and every requested
  feature and cache capability is a member of the profile's sets. When no
  profile matches, the result is `:unknown` if at least one profile carries a
  value outside `known_vocabulary/0` on some scalar dimension and satisfies
  every other matching condition (each known scalar dimension equals the
  query, capacity covers the minimum, the requested sets are covered);
  otherwise it is `:unsupported`.

  Nothing here gates behavior. Results are diagnostic evidence only.
  """

  alias Orchard.Node.Worker.V1.{WorkerCapabilities, WorkerCapabilityProfile}

  @supported_protocol_major 1
  @token_pattern ~r/^[a-z0-9][a-z0-9_.-]{0,63}$/
  @max_version_bytes 128
  @max_profiles 64
  @max_set_entries 64

  @known_artifact_formats ["safetensors"]
  @known_accelerations ["metal"]
  @known_device_bindings ["apple_gpu_0"]
  @known_memory_semantics ["unified"]

  @scalar_dimensions [:artifact_format, :acceleration, :device_binding, :memory_semantics]
  @set_dimensions [:runtime_features, :cache_capabilities]

  @type receipt_classification ::
          :absent | :malformed | :duplicate_or_conflicting | :incompatible | :valid

  @type snapshot :: %{
          classification: receipt_classification(),
          envelope: WorkerCapabilities.t() | nil,
          received_at_ms: integer(),
          custody: term(),
          service_incarnation: String.t() | nil,
          detail: String.t() | nil
        }

  @type query :: %{
          required(:artifact_format) => String.t(),
          required(:acceleration) => String.t(),
          required(:device_binding) => String.t(),
          required(:memory_semantics) => String.t(),
          optional(:min_concurrency) => pos_integer(),
          optional(:runtime_features) => [String.t()],
          optional(:cache_capabilities) => [String.t()]
        }

  @type result ::
          :absent
          | :stale
          | :malformed
          | :duplicate_or_conflicting
          | :incompatible
          | :unknown
          | :unsupported
          | {:supported, profile_id :: String.t(), service_incarnation :: String.t()}

  @type canonical_tuple ::
          {String.t(), String.t(), String.t(), String.t(), non_neg_integer(), [String.t()],
           [String.t()]}

  @spec supported_protocol_major() :: pos_integer()
  def supported_protocol_major, do: @supported_protocol_major

  @spec known_vocabulary() :: %{
          artifact_format: [String.t()],
          acceleration: [String.t()],
          device_binding: [String.t()],
          memory_semantics: [String.t()]
        }
  def known_vocabulary do
    %{
      artifact_format: @known_artifact_formats,
      acceleration: @known_accelerations,
      device_binding: @known_device_bindings,
      memory_semantics: @known_memory_semantics
    }
  end

  @spec canonical_tuple(WorkerCapabilityProfile.t()) :: canonical_tuple()
  def canonical_tuple(%WorkerCapabilityProfile{} = profile) do
    {
      profile.artifact_format,
      profile.acceleration,
      profile.device_binding,
      profile.memory_semantics,
      profile.max_concurrency,
      profile.runtime_features |> Enum.uniq() |> Enum.sort(),
      profile.cache_capabilities |> Enum.uniq() |> Enum.sort()
    }
  end

  @spec classify(WorkerCapabilities.t() | nil, integer(), term()) :: snapshot()
  def classify(nil, received_at_ms, custody) when is_integer(received_at_ms) do
    snapshot(:absent, nil, received_at_ms, custody, nil, nil)
  end

  def classify(%WorkerCapabilities{} = envelope, received_at_ms, custody)
      when is_integer(received_at_ms) do
    case receipt_verdict(envelope) do
      :valid ->
        snapshot(:valid, envelope, received_at_ms, custody, envelope.service_incarnation, nil)

      {:malformed, detail} ->
        snapshot(:malformed, nil, received_at_ms, custody, nil, detail)

      {classification, detail} ->
        snapshot(classification, envelope, received_at_ms, custody, nil, detail)
    end
  end

  @spec evaluate(snapshot() | nil, query(), integer(), keyword()) :: result()
  def evaluate(nil, _query, _now_ms, _opts), do: :absent
  def evaluate(%{classification: :absent}, _query, _now_ms, _opts), do: :absent

  def evaluate(%{received_at_ms: received_at_ms} = snapshot, query, now_ms, opts)
      when is_integer(now_ms) and is_list(opts) do
    freshness_window_ms = Keyword.fetch!(opts, :freshness_window_ms)

    cond do
      now_ms - received_at_ms > freshness_window_ms -> :stale
      snapshot.classification != :valid -> snapshot.classification
      true -> evaluate_query(snapshot, query)
    end
  end

  defp snapshot(classification, envelope, received_at_ms, custody, incarnation, detail) do
    %{
      classification: classification,
      envelope: envelope,
      received_at_ms: received_at_ms,
      custody: custody,
      service_incarnation: incarnation,
      detail: detail
    }
  end

  defp receipt_verdict(%WorkerCapabilities{} = envelope) do
    with :ok <- structural_check(envelope),
         :ok <- identity_check(envelope.profiles),
         :ok <- compatibility_check(envelope.protocol_major) do
      :valid
    end
  end

  defp structural_check(%WorkerCapabilities{} = envelope) do
    with :ok <- check(envelope.protocol_major > 0, :malformed, "protocol_major"),
         :ok <- check(token?(envelope.provider_id), :malformed, "provider_id"),
         :ok <- check(version?(envelope.provider_version), :malformed, "provider_version"),
         :ok <-
           check(
             version?(envelope.implementation_version),
             :malformed,
             "implementation_version"
           ),
         :ok <-
           check(token?(envelope.service_incarnation), :malformed, "service_incarnation"),
         :ok <- check(length(envelope.profiles) <= @max_profiles, :malformed, "profiles") do
      first_failure(envelope.profiles, &profile_structural_check/2)
    end
  end

  defp profile_structural_check(%WorkerCapabilityProfile{} = profile, index) do
    path = "profiles[#{index}]"

    with :ok <- check(token?(profile.profile_id), :malformed, "#{path}.profile_id"),
         :ok <- scalar_tokens_check(profile, path),
         :ok <- check(profile.max_concurrency > 0, :malformed, "#{path}.max_concurrency") do
      first_failure(@set_dimensions, fn dimension, _index ->
        token_set_check(Map.fetch!(profile, dimension), "#{path}.#{dimension}")
      end)
    end
  end

  defp scalar_tokens_check(profile, path) do
    first_failure(@scalar_dimensions, fn dimension, _index ->
      check(token?(Map.fetch!(profile, dimension)), :malformed, "#{path}.#{dimension}")
    end)
  end

  defp token_set_check(entries, path) do
    with :ok <- check(length(entries) <= @max_set_entries, :malformed, path),
         :ok <- check(Enum.all?(entries, &token?/1), :malformed, path) do
      check(sorted_unique?(entries), :malformed, path)
    end
  end

  defp identity_check(profiles) do
    with :ok <-
           check(
             unique?(Enum.map(profiles, & &1.profile_id)),
             :duplicate_or_conflicting,
             "profiles.profile_id"
           ) do
      check(
        unique?(Enum.map(profiles, &canonical_tuple/1)),
        :duplicate_or_conflicting,
        "profiles.canonical_tuple"
      )
    end
  end

  defp compatibility_check(@supported_protocol_major), do: :ok
  defp compatibility_check(_major), do: {:incompatible, "protocol_major"}

  defp check(true, _classification, _detail), do: :ok
  defp check(false, classification, detail), do: {classification, detail}

  defp first_failure(items, fun) do
    items
    |> Enum.with_index()
    |> Enum.find_value(:ok, fn {item, index} ->
      case fun.(item, index) do
        :ok -> nil
        failure -> failure
      end
    end)
  end

  defp token?(value) when is_binary(value), do: Regex.match?(@token_pattern, value)
  defp token?(_value), do: false

  defp version?(value) when is_binary(value) do
    value != "" and byte_size(value) <= @max_version_bytes and printable_ascii?(value)
  end

  defp version?(_value), do: false

  defp printable_ascii?(value) do
    value |> :binary.bin_to_list() |> Enum.all?(&(&1 >= 0x20 and &1 <= 0x7E))
  end

  defp sorted_unique?(entries), do: entries == entries |> Enum.uniq() |> Enum.sort()
  defp unique?(entries), do: length(entries) == length(Enum.uniq(entries))

  defp evaluate_query(%{envelope: envelope, service_incarnation: incarnation}, query) do
    profiles = envelope.profiles

    case Enum.find(profiles, &profile_matches?(&1, query)) do
      %WorkerCapabilityProfile{profile_id: profile_id} ->
        {:supported, profile_id, incarnation}

      nil ->
        if Enum.any?(profiles, &unknown_vocabulary_only_mismatch?(&1, query)) do
          :unknown
        else
          :unsupported
        end
    end
  end

  defp profile_matches?(%WorkerCapabilityProfile{} = profile, query) do
    case Enum.split_with(@scalar_dimensions, &unknown_value?(profile, &1)) do
      {[], known_dimensions} -> known_dimensions_match?(profile, query, known_dimensions)
      {_unknown_dimensions, _known_dimensions} -> false
    end
  end

  defp unknown_vocabulary_only_mismatch?(%WorkerCapabilityProfile{} = profile, query) do
    case Enum.split_with(@scalar_dimensions, &unknown_value?(profile, &1)) do
      {[], _known_dimensions} ->
        false

      {_unknown_dimensions, known_dimensions} ->
        known_dimensions_match?(profile, query, known_dimensions)
    end
  end

  defp known_dimensions_match?(profile, query, known_dimensions) do
    Enum.all?(known_dimensions, &scalar_matches?(profile, query, &1)) and
      capacity_matches?(profile, query) and
      Enum.all?(@set_dimensions, &set_matches?(profile, query, &1))
  end

  defp unknown_value?(profile, dimension) do
    Map.fetch!(profile, dimension) not in Map.fetch!(known_vocabulary(), dimension)
  end

  defp scalar_matches?(profile, query, dimension) do
    Map.fetch!(profile, dimension) == Map.fetch!(query, dimension)
  end

  defp capacity_matches?(profile, query) do
    profile.max_concurrency >= Map.get(query, :min_concurrency, 1)
  end

  defp set_matches?(profile, query, dimension) do
    requested = Map.get(query, dimension, [])
    Enum.all?(requested, &(&1 in Map.fetch!(profile, dimension)))
  end
end
