defmodule Orchard.ClusterManagement.NodeStatus do
  @moduledoc """
  Shared node and runtime-target status contract for cluster-management surfaces.
  """

  alias Orchard.ClusterManagement.{ReasonCodes, Value}

  @object "cluster_management.node_status"
  @contract_version "orchard.cluster_management.status.v1"

  @resource_types ~w(node admission_candidate runtime_target cluster)
  @freshness_values ~w(fresh stale unreachable unknown)
  @transport_values ~w(reachable timeout connect_failed identity_mismatch target_unconfigured unknown)
  @runtime_values ~w(ready not_ready unsupported unknown)
  @compatibility_values ~w(compatible legacy_metadata partial_metadata version_skew unsupported_version unknown)

  defstruct object: @object,
            contract_version: @contract_version,
            resource: %{type: nil, id: nil},
            lifecycle: %{state: nil},
            admission: %{category: nil, source: nil, latest_decision: nil},
            health: %{status: "unknown"},
            freshness: %{status: "unknown", observed_at: nil, source: nil},
            transport: %{status: "unknown"},
            runtime: %{status: "unknown", health_code: nil, health_message: nil},
            compatibility: %{status: "unknown"},
            scheduling: %{eligible: false, reason_codes: []},
            dispatch_capacity: nil,
            warnings: []

  @type t :: %__MODULE__{}

  @spec object() :: String.t()
  def object, do: @object

  @spec contract_version() :: String.t()
  def contract_version, do: @contract_version

  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(%{} = attrs) do
    with {:ok, resource} <- resource(attrs),
         {:ok, freshness} <-
           category(attrs, :freshness, @freshness_values, %{
             status: "unknown",
             observed_at: nil,
             source: nil
           }),
         {:ok, transport} <- category(attrs, :transport, @transport_values, %{status: "unknown"}),
         {:ok, runtime} <-
           category(attrs, :runtime, @runtime_values, %{
             status: "unknown",
             health_code: nil,
             health_message: nil
           }),
         {:ok, compatibility} <-
           category(attrs, :compatibility, @compatibility_values, %{status: "unknown"}),
         {:ok, scheduling} <- scheduling(attrs),
         {:ok, dispatch_capacity} <- dispatch_capacity(value(attrs, :dispatch_capacity)),
         {:ok, warnings} <- warnings(value(attrs, :warnings)) do
      {:ok,
       %__MODULE__{
         resource: resource,
         lifecycle: string_map(value(attrs, :lifecycle), %{state: nil}),
         admission:
           string_map(value(attrs, :admission), %{
             category: nil,
             source: nil,
             latest_decision: nil
           }),
         health: string_map(value(attrs, :health), %{status: "unknown"}),
         freshness: freshness,
         transport: transport,
         runtime: runtime,
         compatibility: compatibility,
         scheduling: scheduling,
         dispatch_capacity: dispatch_capacity,
         warnings: warnings
       }}
    end
  end

  @spec new!(map() | keyword()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, status} -> status
      {:error, reason} -> raise ArgumentError, "invalid node status: #{inspect(reason)}"
    end
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = status) do
    %{
      object: status.object,
      contract_version: status.contract_version,
      resource: json_map(status.resource),
      lifecycle: json_map(status.lifecycle),
      admission: json_map(status.admission),
      health: json_map(status.health),
      freshness: json_map(status.freshness),
      transport: json_map(status.transport),
      runtime: json_map(status.runtime),
      compatibility: json_map(status.compatibility),
      scheduling: json_map(status.scheduling),
      dispatch_capacity: json_map(status.dispatch_capacity),
      warnings: Enum.map(status.warnings, &json_map/1)
    }
  end

  defp resource(attrs) do
    resource = string_map(value(attrs, :resource), %{type: nil, id: nil})
    type = Map.get(resource, :type)

    if is_nil(type) or type in @resource_types do
      {:ok, resource}
    else
      {:error, {:unknown_resource_type, type}}
    end
  end

  defp category(attrs, key, values, defaults) do
    category = string_map(value(attrs, key), defaults)
    status = Map.get(category, :status)

    if is_nil(status) or status in values do
      {:ok, category}
    else
      {:error, {:unknown_status, key, status}}
    end
  end

  defp scheduling(attrs) do
    scheduling = value(attrs, :scheduling) || %{}
    reason_codes = map_value(scheduling, :reason_codes)

    with {:ok, codes} <- ReasonCodes.validate_codes(:scheduler_rejection, reason_codes) do
      {:ok,
       %{
         eligible: map_value(scheduling, :eligible) == true,
         reason_codes: codes
       }}
    end
  end

  defp dispatch_capacity(nil), do: {:ok, nil}

  defp dispatch_capacity(capacity) when is_map(capacity) do
    reason_codes = map_value(capacity, :reason_codes)

    with {:ok, reason_codes} <- dispatch_capacity_reason_codes(reason_codes) do
      normalized =
        capacity
        |> string_map(%{
          mode: "counterfactual",
          counterfactual: true,
          consumers_ready: false,
          runtime_concurrency_enforcement_limit: nil,
          controller_dispatch_ceiling: nil,
          effective_dispatch_limit: 0,
          controller_accounted_allocation: nil,
          dispatch_headroom: 0,
          placement_capacity: "not_applicable",
          placement_headroom: nil,
          authority_phase: "invalid",
          policy_state: "missing",
          management_class: "invalid",
          authority_decision: "fail_closed",
          available_slots: 0,
          legacy_pre_cutover_limit: nil,
          legacy_pre_cutover_reported_allocation: nil,
          legacy_pre_cutover_claim_count: nil,
          legacy_pre_cutover_available_slots: nil,
          eligible: false,
          observation_time: nil,
          reason_codes: []
        })
        |> Map.put(:reason_codes, reason_codes)

      {:ok, normalized}
    end
  end

  defp dispatch_capacity(_capacity), do: {:error, :dispatch_capacity_must_be_map}

  defp dispatch_capacity_reason_codes(nil), do: {:ok, []}

  defp dispatch_capacity_reason_codes(codes) when is_list(codes) do
    normalized = Enum.map(codes, &Value.normalize_string/1)

    case Enum.find(normalized, &(&1 not in ReasonCodes.dispatch_capacity_codes())) do
      nil -> {:ok, normalized}
      unknown -> {:error, {:unknown_dispatch_capacity_reason_code, unknown}}
    end
  end

  defp dispatch_capacity_reason_codes(_codes),
    do: {:error, :dispatch_capacity_reason_codes_must_be_list}

  defp warnings(nil), do: {:ok, []}

  defp warnings(warnings) when is_list(warnings) do
    warnings
    |> Enum.reduce_while({:ok, []}, fn warning, {:ok, acc} ->
      case warning(warning) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp warnings(_warnings), do: {:error, :warnings_must_be_list}

  defp warning(warning) when is_map(warning) do
    normalized = string_map(warning, %{code: nil, message: nil, metadata: %{}})

    case normalized.code do
      code when is_binary(code) and code != "" -> {:ok, normalized}
      _other -> {:error, :warning_code_required}
    end
  end

  defp warning(_warning), do: {:error, :warning_must_be_map}

  defp string_map(nil, defaults), do: defaults

  defp string_map(map, defaults) when is_map(map) do
    Enum.reduce(defaults, %{}, fn {key, default}, acc ->
      Map.put(acc, key, normalize_value(map_value(map, key), default))
    end)
  end

  defp string_map(_value, defaults), do: defaults

  defp json_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {key, Value.json_value(value)} end)
  end

  defp json_map(nil), do: nil

  defp normalize_value(nil, default), do: default
  defp normalize_value(%DateTime{} = value, _default), do: value
  defp normalize_value(value, _default) when is_boolean(value), do: value
  defp normalize_value(value, _default) when is_atom(value), do: Atom.to_string(value)
  defp normalize_value(value, _default), do: value

  defp value(attrs, key), do: map_value(attrs, key)

  defp map_value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, nil} -> Map.get(map, Atom.to_string(key))
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp map_value(_map, _key), do: nil
end
