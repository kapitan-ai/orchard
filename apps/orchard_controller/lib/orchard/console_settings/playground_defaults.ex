defmodule Orchard.ConsoleSettings.PlaygroundDefaults do
  @moduledoc """
  Casting and normalization for persisted Playground defaults.
  """

  import Ecto.Changeset

  alias Orchard.Inference.SamplingValidation

  @fields [:default_model, :temperature, :top_p, :max_completion_tokens]
  @sampling_fields [:temperature, :top_p, :max_completion_tokens]
  @default_model_max_length 256
  @types %{
    default_model: :string,
    temperature: :float,
    top_p: :float,
    max_completion_tokens: :integer
  }
  @defaults %{
    default_model: nil,
    temperature: nil,
    top_p: nil,
    max_completion_tokens: nil
  }

  @type t :: %{
          default_model: String.t() | nil,
          temperature: number() | nil,
          top_p: number() | nil,
          max_completion_tokens: pos_integer() | nil
        }

  @spec defaults() :: t()
  def defaults, do: @defaults

  @spec cast_params(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def cast_params(attrs) when is_map(attrs) do
    changeset =
      {@defaults, @types}
      |> Ecto.Changeset.cast(attrs, @fields, empty_values: [""])
      |> normalize_default_model_change()
      |> validate_length(:default_model, max: @default_model_max_length)
      |> validate_sampling_fields()

    if changeset.valid? do
      {:ok, changeset |> apply_changes() |> normalize()}
    else
      {:error, changeset}
    end
  end

  @spec normalize(term()) :: t()
  def normalize(value) when is_map(value) do
    Enum.reduce(@fields, @defaults, fn field, acc ->
      value
      |> fetch_known_value(field)
      |> put_valid_value(acc, field)
    end)
  end

  def normalize(_value), do: @defaults

  @spec to_value(t()) :: map()
  def to_value(defaults) when is_map(defaults) do
    defaults
    |> normalize()
    |> Enum.reject(fn {_field, value} -> is_nil(value) end)
    |> Map.new(fn {field, value} -> {Atom.to_string(field), value} end)
  end

  defp normalize_default_model_change(changeset) do
    update_change(changeset, :default_model, &String.trim/1)
  end

  defp validate_sampling_fields(changeset) do
    Enum.reduce(@sampling_fields, changeset, fn field, acc ->
      validate_sampling_field(acc, field)
    end)
  end

  defp validate_sampling_field(changeset, field) do
    case get_field(changeset, field) do
      nil ->
        changeset

      value ->
        case validate_value(field, value) do
          :ok -> changeset
          {:error, message} -> add_error(changeset, field, message)
        end
    end
  end

  defp fetch_known_value(map, field) do
    string_field = Atom.to_string(field)

    cond do
      Map.has_key?(map, string_field) -> Map.fetch!(map, string_field)
      Map.has_key?(map, field) -> Map.fetch!(map, field)
      true -> nil
    end
  end

  defp put_valid_value(value, acc, :default_model) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" -> acc
      String.length(value) > @default_model_max_length -> acc
      true -> Map.put(acc, :default_model, value)
    end
  end

  defp put_valid_value(value, acc, field) when field in @sampling_fields do
    case validate_value(field, value) do
      :ok -> Map.put(acc, field, value)
      {:error, _message} -> acc
    end
  end

  defp put_valid_value(_value, acc, _field), do: acc

  defp validate_value(:temperature, value) do
    value
    |> then(&SamplingValidation.validate_temperature(%{"temperature" => &1}))
    |> validation_result()
  end

  defp validate_value(:top_p, value) do
    value
    |> then(&SamplingValidation.validate_top_p(%{"top_p" => &1}))
    |> validation_result()
  end

  defp validate_value(:max_completion_tokens, value) do
    value
    |> then(&SamplingValidation.validate_positive_integer(&1, "max_completion_tokens"))
    |> validation_result()
  end

  defp validation_result(:ok), do: :ok

  defp validation_result({:error, :invalid_value, _field, message}), do: {:error, message}
end
