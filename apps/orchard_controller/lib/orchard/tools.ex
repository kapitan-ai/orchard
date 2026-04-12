defmodule Orchard.Tools do
  @moduledoc """
  Persistence context for Orchard tool registry data.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias Orchard.Repo
  alias Orchard.Tools.Tool

  @transition_targets %{
    active: [:deprecated],
    deprecated: [:active]
  }

  @type identity :: {String.t(), String.t()}

  @spec list_tools(keyword()) :: [Tool.t()]
  def list_tools(opts \\ []) do
    Tool
    |> maybe_filter_state(Keyword.get(opts, :state))
    |> order_by([tool], asc: tool.inserted_at, asc: tool.id)
    |> Repo.all()
  end

  @spec list_active_tools() :: [Tool.t()]
  def list_active_tools do
    list_tools(state: :active)
  end

  @spec get_tool!(Ecto.UUID.t()) :: Tool.t()
  def get_tool!(id), do: Repo.get!(Tool, id)

  @spec get_tool_by_identity(String.t(), String.t()) :: Tool.t() | nil
  def get_tool_by_identity(name, version) do
    Repo.get_by(Tool, name: name, version: version)
  end

  @spec fetch_tool_by_identity(String.t(), String.t()) ::
          {:ok, Tool.t() | nil} | {:error, :unavailable}
  def fetch_tool_by_identity(name, version) do
    if repo_available?() do
      {:ok, Repo.get_by(Tool, name: name, version: version)}
    else
      {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  @spec fetch_active_tools_by_identity([identity()]) :: %{optional(identity()) => Tool.t()}
  def fetch_active_tools_by_identity(identities) when is_list(identities) do
    identities = Enum.uniq(identities)

    case identities do
      [] ->
        %{}

      _ ->
        matcher = build_identity_matcher(identities)

        Tool
        |> where([tool], tool.state == :active)
        |> where(^matcher)
        |> Repo.all()
        |> Map.new(fn tool -> {{tool.name, tool.version}, tool} end)
    end
  end

  @spec create_tool(map()) :: {:ok, Tool.t()} | {:error, Ecto.Changeset.t()}
  def create_tool(attrs) do
    %Tool{}
    |> Tool.changeset(attrs)
    |> Repo.insert()
  end

  @spec activate_tool(Tool.t() | String.t()) ::
          {:ok, Tool.t()} | {:error, Changeset.t() | :not_found}
  def activate_tool(tool_or_id), do: transition_tool_state(tool_or_id, :active)

  @spec deprecate_tool(Tool.t() | String.t()) ::
          {:ok, Tool.t()} | {:error, Changeset.t() | :not_found}
  def deprecate_tool(tool_or_id), do: transition_tool_state(tool_or_id, :deprecated)

  defp transition_tool_state(tool_or_id, target_state) do
    with {:ok, id} <- normalize_tool_id(tool_or_id) do
      allowed_sources = allowed_source_states(target_state)
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      {count, rows} =
        Tool
        |> where([tool], tool.id == ^id and tool.state in ^allowed_sources)
        |> select([tool], tool)
        |> Repo.update_all(set: [state: target_state, updated_at: now])

      transition_tool_state_result(count, rows, id, target_state)
    end
  end

  defp transition_tool_state_result(1, rows, _id, _target_state), do: {:ok, hd(rows)}

  defp transition_tool_state_result(0, _rows, id, target_state) do
    case Repo.get(Tool, id) do
      nil -> {:error, :not_found}
      tool -> {:error, invalid_transition_changeset(tool, target_state)}
    end
  end

  defp normalize_tool_id(%Tool{id: id}), do: normalize_tool_id(id)

  defp normalize_tool_id(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :not_found}
    end
  end

  defp normalize_tool_id(_), do: {:error, :not_found}

  defp build_identity_matcher([{name, version} | rest]) do
    Enum.reduce(
      rest,
      dynamic([tool], tool.name == ^name and tool.version == ^version),
      fn {next_name, next_version}, dynamic_query ->
        dynamic(
          [tool],
          ^dynamic_query or (tool.name == ^next_name and tool.version == ^next_version)
        )
      end
    )
  end

  defp allowed_source_states(target_state) do
    Enum.flat_map(@transition_targets, fn {source, targets} ->
      if target_state in targets, do: [source], else: []
    end)
  end

  defp invalid_transition_changeset(%Tool{} = tool, target_state) do
    tool
    |> Changeset.change()
    |> Changeset.add_error(:state, "cannot transition from %{from} to %{to}",
      from: tool.state,
      to: target_state
    )
  end

  defp maybe_filter_state(query, nil), do: query

  defp maybe_filter_state(query, state) do
    where(query, [tool], tool.state == ^state)
  end

  defp repo_available? do
    pid = Process.whereis(Orchard.Repo)
    is_pid(pid) and Process.alive?(pid)
  end
end
