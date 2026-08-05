defmodule Orchard.NodeHeartbeats.Payload do
  @moduledoc """
  Builds the closed, bounded schema-v1 scheduler-candidate heartbeat payload.
  """

  alias Orchard.Runtime.{MemoryBudget, PrefixCacheStatus}
  alias Orchard.RuntimeEndpoint.{ModelRef, Observation, Placement, PlacementCapacity, Target}

  @schema_version 1
  @default_max_bytes 262_144
  @minimum_max_bytes 128
  @entry_limit 40
  @string_limit_bytes 512
  @model_ref_limit 160
  @status_limit 80
  @uint32_max 4_294_967_295

  @availability_values ~w(available unavailable degraded unknown)
  @worker_state_values ~w(starting idle busy stopping failed stopped unknown)
  @placement_state_values ~w(unknown unavailable cached loaded provider_available failed loading)

  @type invalid_reason ::
          :duplicate_placement_model_ref
          | :malformed_required_envelope
          | :payload_too_large
          | :placement_entry_overflow
          | :unsupported_schema_version
  @type t :: map()

  @doc "Returns the validated encoded payload ceiling."
  @spec max_bytes!() :: pos_integer()
  def max_bytes! do
    case Application.get_env(
           :orchard_controller,
           :node_heartbeat_payload_max_bytes,
           @default_max_bytes
         ) do
      value when is_integer(value) and value >= @minimum_max_bytes ->
        value

      value ->
        raise ArgumentError,
              "node_heartbeat_payload_max_bytes must be an integer >= #{@minimum_max_bytes}, got: #{inspect(value)}"
    end
  end

  @doc """
  Builds one schema-v1 payload or a stable minimal invalid envelope.

  The optional schema_version input exists for explicit envelope validation;
  Controller-produced observations use version 1.
  """
  @spec build(Target.t(), map() | struct(), keyword()) :: t()
  def build(target, observation, opts \\ [])

  def build(%Target{} = target, observation, opts) when is_map(observation) do
    case Keyword.get(opts, :schema_version, @schema_version) do
      @schema_version ->
        target
        |> valid_payload(observation, Keyword.get(opts, :node_id))
        |> enforce_size()

      _unsupported ->
        invalid(:unsupported_schema_version)
    end
  end

  def build(_target, _observation, _opts), do: invalid(:malformed_required_envelope)

  @doc "Returns the stable minimal schema-v1 invalid envelope."
  @spec invalid(invalid_reason()) :: t()
  def invalid(reason)
      when reason in [
             :duplicate_placement_model_ref,
             :malformed_required_envelope,
             :payload_too_large,
             :placement_entry_overflow,
             :unsupported_schema_version
           ] do
    %{
      "schema_version" => @schema_version,
      "validity" => "invalid",
      "invalid_reason" => Atom.to_string(reason)
    }
  end

  defp valid_payload(target, observation, _node_id) do
    with {:ok, target_payload} <- normalize_target(target),
         {:ok, endpoint_id} <- required_string(value(observation, :endpoint_id) || target.id),
         {:ok, placements} <- normalize_placements(value(observation, :placements)) do
      %{
        "schema_version" => @schema_version,
        "validity" => "valid",
        "endpoint_id" => endpoint_id,
        "target" => target_payload,
        "availability" => normalize_availability(observation),
        "worker_state" => normalize_worker_state(value(observation, :worker_state)),
        "aggregate_active_request_count" => aggregate_active_count(observation),
        "aggregate_max_concurrency" => aggregate_max_concurrency(observation),
        "aggregate_capacity_evidence" => aggregate_capacity_evidence(observation),
        "placements" => placements,
        "runtime_memory_budgets" =>
          normalize_entries(
            value(observation, :runtime_memory_budgets),
            &MemoryBudget.normalize/1
          ),
        "runtime_prefix_cache_statuses" =>
          normalize_entries(
            value(observation, :runtime_prefix_cache_statuses),
            &PrefixCacheStatus.normalize/1
          ),
        "supports_prompt_token_ids" => value(observation, :supports_prompt_token_ids) == true
      }
    else
      {:error, reason}
      when reason in [:duplicate_placement_model_ref, :placement_entry_overflow] ->
        invalid(reason)

      _error ->
        invalid(:malformed_required_envelope)
    end
  end

  defp enforce_size(payload) do
    if payload |> Jason.encode!() |> byte_size() <= max_bytes!() do
      payload
    else
      invalid(:payload_too_large)
    end
  end

  defp normalize_target(%Target{} = target) do
    with {:ok, id} <- required_string(target.id),
         {:ok, transport} <- normalize_transport(target.transport),
         {:ok, address} <- normalize_address(target.transport, target.address),
         {:ok, node_id} <- normalize_node_id(target.node_id) do
      {:ok,
       %{
         "id" => id,
         "transport" => transport,
         "address" => address,
         "node_id" => node_id
       }}
    end
  end

  defp normalize_transport(:beam), do: {:ok, "beam"}
  defp normalize_transport(:grpc_compat), do: {:ok, "grpc_compat"}
  defp normalize_transport(_transport), do: :error

  defp normalize_address(:beam, address) when is_atom(address) do
    normalize_beam_address(Atom.to_string(address))
  end

  defp normalize_address(:beam, address), do: normalize_beam_address(address)

  defp normalize_address(:grpc_compat, address) when is_list(address) or is_map(address) do
    address = Map.new(address)
    host = value(address, :host)
    port = value(address, :port)

    with {:ok, host} <- required_string(host),
         true <- is_integer(port) and port in 1..65_535 do
      {:ok, %{"host" => host, "port" => port}}
    else
      _error -> :error
    end
  end

  defp normalize_address(_transport, _address), do: :error

  defp normalize_beam_address(address) when is_binary(address) and byte_size(address) <= 255,
    do: required_string(address)

  defp normalize_beam_address(_address), do: :error

  defp normalize_node_id(node_id) when is_binary(node_id), do: Ecto.UUID.cast(node_id)

  defp normalize_node_id(_node_id), do: :error

  defp normalize_availability(observation) do
    case enum_string(value(observation, :availability), @availability_values) do
      "unknown" -> availability_from_health(observation)
      availability -> availability
    end
  end

  defp availability_from_health(observation) do
    health = value(observation, :runtime_health) || value(observation, :health)

    cond do
      not is_map(health) ->
        "unknown"

      value(health, :ready) == false ->
        "unavailable"

      present_string?(value(health, :health_code)) or
          present_string?(value(health, :health_message)) ->
        "degraded"

      value(health, :ready) == true ->
        "available"

      true ->
        "unknown"
    end
  end

  defp normalize_worker_state(value) do
    value
    |> worker_state()
    |> enum_string(@worker_state_values)
  end

  defp worker_state(:WORKER_STATE_STARTING), do: :starting
  defp worker_state(:WORKER_STATE_IDLE), do: :idle
  defp worker_state(:WORKER_STATE_BUSY), do: :busy
  defp worker_state(:WORKER_STATE_STOPPING), do: :stopping
  defp worker_state(:WORKER_STATE_FAILED), do: :failed
  defp worker_state(:WORKER_STATE_STOPPED), do: :stopped
  defp worker_state(1), do: :starting
  defp worker_state(2), do: :idle
  defp worker_state(3), do: :busy
  defp worker_state(4), do: :stopping
  defp worker_state(5), do: :failed
  defp worker_state(6), do: :stopped
  defp worker_state(value), do: value

  defp aggregate_active_count(observation) do
    observation
    |> first_value([:aggregate_active_request_count, :active_request_count])
    |> normalize_uint32()
  end

  defp aggregate_max_concurrency(observation) do
    observation
    |> first_value([:aggregate_max_concurrency, :max_concurrency])
    |> normalize_positive_uint32()
  end

  defp aggregate_capacity_evidence(%Observation{aggregate_capacity_evidence: evidence})
       when is_map(evidence) do
    normalize_capacity_evidence(evidence)
  end

  defp aggregate_capacity_evidence(observation) do
    case value(observation, :aggregate_capacity_evidence) do
      evidence when is_map(evidence) ->
        normalize_capacity_evidence(evidence)

      _missing ->
        active = aggregate_active_count(observation)
        limit = aggregate_max_concurrency(observation)

        %{
          "runtime_concurrency_limit" => limit,
          "active_request_count" => active,
          "validity" => capacity_validity(active, limit)
        }
    end
  end

  defp normalize_capacity_evidence(evidence) do
    active = evidence |> value(:active_request_count) |> normalize_uint32()
    limit = evidence |> value(:runtime_concurrency_limit) |> normalize_positive_uint32()
    reported_validity = enum_string(value(evidence, :validity), ~w(valid missing invalid))

    validity =
      case reported_validity do
        "valid" when not is_nil(active) and not is_nil(limit) -> "valid"
        "missing" when is_nil(active) or is_nil(limit) -> "missing"
        _other -> "invalid"
      end

    %{
      "runtime_concurrency_limit" => limit,
      "active_request_count" => active,
      "validity" => validity
    }
  end

  defp capacity_validity(nil, _limit), do: "missing"
  defp capacity_validity(_active, nil), do: "missing"
  defp capacity_validity(_active, _limit), do: "valid"

  defp normalize_placements(placements) when is_list(placements) do
    with :ok <- ensure_unique_placement_model_refs(placements),
         :ok <- ensure_placement_limit(placements) do
      {:ok, Enum.flat_map(placements, &normalize_placement/1)}
    end
  end

  defp normalize_placements(nil), do: {:ok, []}
  defp normalize_placements(_malformed), do: {:ok, []}

  defp ensure_unique_placement_model_refs(placements) do
    keys =
      Enum.flat_map(placements, fn placement ->
        case placement_model_ref_key(placement) do
          {:ok, key} -> [key]
          :error -> []
        end
      end)

    if length(keys) == MapSet.size(MapSet.new(keys)) do
      :ok
    else
      {:error, :duplicate_placement_model_ref}
    end
  end

  defp placement_model_ref_key(%Placement{} = placement),
    do: placement |> Map.from_struct() |> placement_model_ref_key()

  defp placement_model_ref_key(placement) when is_map(placement) do
    case normalize_model_ref(value(placement, :model_ref)) do
      {:ok, %{"model_id" => model_id, "version" => version}} -> {:ok, {model_id, version}}
      :error -> :error
    end
  end

  defp placement_model_ref_key(_placement), do: :error

  defp ensure_placement_limit(placements) do
    if length(placements) <= @entry_limit do
      :ok
    else
      {:error, :placement_entry_overflow}
    end
  end

  defp normalize_placement(%Placement{} = placement),
    do: placement |> Map.from_struct() |> normalize_placement()

  defp normalize_placement(placement) when is_map(placement) do
    case normalize_model_ref(value(placement, :model_ref)) do
      {:ok, model_ref} ->
        [
          %{
            "model_ref" => model_ref,
            "state" => normalize_placement_state(value(placement, :state)),
            "capacity" => normalize_placement_capacity(value(placement, :capacity)),
            "last_used_at" => normalize_last_used_at(value(placement, :last_used_at))
          }
        ]

      :error ->
        []
    end
  end

  defp normalize_placement(_placement), do: []

  defp normalize_model_ref(%ModelRef{} = model_ref),
    do: model_ref |> Map.from_struct() |> normalize_model_ref()

  defp normalize_model_ref(model_ref) when is_map(model_ref) do
    model_id = value(model_ref, :model_id)
    version = value(model_ref, :version)

    if present_string?(model_id) and present_string?(version) do
      bounded_version = String.slice(version, 0, div(@model_ref_limit, 2))
      model_id_limit = max(@model_ref_limit - String.length(bounded_version) - 1, 1)

      {:ok,
       %{
         "model_id" => String.slice(model_id, 0, model_id_limit),
         "version" => bounded_version
       }}
    else
      :error
    end
  end

  defp normalize_model_ref(_model_ref), do: :error

  defp normalize_placement_state(state) do
    state
    |> placement_state()
    |> enum_string(@placement_state_values)
  end

  defp placement_state(:PLACEMENT_STATE_UNAVAILABLE), do: :unavailable
  defp placement_state(:PLACEMENT_STATE_CACHED), do: :cached
  defp placement_state(:PLACEMENT_STATE_LOADED), do: :loaded
  defp placement_state(:PLACEMENT_STATE_PROVIDER_AVAILABLE), do: :provider_available
  defp placement_state(:PLACEMENT_STATE_FAILED), do: :failed
  defp placement_state(:PLACEMENT_STATE_LOADING), do: :loading
  defp placement_state(state), do: state

  defp normalize_placement_capacity(%PlacementCapacity{} = capacity),
    do: capacity |> Map.from_struct() |> normalize_placement_capacity()

  defp normalize_placement_capacity(capacity) when is_map(capacity) do
    active = capacity |> value(:active_request_count) |> normalize_uint32()
    limit = capacity |> value(:max_concurrency) |> normalize_positive_uint32()

    %{
      "active_request_count" => active,
      "max_concurrency" => limit,
      "status" => placement_capacity_status(active, limit),
      "source" => bounded_status(value(capacity, :source), "unknown")
    }
  end

  defp normalize_placement_capacity(_capacity) do
    %{
      "active_request_count" => nil,
      "max_concurrency" => nil,
      "status" => "unknown",
      "source" => "unknown"
    }
  end

  defp placement_capacity_status(nil, nil), do: "unknown"

  defp placement_capacity_status(active, limit) when is_integer(active) and is_integer(limit),
    do: "known"

  defp placement_capacity_status(_active, _limit), do: "invalid"

  defp normalize_last_used_at(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp normalize_last_used_at(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp normalize_last_used_at(value) when is_binary(value), do: bounded_binary(value)
  defp normalize_last_used_at(_value), do: nil

  defp normalize_entries(entries, normalizer) when is_list(entries) do
    entries
    |> Enum.take(@entry_limit)
    |> Enum.map(normalizer)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&stringify_keys/1)
  end

  defp normalize_entries(nil, _normalizer), do: []

  defp normalize_entries(malformed, normalizer) do
    normalized = normalizer.(malformed)
    if is_nil(normalized), do: [], else: [stringify_keys(normalized)]
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value) when is_boolean(value) or is_nil(value), do: value
  defp stringify_keys(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_keys(value), do: value

  defp enum_string(value, allowed) when is_atom(value),
    do: enum_string(Atom.to_string(value), allowed)

  defp enum_string(value, allowed) when is_binary(value) do
    normalized = String.downcase(value)
    if normalized in allowed, do: normalized, else: "unknown"
  end

  defp enum_string(_value, _allowed), do: "unknown"

  defp bounded_status(value, default) when is_atom(value),
    do: bounded_status(Atom.to_string(value), default)

  defp bounded_status(value, _default) when is_binary(value) and value != "",
    do: String.slice(value, 0, @status_limit)

  defp bounded_status(_value, default), do: default

  defp normalize_uint32(value) when is_integer(value) and value in 0..@uint32_max, do: value
  defp normalize_uint32(_value), do: nil

  defp normalize_positive_uint32(value)
       when is_integer(value) and value in 1..@uint32_max,
       do: value

  defp normalize_positive_uint32(_value), do: nil

  defp first_value(map, keys), do: Enum.find_value(keys, &value(map, &1))

  defp required_string(value) when is_binary(value) and value != "" do
    case bounded_binary(value) do
      nil -> :error
      bounded -> {:ok, bounded}
    end
  end

  defp required_string(_value), do: :error

  defp bounded_binary(value) when is_binary(value) do
    cond do
      not String.valid?(value) -> nil
      byte_size(value) <= @string_limit_bytes -> value
      true -> value |> binary_part(0, @string_limit_bytes) |> trim_invalid_suffix()
    end
  end

  defp trim_invalid_suffix(value) do
    if String.valid?(value) do
      value
    else
      value
      |> binary_part(0, byte_size(value) - 1)
      |> trim_invalid_suffix()
    end
  end

  defp present_string?(value), do: is_binary(value) and value != "" and String.valid?(value)

  defp value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
