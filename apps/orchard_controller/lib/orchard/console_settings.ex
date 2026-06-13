defmodule Orchard.ConsoleSettings do
  @moduledoc """
  Context for Console-wide persisted settings.
  """

  alias Orchard.ConsoleSettings.Entry
  alias Orchard.ConsoleSettings.PlaygroundDefaults
  alias Orchard.Repo

  @playground_defaults_key "playground_defaults"

  @spec get_playground_defaults() :: PlaygroundDefaults.t()
  def get_playground_defaults do
    case Repo.get(Entry, @playground_defaults_key) do
      nil -> PlaygroundDefaults.defaults()
      %Entry{value: value} -> PlaygroundDefaults.normalize(value)
    end
  end

  @spec save_playground_defaults(map()) ::
          {:ok, PlaygroundDefaults.t()} | {:error, Ecto.Changeset.t()}
  def save_playground_defaults(attrs) when is_map(attrs) do
    with {:ok, defaults} <- PlaygroundDefaults.cast_params(attrs) do
      value = PlaygroundDefaults.to_value(defaults)

      %Entry{}
      |> Entry.changeset(%{key: @playground_defaults_key, value: value})
      |> Repo.insert(
        on_conflict: {:replace, [:value, :updated_at]},
        conflict_target: :key,
        returning: true
      )
      |> case do
        {:ok, %Entry{value: saved_value}} -> {:ok, PlaygroundDefaults.normalize(saved_value)}
        {:error, changeset} -> {:error, changeset}
      end
    end
  end
end
