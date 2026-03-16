defmodule Orchard.Models do
  @moduledoc """
  Persistence context for Orchard model catalog data.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias Orchard.Models.Model
  alias Orchard.Repo

  @transition_targets %{
    registered: [:active, :retired],
    active: [:deprecated, :retired],
    deprecated: [:active, :retired],
    retired: []
  }

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

  # -- Lifecycle transitions --

  @doc """
  Returns the list of valid target states for the given model or state atom.
  """
  @spec available_transitions(struct() | atom()) :: [atom()]
  def available_transitions(%Model{state: state}), do: available_transitions(state)

  def available_transitions(state) when is_atom(state),
    do: Map.get(@transition_targets, state, [])

  @doc """
  Transitions a model to the `:active` state.

  Allowed from `:registered` or `:deprecated`.
  """
  @spec activate_model(struct() | String.t()) ::
          {:ok, struct()} | {:error, Changeset.t() | :not_found}
  def activate_model(model_or_id), do: transition_model_state(model_or_id, :active)

  @doc """
  Transitions a model to the `:deprecated` state.

  Allowed from `:active`.
  """
  @spec deprecate_model(struct() | String.t()) ::
          {:ok, struct()} | {:error, Changeset.t() | :not_found}
  def deprecate_model(model_or_id), do: transition_model_state(model_or_id, :deprecated)

  @doc """
  Transitions a model to the `:retired` state.

  Allowed from `:registered`, `:active`, or `:deprecated`. Retired is terminal.
  """
  @spec retire_model(struct() | String.t()) ::
          {:ok, struct()} | {:error, Changeset.t() | :not_found}
  def retire_model(model_or_id), do: transition_model_state(model_or_id, :retired)

  defp transition_model_state(model_or_id, target_state) do
    with {:ok, id} <- normalize_model_id(model_or_id) do
      allowed_sources = allowed_source_states(target_state)
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      {count, rows} =
        Model
        |> where([m], m.id == ^id and m.state in ^allowed_sources)
        |> select([m], m)
        |> Repo.update_all(set: [state: target_state, updated_at: now])

      case count do
        1 ->
          {:ok, hd(rows)}

        0 ->
          case Repo.get(Model, id) do
            nil -> {:error, :not_found}
            model -> {:error, invalid_transition_changeset(model, target_state)}
          end
      end
    end
  end

  defp normalize_model_id(%Model{id: id}), do: normalize_model_id(id)

  defp normalize_model_id(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :not_found}
    end
  end

  defp normalize_model_id(_), do: {:error, :not_found}

  defp allowed_source_states(target_state) do
    Enum.flat_map(@transition_targets, fn {source, targets} ->
      if target_state in targets, do: [source], else: []
    end)
  end

  defp invalid_transition_changeset(%Model{} = model, target_state) do
    model
    |> Changeset.change()
    |> Changeset.add_error(:state, "cannot transition from %{from} to %{to}",
      from: model.state,
      to: target_state
    )
  end

  defp maybe_filter_state(query, nil), do: query

  defp maybe_filter_state(query, state) do
    where(query, [model], model.state == ^state)
  end

  defp zero_fill_states(counts, states) do
    Map.new(states, fn state -> {state, Map.get(counts, state, 0)} end)
  end
end
