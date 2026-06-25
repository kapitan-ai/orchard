defmodule Orchard.RuntimeEndpoint.ModelRef do
  @moduledoc """
  Transport-independent model identity used by Runtime Endpoint contracts.
  """

  @enforce_keys [:model_id, :version]
  defstruct model_id: nil, version: nil

  @type t :: %__MODULE__{model_id: String.t(), version: String.t()}

  @spec new(String.t(), String.t()) :: {:ok, t()} | {:error, :invalid_model_ref}
  def new(model_id, version)
      when is_binary(model_id) and model_id != "" and is_binary(version) and version != "" do
    {:ok, %__MODULE__{model_id: model_id, version: version}}
  end

  def new(_model_id, _version), do: {:error, :invalid_model_ref}

  @spec new(t() | map()) :: {:ok, t()} | {:error, :invalid_model_ref}
  def new(%__MODULE__{} = model_ref), do: new(model_ref.model_id, model_ref.version)

  def new(%{} = attrs) do
    new(value(attrs, :model_id), value(attrs, :version))
  end

  def new(_attrs), do: {:error, :invalid_model_ref}

  @spec new!(String.t(), String.t()) :: t()
  def new!(model_id, version) do
    case new(model_id, version) do
      {:ok, model_ref} ->
        model_ref

      {:error, :invalid_model_ref} ->
        raise ArgumentError, "model_ref requires non-empty model_id and version"
    end
  end

  @spec new!(t() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, model_ref} ->
        model_ref

      {:error, :invalid_model_ref} ->
        raise ArgumentError, "model_ref requires non-empty model_id and version"
    end
  end

  @spec equal?(t() | map() | nil, t() | map() | nil) :: boolean()
  def equal?(left, right) do
    with {:ok, left_ref} <- new(left),
         {:ok, right_ref} <- new(right) do
      left_ref.model_id == right_ref.model_id and left_ref.version == right_ref.version
    else
      _ -> false
    end
  end

  defp value(%{} = attrs, key), do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
end
