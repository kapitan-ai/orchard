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
    node_id = resolve_identity!(runtime)

    # Write resolved identity back into Application env for runtime reads
    updated_runtime = Keyword.put(runtime, :node_id, node_id)
    Application.put_env(:orchard_node_agent, :runtime, updated_runtime)

    Logger.info("Node identity resolved: #{node_id}")
    node_id
  end

  @doc false
  def resolve_identity!(runtime) do
    case Keyword.get(runtime, :node_id) do
      id when is_binary(id) and id != "" ->
        validate_uuid!(id, :config)
        id

      _ ->
        resolve_from_file_or_generate!(runtime)
    end
  end

  defp resolve_from_file_or_generate!(runtime) do
    path = Keyword.fetch!(runtime, :node_identity_path)

    case File.read(path) do
      {:ok, content} ->
        id = String.trim(content)
        validate_uuid!(id, {:file, path})
        id

      {:error, :enoent} ->
        generate_and_persist!(path)

      {:error, reason} ->
        raise "Cannot read node identity file #{path}: #{inspect(reason)}"
    end
  end

  # NOTE: This path assumes single ownership of the identity file.
  # Concurrent node-agent processes sharing the same node_identity_path
  # are not supported — Orchard assumes one node-agent per support root.
  # If concurrent startup is ever needed, use File.open(:exclusive) and
  # adopt-on-race instead of overwrite.
  defp generate_and_persist!(path) do
    id = generate_uuid()
    dir = Path.dirname(path)

    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> raise "Cannot create identity directory #{dir}: #{inspect(reason)}"
    end

    # Atomic write: temp file in same directory, then rename
    tmp_path = path <> ".tmp." <> Base.encode16(:crypto.strong_rand_bytes(4))

    case File.write(tmp_path, id <> "\n") do
      :ok ->
        :ok

      {:error, reason} ->
        raise "Cannot write temporary identity file #{tmp_path}: #{inspect(reason)}"
    end

    case File.rename(tmp_path, path) do
      :ok ->
        Logger.info("Generated new node identity: #{id} -> #{path}")
        id

      {:error, reason} ->
        File.rm(tmp_path)
        raise "Cannot persist identity file #{path}: #{inspect(reason)}"
    end
  end

  defp validate_uuid!(value, source) do
    unless Regex.match?(@uuid_regex, value) do
      source_desc =
        case source do
          :config -> "config :node_id"
          {:file, path} -> "identity file #{path}"
        end

      raise "Invalid node UUID from #{source_desc}: #{inspect(value)}"
    end
  end

  defp generate_uuid do
    <<a::48, _::4, b::12, _::2, c::62>> = :crypto.strong_rand_bytes(16)
    # UUIDv4: version 4, variant 10
    <<a::48, 4::4, b::12, 2::2, c::62>>
    |> Base.encode16(case: :lower)
    |> then(fn hex ->
      <<g1::binary-8, g2::binary-4, g3::binary-4, g4::binary-4, g5::binary-12>> = hex
      "#{g1}-#{g2}-#{g3}-#{g4}-#{g5}"
    end)
  end
end
