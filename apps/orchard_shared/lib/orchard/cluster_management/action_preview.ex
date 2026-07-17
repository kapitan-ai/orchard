defmodule Orchard.ClusterManagement.ActionPreview do
  @moduledoc """
  Side-effect-free action preview contract for cluster-management actions.
  """

  alias Orchard.ClusterManagement.{ReasonCodes, Value}

  @object "cluster_management.action_preview"
  @contract_version "orchard.cluster_management.action_preview.v1"

  defstruct object: @object,
            contract_version: @contract_version,
            action: nil,
            target: %{type: nil, id: nil},
            current: %{},
            dispatch_capacity_policy: %{},
            active_request_count: nil,
            scheduler_eligibility: %{eligible: false, reason_codes: []},
            blockers: [],
            warnings: [],
            consequence_codes: [],
            confirmation_requirements: [],
            expected_transition: %{from: nil, to: nil},
            audit_action: nil,
            confirmation_required: false

  @type t :: %__MODULE__{}

  @spec object() :: String.t()
  def object, do: @object

  @spec contract_version() :: String.t()
  def contract_version, do: @contract_version

  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(%{} = attrs) do
    with {:ok, blockers} <- coded_entries(value(attrs, :blockers), :action_blocker, true),
         {:ok, warnings} <- coded_entries(value(attrs, :warnings), nil, false),
         {:ok, consequence_codes} <-
           ReasonCodes.validate_codes(:consequence, value(attrs, :consequence_codes)),
         {:ok, confirmation_requirements} <-
           ReasonCodes.validate_codes(
             :confirmation_requirement,
             value(attrs, :confirmation_requirements)
           ),
         {:ok, scheduler_eligibility} <- scheduler_eligibility(attrs) do
      {:ok,
       %__MODULE__{
         action: Value.normalize_string(value(attrs, :action)),
         target: string_map(value(attrs, :target), %{type: nil, id: nil}),
         current: map_value_or_empty(value(attrs, :current)),
         dispatch_capacity_policy: map_value_or_empty(value(attrs, :dispatch_capacity_policy)),
         active_request_count: active_request_count(value(attrs, :active_request_count)),
         scheduler_eligibility: scheduler_eligibility,
         blockers: blockers,
         warnings: warnings,
         consequence_codes: consequence_codes,
         confirmation_requirements: confirmation_requirements,
         expected_transition:
           string_map(value(attrs, :expected_transition), %{from: nil, to: nil}),
         audit_action: Value.normalize_string(value(attrs, :audit_action)),
         confirmation_required: value(attrs, :confirmation_required) == true
       }}
    end
  end

  @spec new!(map() | keyword()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, preview} -> preview
      {:error, reason} -> raise ArgumentError, "invalid action preview: #{inspect(reason)}"
    end
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = preview) do
    %{
      object: preview.object,
      contract_version: preview.contract_version,
      action: preview.action,
      target: Value.json_value(preview.target),
      current: Value.json_value(preview.current),
      dispatch_capacity_policy: Value.json_value(preview.dispatch_capacity_policy),
      active_request_count: preview.active_request_count,
      scheduler_eligibility: Value.json_value(preview.scheduler_eligibility),
      blockers: Enum.map(preview.blockers, &Value.json_value/1),
      warnings: Enum.map(preview.warnings, &Value.json_value/1),
      consequence_codes: preview.consequence_codes,
      confirmation_requirements: preview.confirmation_requirements,
      expected_transition: Value.json_value(preview.expected_transition),
      audit_action: preview.audit_action,
      confirmation_required: preview.confirmation_required
    }
  end

  defp scheduler_eligibility(attrs) do
    scheduling = value(attrs, :scheduler_eligibility) || %{}

    with {:ok, codes} <-
           ReasonCodes.validate_codes(:scheduler_rejection, map_value(scheduling, :reason_codes)) do
      {:ok, %{eligible: map_value(scheduling, :eligible) == true, reason_codes: codes}}
    end
  end

  defp coded_entries(nil, _vocabulary, _fixed), do: {:ok, []}

  defp coded_entries(entries, vocabulary, fixed) when is_list(entries) do
    entries
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case coded_entry(entry, vocabulary, fixed) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp coded_entries(_entries, _vocabulary, _fixed), do: {:error, :entries_must_be_list}

  defp coded_entry(entry, vocabulary, fixed) when is_map(entry) do
    code = ReasonCodes.normalize_code(map_value(entry, :code))

    cond do
      is_nil(code) ->
        {:error, :entry_code_required}

      fixed and not ReasonCodes.valid?(vocabulary, code) ->
        {:error, {:unknown_code, vocabulary, code}}

      true ->
        {:ok,
         %{
           code: code,
           message: Value.normalize_string(map_value(entry, :message)),
           metadata: map_value_or_empty(map_value(entry, :metadata))
         }}
    end
  end

  defp coded_entry(_entry, _vocabulary, _fixed), do: {:error, :entry_must_be_map}

  defp string_map(nil, defaults), do: defaults

  defp string_map(map, defaults) when is_map(map) do
    Enum.reduce(defaults, %{}, fn {key, default}, acc ->
      Map.put(acc, key, Value.normalize_string(map_value(map, key)) || default)
    end)
  end

  defp string_map(_value, defaults), do: defaults

  defp map_value_or_empty(value) when is_map(value), do: value
  defp map_value_or_empty(_value), do: %{}

  defp active_request_count(count) when is_integer(count) and count >= 0, do: count
  defp active_request_count(_count), do: nil

  defp value(attrs, key), do: map_value(attrs, key)

  defp map_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp map_value(_map, _key), do: nil
end
