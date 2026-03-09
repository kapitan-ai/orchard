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

  defp maybe_filter_state(query, nil), do: query

  defp maybe_filter_state(query, state) do
    where(query, [model], model.state == ^state)
  end
end
