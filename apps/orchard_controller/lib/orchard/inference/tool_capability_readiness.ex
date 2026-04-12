defmodule Orchard.Inference.ToolCapabilityReadiness do
  @moduledoc """
  Read-only controller view over hosted-tool capability and readiness observations.

  Answers which persisted nodes can host a registry tool right now without
  introducing dispatch or hosted execution behavior.
  """

  alias Orchard.Inference
  alias Orchard.Nodes
  alias Orchard.Nodes.Node
  alias Orchard.Tools
  alias Orchard.Tools.Tool

  defmodule Candidate do
    @moduledoc false

    @enforce_keys [
      :tool_ref,
      :tool_name,
      :tool_version,
      :execution_mode,
      :node_id,
      :display_name,
      :advertise_addr,
      :rpc_port,
      :state,
      :health,
      :last_heartbeat_at,
      :fresh?,
      :advertised?,
      :tool_ready?,
      :status_code,
      :status_message,
      :adapter_kind,
      :effective_ready?
    ]
    defstruct [
      :tool_ref,
      :tool_name,
      :tool_version,
      :execution_mode,
      :node_id,
      :display_name,
      :advertise_addr,
      :rpc_port,
      :state,
      :health,
      :last_heartbeat_at,
      :fresh?,
      :advertised?,
      :tool_ready?,
      :status_code,
      :status_message,
      :adapter_kind,
      :effective_ready?
    ]

    @type t :: %__MODULE__{
            tool_ref: String.t(),
            tool_name: String.t(),
            tool_version: String.t(),
            execution_mode: Tool.execution_mode(),
            node_id: Ecto.UUID.t(),
            display_name: String.t() | nil,
            advertise_addr: String.t() | nil,
            rpc_port: pos_integer() | nil,
            state: atom() | nil,
            health: atom() | nil,
            last_heartbeat_at: DateTime.t() | nil,
            fresh?: boolean(),
            advertised?: boolean(),
            tool_ready?: boolean() | nil,
            status_code: String.t() | nil,
            status_message: String.t() | nil,
            adapter_kind: String.t() | nil,
            effective_ready?: boolean()
          }
  end

  @type error_reason ::
          :tool_registry_unavailable
          | :tool_not_found
          | :tool_inactive
          | :tool_not_server_hostable

  @spec list_candidates(String.t(), String.t(), keyword()) ::
          {:ok, [Candidate.t()]} | {:error, error_reason()}
  def list_candidates(name, version, opts \\ []) when is_binary(name) and is_binary(version) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, %Tool{} = tool} <- fetch_server_hostable_tool(name, version) do
      {:ok,
       tool
       |> build_candidates(Nodes.list_nodes(), now)
       |> Enum.sort_by(&{&1.display_name || "", &1.node_id})}
    end
  end

  @spec list_hostable_nodes(String.t(), String.t(), keyword()) ::
          {:ok, [Candidate.t()]} | {:error, error_reason()}
  def list_hostable_nodes(name, version, opts \\ []) do
    with {:ok, candidates} <- list_candidates(name, version, opts) do
      {:ok, Enum.filter(candidates, & &1.effective_ready?)}
    end
  end

  defp fetch_server_hostable_tool(name, version) do
    case Tools.fetch_tool_by_identity(name, version) do
      {:error, :unavailable} ->
        {:error, :tool_registry_unavailable}

      {:ok, nil} ->
        {:error, :tool_not_found}

      {:ok, %Tool{state: state}} when state != :active ->
        {:error, :tool_inactive}

      {:ok, %Tool{execution_mode: execution_mode}} when execution_mode != :server_hostable ->
        {:error, :tool_not_server_hostable}

      {:ok, %Tool{} = tool} ->
        {:ok, tool}
    end
  end

  defp build_candidates(%Tool{} = tool, nodes, now) when is_list(nodes) do
    Enum.map(nodes, &build_candidate(tool, &1, now))
  end

  defp build_candidate(%Tool{} = tool, %Node{} = node, now) do
    tool_ref = "tool://#{tool.name}@#{tool.version}"
    capability = hosted_tool_capability(node, tool.name, tool.version, tool_ref)
    readiness = hosted_tool_readiness(node, tool_ref)
    fresh? = fresh_node?(node, now)
    advertised? = not is_nil(capability)
    tool_ready? = readiness_ready(readiness)

    %Candidate{
      tool_ref: tool_ref,
      tool_name: tool.name,
      tool_version: tool.version,
      execution_mode: tool.execution_mode,
      node_id: node.id,
      display_name: node.display_name,
      advertise_addr: node.advertise_addr,
      rpc_port: node.rpc_port,
      state: node.state,
      health: node.health,
      last_heartbeat_at: node.last_heartbeat_at,
      fresh?: fresh?,
      advertised?: advertised?,
      tool_ready?: tool_ready?,
      status_code: blank_to_nil(map_value(readiness, :status_code)),
      status_message: blank_to_nil(map_value(readiness, :status_message)),
      adapter_kind: capability |> map_value(:adapter_kind) |> blank_to_nil(),
      effective_ready?: effective_ready?(node, fresh?, advertised?, tool_ready?)
    }
  end

  defp effective_ready?(%Node{} = node, fresh?, advertised?, tool_ready?) do
    node.state == :active and
      node.health in [:healthy, :degraded] and
      fresh? and
      advertised? and
      tool_ready? == true
  end

  defp hosted_tool_capability(%Node{} = node, name, version, ref) do
    node
    |> hosted_tools()
    |> Enum.find(fn entry ->
      map_value(entry, :name) == name and
        map_value(entry, :version) == version and
        capability_ref_matches?(entry, ref) and
        non_empty_binary?(map_value(entry, :adapter_kind))
    end)
  end

  defp hosted_tool_readiness(%Node{tool_readiness: readiness}, ref) when is_map(readiness) do
    case Map.get(readiness, ref) do
      entry when is_map(entry) -> entry
      _other -> nil
    end
  end

  defp hosted_tool_readiness(_node, _ref), do: nil

  defp hosted_tools(%Node{capabilities: capabilities}) when is_map(capabilities) do
    case map_value(capabilities, :hosted_tools) do
      entries when is_list(entries) -> entries
      _other -> []
    end
  end

  defp hosted_tools(_node), do: []

  defp capability_ref_matches?(entry, ref) do
    case map_value(entry, :ref) do
      nil -> true
      ^ref -> true
      _other -> false
    end
  end

  defp fresh_node?(%Node{last_heartbeat_at: %DateTime{} = last_heartbeat_at}, %DateTime{} = now) do
    cutoff = DateTime.add(now, -Inference.node_freshness_threshold_ms(), :millisecond)
    DateTime.compare(last_heartbeat_at, cutoff) in [:eq, :gt]
  end

  defp fresh_node?(_node, _now), do: false

  defp readiness_ready(readiness) when is_map(readiness) do
    case map_value(readiness, :ready) do
      value when is_boolean(value) -> value
      _other -> nil
    end
  end

  defp readiness_ready(_readiness), do: nil

  defp blank_to_nil(value) when is_binary(value) and value != "", do: value
  defp blank_to_nil(_value), do: nil

  defp non_empty_binary?(value), do: is_binary(value) and value != ""

  defp map_value(nil, _key), do: nil

  defp map_value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
