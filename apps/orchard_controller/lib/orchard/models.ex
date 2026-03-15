defmodule Orchard.Models do
  @moduledoc """
  Persistence context for Orchard model catalog data.
  """

  import Ecto.Query

  alias Orchard.Models.Model
  alias Orchard.Repo

  @spec list_models(keyword()) :: [struct()]
  def list_models(opts \\ []) do
    Model
    |> maybe_filter_state(Keyword.get(opts, :state))
    |> order_by([model], asc: model.inserted_at, asc: model.id)
    |> Repo.all()
  end

  @spec list_active_models() :: [struct()]
  def list_active_models do
    list_models(state: :active)
  end

  @spec get_model!(Ecto.UUID.t()) :: struct()
  def get_model!(id), do: Repo.get!(Model, id)

  @spec get_model_by_identity(String.t(), String.t()) :: struct() | nil
  def get_model_by_identity(model_id, version) do
    Repo.get_by(Model, model_id: model_id, version: version)
  end

  @spec create_model(map()) :: {:ok, struct()} | {:error, Ecto.Changeset.t()}
  def create_model(attrs) do
    %Model{}
    |> Model.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Returns a summary of model catalog counts grouped by state.

  All states from `Model.states/0` are present in `by_state`, zero-filled
  when no rows exist for that state.
  """
  @spec catalog_summary() :: %{
          total: non_neg_integer(),
          by_state: %{required(atom()) => non_neg_integer()}
        }
  def catalog_summary do
    counts =
      Model
      |> group_by([m], m.state)
      |> select([m], {m.state, count(m.id)})
      |> Repo.all()
      |> Map.new()

    by_state = zero_fill_states(counts, Model.states())
    %{total: by_state |> Map.values() |> Enum.sum(), by_state: by_state}
  end

  defp maybe_filter_state(query, nil), do: query

  defp maybe_filter_state(query, state) do
    where(query, [model], model.state == ^state)
  end

  defp zero_fill_states(counts, states) do
    Map.new(states, fn state -> {state, Map.get(counts, state, 0)} end)
  end
end
