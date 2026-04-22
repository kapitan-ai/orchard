defmodule Orchard.Models do
  @moduledoc """
  Persistence context for Orchard model catalog data.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias Orchard.Models.Importer
  alias Orchard.Models.Model
  alias Orchard.Repo
  alias Orchard.Requests.Request

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
  Resolves a catalog artifact URI to a local path under the configured root.

  Only `file://` URIs without host, query, or fragment are accepted. The
  resolved path must stay within `Orchard.Inference.artifacts_root/0` and no
  existing path component may be a symlink.
  """
  @spec artifact_local_path(Model.t() | String.t()) :: {:ok, String.t()} | {:error, term()}
  def artifact_local_path(%Model{artifact_uri: artifact_uri}),
    do: artifact_local_path(artifact_uri)

  def artifact_local_path("file://" <> _rest = artifact_uri) do
    with {:ok, local_path} <- file_uri_path(artifact_uri),
         {:ok, artifacts_root} <- expanded_artifacts_root(),
         expanded_path = Path.expand(local_path),
         :ok <- validate_local_artifact_contained(expanded_path, artifacts_root),
         :ok <- reject_symlink_components(expanded_path) do
      {:ok, expanded_path}
    end
  end

  def artifact_local_path(uri) when is_binary(uri), do: {:error, {:unsupported_uri, uri}}
  def artifact_local_path(_uri), do: {:error, :invalid_artifact_uri}

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

  # -- Model deletion --

  @doc """
  Returns `true` if the given model or state atom is eligible for deletion.

  Only `:retired` models can be deleted.
  """
  @spec deletable?(Model.t() | atom()) :: boolean()
  def deletable?(%Model{state: state}), do: deletable?(state)
  def deletable?(:retired), do: true
  def deletable?(_), do: false

  @doc """
  Deletes a retired model, removing its catalog row and artifact files.

  ## Algorithm

  1. Lock model row, verify `:retired`
  2. Lock all referencing requests
  3. If non-terminal requests exist, reject with `{:model_in_use, count}`
  4. Nullify `model_id` on terminal requests
  5. Rename artifact dir to quarantine path
  6. Delete model row
  7. After commit: remove quarantine directory

  Returns `{:ok, model}` on full success, `{:artifacts_cleanup_failed, model}`
  if the DB commit succeeded but filesystem cleanup failed, or
  `{:error, reason}` on pre-commit failure.
  """
  @spec delete_model(Model.t() | String.t()) ::
          {:ok, Model.t()}
          | {:artifacts_cleanup_failed, Model.t()}
          | {:error, :not_found | :not_retired | {:model_in_use, pos_integer()} | term()}
  def delete_model(model_or_id) do
    with {:ok, id} <- normalize_model_id(model_or_id) do
      id
      |> execute_delete_transaction()
      |> finalize_delete_result()
    end
  end

  defp finalize_delete_result({:ok, %{model: model, quarantine_path: nil}}), do: {:ok, model}

  defp finalize_delete_result({:ok, %{model: model, quarantine_path: qpath}}) do
    case File.rm_rf(qpath) do
      {:ok, _} -> {:ok, model}
      {:error, _, _} -> {:artifacts_cleanup_failed, model}
    end
  end

  defp finalize_delete_result({:error, reason}), do: {:error, reason}

  defp execute_delete_transaction(id) do
    Repo.transaction(fn ->
      with {:ok, model} <- lock_model_for_delete(id),
           :ok <- guard_retired(model),
           :ok <- guard_and_nullify_request_refs(model),
           {:ok, quarantine_path} <- quarantine_artifact_dir(model) do
        delete_locked_model(model, quarantine_path)
      else
        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  defp delete_locked_model(model, quarantine_path) do
    case Repo.delete(model) do
      {:ok, deleted} ->
        %{model: deleted, quarantine_path: quarantine_path}

      {:error, changeset} ->
        maybe_restore_quarantine(quarantine_path, model)
        Repo.rollback({:delete_failed, changeset})
    end
  end

  defp lock_model_for_delete(id) do
    case Model |> where([m], m.id == ^id) |> lock("FOR UPDATE") |> Repo.one() do
      nil -> {:error, :not_found}
      model -> {:ok, model}
    end
  end

  defp guard_retired(%Model{state: :retired}), do: :ok
  defp guard_retired(_), do: {:error, :not_retired}

  # Lock all referencing request rows, partition into terminal/non-terminal,
  # reject if any non-terminal exist, then nullify terminal model_id values.
  defp guard_and_nullify_request_refs(%Model{id: model_id}) do
    terminal_states = Request.terminal_states()
    refs = fetch_request_refs_for_model(model_id)
    {terminal_refs, non_terminal_refs} = partition_request_refs(refs, terminal_states)

    case non_terminal_refs do
      [] ->
        nullify_terminal_request_refs(terminal_refs)

      refs ->
        {:error, {:model_in_use, length(refs)}}
    end
  end

  defp fetch_request_refs_for_model(model_id) do
    Request
    |> where([r], r.model_id == ^model_id)
    |> lock("FOR UPDATE")
    |> select([r], {r.id, r.state})
    |> Repo.all()
  end

  defp partition_request_refs(refs, terminal_states) do
    Enum.split_with(refs, fn {_id, state} -> state in terminal_states end)
  end

  defp nullify_terminal_request_refs([]), do: :ok

  defp nullify_terminal_request_refs(terminal_refs) do
    ids = Enum.map(terminal_refs, fn {id, _} -> id end)

    Request
    |> where([r], r.id in ^ids)
    |> Repo.update_all(set: [model_id: nil])

    :ok
  end

  defp quarantine_artifact_dir(%Model{} = model) do
    artifacts_root = Orchard.Inference.artifacts_root()

    artifact_path =
      Importer.artifact_destination_path(artifacts_root, model.model_id, model.version)

    with :ok <- validate_artifact_path_contained(artifact_path, artifacts_root),
         :ok <- reject_symlink(artifact_path) do
      maybe_quarantine_artifact_dir(artifact_path, artifacts_root)
    end
  end

  defp maybe_quarantine_artifact_dir(artifact_path, artifacts_root) do
    if File.dir?(artifact_path) do
      quarantine_artifact_dir!(artifact_path, artifacts_root)
    else
      {:ok, nil}
    end
  end

  defp quarantine_artifact_dir!(artifact_path, artifacts_root) do
    deleting_dir = Path.join(artifacts_root, ".deleting")
    quarantine_path = Path.join(deleting_dir, Ecto.UUID.generate())

    case File.mkdir_p(deleting_dir) do
      :ok ->
        rename_to_quarantine(artifact_path, quarantine_path)

      {:error, reason} ->
        {:error, {:artifact_quarantine_failed, reason}}
    end
  end

  defp rename_to_quarantine(artifact_path, quarantine_path) do
    case File.rename(artifact_path, quarantine_path) do
      :ok -> {:ok, quarantine_path}
      {:error, reason} -> {:error, {:artifact_quarantine_failed, reason}}
    end
  end

  defp validate_artifact_path_contained(artifact_path, artifacts_root) do
    expanded_artifact = Path.expand(artifact_path)
    expanded_root = Path.expand(artifacts_root)

    if String.starts_with?(expanded_artifact, expanded_root <> "/") do
      :ok
    else
      {:error, {:path_escape, artifact_path}}
    end
  end

  # Reject artifact paths that are or contain symlinks to prevent traversal
  # beyond the containment check.
  defp reject_symlink(path) do
    case File.read_link(path) do
      {:ok, _target} -> {:error, {:path_escape, path}}
      {:error, _} -> :ok
    end
  end

  defp maybe_restore_quarantine(nil, _model), do: :ok

  defp maybe_restore_quarantine(quarantine_path, %Model{} = model) do
    artifacts_root = Orchard.Inference.artifacts_root()

    original_path =
      Importer.artifact_destination_path(artifacts_root, model.model_id, model.version)

    case File.rename(quarantine_path, original_path) do
      :ok ->
        :ok

      {:error, reason} ->
        require Logger

        Logger.error(
          "Failed to restore quarantined artifacts for model " <>
            "#{model.model_id}@#{model.version}: #{inspect(reason)}. " <>
            "Quarantined path: #{quarantine_path}"
        )

        :ok
    end
  end

  defp file_uri_path(artifact_uri) do
    uri = URI.parse(artifact_uri)

    cond do
      uri.scheme != "file" ->
        {:error, {:unsupported_uri, artifact_uri}}

      uri.host not in [nil, ""] ->
        {:error, {:unsupported_file_uri_host, uri.host}}

      uri.query || uri.fragment ->
        {:error, {:unsupported_file_uri_parts, artifact_uri}}

      not is_binary(uri.path) or uri.path == "" ->
        {:error, {:invalid_file_uri, artifact_uri}}

      true ->
        {:ok, URI.decode(uri.path)}
    end
  end

  defp expanded_artifacts_root do
    case Orchard.Inference.artifacts_root() do
      root when is_binary(root) and root != "" -> {:ok, Path.expand(root)}
      other -> {:error, {:invalid_artifacts_root, other}}
    end
  end

  defp validate_local_artifact_contained(path, artifacts_root) do
    if String.starts_with?(path, artifacts_root <> "/") do
      :ok
    else
      {:error, {:path_escape, path}}
    end
  end

  defp reject_symlink_components(path) do
    path
    |> path_prefixes()
    |> Enum.reduce_while(:ok, &reject_symlink_component/2)
  end

  defp path_prefixes(path) do
    path
    |> Path.split()
    |> Enum.reduce([], fn
      "/", [] -> ["/"]
      part, [] -> [part]
      part, acc -> acc ++ [Path.join(List.last(acc), part)]
    end)
  end

  defp reject_symlink_component(component, :ok) do
    case File.read_link(component) do
      {:ok, _target} -> {:halt, {:error, {:path_symlink, component}}}
      {:error, :enoent} -> {:halt, :ok}
      {:error, _not_symlink} -> validate_readable_component(component)
    end
  end

  defp validate_readable_component(component) do
    case File.lstat(component) do
      {:ok, _stat} -> {:cont, :ok}
      {:error, :enoent} -> {:halt, :ok}
      {:error, reason} -> {:halt, {:error, {:path_unreadable, component, reason}}}
    end
  end

  # -- Lifecycle transitions --

  defp transition_model_state(model_or_id, target_state) do
    with {:ok, id} <- normalize_model_id(model_or_id) do
      allowed_sources = allowed_source_states(target_state)
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      {count, rows} =
        Model
        |> where([m], m.id == ^id and m.state in ^allowed_sources)
        |> select([m], m)
        |> Repo.update_all(set: [state: target_state, updated_at: now])

      transition_model_state_result(count, rows, id, target_state)
    end
  end

  defp transition_model_state_result(1, rows, _id, _target_state), do: {:ok, hd(rows)}

  defp transition_model_state_result(0, _rows, id, target_state) do
    case Repo.get(Model, id) do
      nil -> {:error, :not_found}
      model -> {:error, invalid_transition_changeset(model, target_state)}
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
