defmodule Orchard.RuntimeEndpoint.PlacementCapacity do
  @moduledoc """
  Scheduler-visible capacity for one Runtime Endpoint model placement.
  """

  alias Orchard.RuntimeEndpoint.ModelRef

  defstruct model_ref: nil,
            active_request_count: nil,
            max_concurrency: nil,
            status: :unknown,
            source: :unknown,
            diagnostics: %{}

  @type status :: :known | :unknown | :invalid
  @type t :: %__MODULE__{
          model_ref: ModelRef.t() | nil,
          active_request_count: non_neg_integer() | term(),
          max_concurrency: pos_integer() | term(),
          status: status(),
          source: atom() | String.t(),
          diagnostics: map()
        }

  @spec new(map() | keyword()) :: t()
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(%{} = attrs) do
    model_ref = normalize_model_ref(value(attrs, :model_ref))
    active_request_count = value(attrs, :active_request_count)
    max_concurrency = value(attrs, :max_concurrency)

    %__MODULE__{
      model_ref: model_ref,
      active_request_count: active_request_count,
      max_concurrency: max_concurrency,
      status: capacity_status(model_ref, active_request_count, max_concurrency),
      source: value(attrs, :source) || :unknown,
      diagnostics: diagnostics(attrs)
    }
  end

  @spec unknown(ModelRef.t() | map(), atom() | String.t()) :: t()
  def unknown(model_ref, source \\ :unknown) do
    new(%{model_ref: model_ref, source: source})
  end

  @spec full?(t()) :: boolean()
  def full?(%__MODULE__{status: :known, active_request_count: active, max_concurrency: max}),
    do: active >= max

  def full?(%__MODULE__{}), do: false

  @spec spare?(t()) :: boolean()
  def spare?(%__MODULE__{status: :known, active_request_count: active, max_concurrency: max}),
    do: active < max

  def spare?(%__MODULE__{}), do: false

  @spec known?(t()) :: boolean()
  def known?(%__MODULE__{status: :known}), do: true
  def known?(%__MODULE__{}), do: false

  defp normalize_model_ref(%ModelRef{} = model_ref), do: model_ref

  defp normalize_model_ref(model_ref) do
    case ModelRef.new(model_ref) do
      {:ok, normalized} -> normalized
      {:error, :invalid_model_ref} -> nil
    end
  end

  defp capacity_status(nil, _active_request_count, _max_concurrency), do: :invalid

  defp capacity_status(_model_ref, nil, nil), do: :unknown

  defp capacity_status(_model_ref, active_request_count, max_concurrency)
       when is_integer(active_request_count) and active_request_count >= 0 and
              is_integer(max_concurrency) and
              max_concurrency > 0,
       do: :known

  defp capacity_status(_model_ref, _active_request_count, _max_concurrency), do: :invalid

  defp diagnostics(attrs) do
    case value(attrs, :diagnostics) do
      %{} = diagnostics -> diagnostics
      nil -> %{}
      other -> %{raw_diagnostics: other}
    end
  end

  defp value(%{} = attrs, key) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(attrs, key) -> Map.fetch!(attrs, key)
      Map.has_key?(attrs, string_key) -> Map.fetch!(attrs, string_key)
      true -> nil
    end
  end
end
