defmodule Orchard.RuntimeEndpoint.Placement do
  @moduledoc """
  Runtime Endpoint model placement state and capacity.
  """

  alias Orchard.RuntimeEndpoint.{ModelRef, PlacementCapacity}

  @enforce_keys [:model_ref, :state]
  defstruct model_ref: nil,
            state: :unknown,
            capacity: nil,
            last_used_at: nil,
            diagnostics: %{}

  @type state ::
          :unknown
          | :unavailable
          | :cached
          | :loaded
          | :provider_available
          | :failed
          | :loading
          | atom()
  @type t :: %__MODULE__{
          model_ref: ModelRef.t(),
          state: state(),
          capacity: PlacementCapacity.t(),
          last_used_at: term(),
          diagnostics: map()
        }

  @spec new(map() | keyword()) :: t()
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(%{} = attrs) do
    model_ref = ModelRef.new!(value(attrs, :model_ref))
    capacity = normalize_capacity(value(attrs, :capacity), model_ref)

    %__MODULE__{
      model_ref: model_ref,
      state: value(attrs, :state) || :unknown,
      capacity: capacity,
      last_used_at: value(attrs, :last_used_at),
      diagnostics: diagnostics(attrs)
    }
  end

  @spec loaded?(t()) :: boolean()
  def loaded?(%__MODULE__{state: state})
      when state in [:loaded, "loaded", :PLACEMENT_STATE_LOADED],
      do: true

  def loaded?(%__MODULE__{}), do: false

  defp normalize_capacity(%PlacementCapacity{} = capacity, _model_ref), do: capacity
  defp normalize_capacity(nil, model_ref), do: PlacementCapacity.unknown(model_ref, :not_observed)

  defp normalize_capacity(%{} = attrs, model_ref) do
    attrs
    |> Map.put_new(:model_ref, model_ref)
    |> PlacementCapacity.new()
  end

  defp normalize_capacity(_capacity, model_ref),
    do: PlacementCapacity.unknown(model_ref, :invalid_capacity)

  defp diagnostics(attrs) do
    case value(attrs, :diagnostics) do
      %{} = diagnostics -> diagnostics
      nil -> %{}
      other -> %{raw_diagnostics: other}
    end
  end

  defp value(%{} = attrs, key), do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
end
