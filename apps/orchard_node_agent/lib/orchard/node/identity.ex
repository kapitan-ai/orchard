defmodule Orchard.Node.Identity do
  @moduledoc """
  Boot-time node identity resolution.

  Resolves a stable UUID node identity with the following precedence:
  1. Explicit config/env `node_id`
  2. Persisted identity file at `node_identity_path`
  3. Generate UUID + persist via atomic write

  Called once during application startup before the supervision tree starts.
  The resolved identity is written back to Application env so subsequent
  reads via `Orchard.Node.node_id/0` are pure config lookups.
  """

  require Logger

  alias Orchard.Node.RuntimeTLS
  alias Orchard.NodeIdentityFile

  @uuid_regex ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

  @doc """
  Resolves node identity and persists the result into Application env.

  Raises on:
  - Invalid explicit `node_id` in config
  - Unreadable or corrupt identity file
  - File write failure during first-boot generation
  """
  @spec ensure_identity!() :: String.t()
  def ensure_identity! do
    runtime = Application.fetch_env!(:orchard_node_agent, :runtime)
    {node_id, updated_runtime} = resolve_runtime_identity!(runtime)
    Application.put_env(:orchard_node_agent, :runtime, updated_runtime)

    Logger.info("Node identity resolved: #{node_id}")
    node_id
  end

  defp resolve_runtime_identity!(runtime) do
    case RuntimeTLS.load(runtime) do
      :plaintext_compatibility ->
        node_id = resolve_identity!(runtime)
        {node_id, Keyword.put(runtime, :node_id, node_id)}

      {:ok, identity} ->
        ensure_configured_identity_matches!(runtime[:node_id], identity.node_id)

        updated =
          runtime
          |> Keyword.put(:node_id, identity.node_id)
          |> Keyword.put(:runtime_tls_identity, identity)

        {identity.node_id, updated}

      {:error, reason} ->
        raise "Node Runtime TLS identity invalid: #{reason}"
    end
  end

  defp ensure_configured_identity_matches!(nil, _node_id), do: :ok
  defp ensure_configured_identity_matches!("", _node_id), do: :ok
  defp ensure_configured_identity_matches!(node_id, node_id), do: :ok

  defp ensure_configured_identity_matches!(_configured, _persisted) do
    raise "Configured Node id does not match the registered Runtime TLS identity"
  end

  @doc false
  def resolve_identity!(runtime) do
    case Keyword.get(runtime, :node_id) do
      id when is_binary(id) and id != "" ->
        validate_config_uuid!(id)
        id

      _ ->
        resolve_from_file_or_generate!(runtime)
    end
  end

  defp resolve_from_file_or_generate!(runtime) do
    path = Keyword.fetch!(runtime, :node_identity_path)

    case NodeIdentityFile.ensure(path) do
      {:ok, id, :existing} ->
        id

      {:ok, id, :generated} ->
        Logger.info("Generated new node identity: #{id} -> #{path}")
        id

      {:error, {:invalid_uuid, value}} ->
        raise "Invalid node UUID from identity file #{path}: #{inspect(value)}"

      {:error, {:read_failed, reason}} ->
        raise "Cannot read node identity file #{path}: #{inspect(reason)}"

      {:error, {:write_failed, reason}} ->
        raise_write_error!(path, reason)
    end
  end

  defp validate_config_uuid!(value) do
    unless Regex.match?(@uuid_regex, value) do
      raise "Invalid node UUID from config :node_id: #{inspect(value)}"
    end
  end

  defp raise_write_error!(path, reason) do
    dir = Path.dirname(path)

    if File.dir?(dir) do
      raise "Cannot persist identity file #{path}: #{inspect(reason)}"
    else
      raise "Cannot create identity directory #{dir}: #{inspect(reason)}"
    end
  end
end
