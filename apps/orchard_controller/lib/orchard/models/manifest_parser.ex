defmodule Orchard.Models.ManifestParser do
  @moduledoc """
  Parses a model bundle's `manifest.json` into an `Orchard.ModelManifest`.

  Bridges from JSON string-keyed maps to the atom-keyed domain struct,
  rejecting unknown top-level keys and normalizing nested structures
  before delegating to `ModelManifest.new/1` for domain validation.
  """

  alias Orchard.ModelManifest

  @manifest_filename "manifest.json"

  @known_top_level_keys ~w(
    model_id version format artifact_layout entrypoint sha256
    size_bytes resident_memory_bytes kv_cache_bytes_per_token
    prefill_workspace_bytes_per_token max_context_tokens
    capabilities tokenizer chat_template runtime_requirements
  )

  @known_tokenizer_keys ~w(kind path)
  @known_chat_template_keys ~w(path sha256)
  @known_runtime_requirements_keys ~w(adapter min_agent_capability)

  @doc """
  Reads and parses `manifest.json` from a bundle directory.

  Returns `{:ok, manifest}` or `{:error, reason}` where reason is
  `{:manifest_not_found, path}`, `{:json_decode, message}`, or
  `{:validation, message}`.
  """
  @spec parse_from_bundle(String.t()) :: {:ok, ModelManifest.t()} | {:error, term()}
  def parse_from_bundle(bundle_path) when is_binary(bundle_path) do
    manifest_path = Path.join(bundle_path, @manifest_filename)

    case File.read(manifest_path) do
      {:ok, json} ->
        parse_json(json)

      {:error, :enoent} ->
        {:error, {:manifest_not_found, manifest_path}}

      {:error, reason} ->
        {:error, {:manifest_read, "failed to read #{manifest_path}: #{inspect(reason)}"}}
    end
  end

  @doc """
  Parses a JSON string into an `Orchard.ModelManifest`.

  Returns `{:ok, manifest}` or `{:error, reason}`.
  """
  @spec parse_json(String.t()) :: {:ok, ModelManifest.t()} | {:error, term()}
  def parse_json(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) ->
        atomize_and_build(map)

      {:ok, _other} ->
        {:error, {:json_decode, "manifest must be a JSON object"}}

      {:error, %Jason.DecodeError{} = err} ->
        {:error, {:json_decode, Exception.message(err)}}
    end
  end

  defp atomize_and_build(string_map) do
    with {:ok, atom_map} <- atomize_top_level(string_map),
         {:ok, atom_map} <- atomize_nested(atom_map, :tokenizer, @known_tokenizer_keys),
         {:ok, atom_map} <- atomize_nested(atom_map, :chat_template, @known_chat_template_keys),
         {:ok, atom_map} <-
           atomize_nested(atom_map, :runtime_requirements, @known_runtime_requirements_keys) do
      build_manifest(atom_map)
    end
  end

  defp atomize_top_level(string_map) do
    unknown = Map.keys(string_map) -- @known_top_level_keys

    if unknown != [] do
      {:error, {:validation, "unknown manifest keys: #{inspect(unknown)}"}}
    else
      atom_map =
        for {k, v} <- string_map, into: %{} do
          {String.to_existing_atom(k), v}
        end

      {:ok, atom_map}
    end
  end

  defp atomize_nested(atom_map, key, known_keys) do
    case Map.get(atom_map, key) do
      nil ->
        {:ok, atom_map}

      nested when is_map(nested) ->
        atomize_nested_map(atom_map, key, nested, known_keys)

      _other ->
        # Let ModelManifest.new/1 handle type validation
        {:ok, atom_map}
    end
  end

  defp atomize_nested_map(atom_map, key, nested, known_keys) do
    unknown = Map.keys(nested) -- known_keys

    if unknown != [] do
      {:error, {:validation, "unknown keys in #{inspect(key)}: #{inspect(unknown)}"}}
    else
      atomized = for {k, v} <- nested, into: %{}, do: {String.to_existing_atom(k), v}
      {:ok, Map.put(atom_map, key, atomized)}
    end
  end

  defp build_manifest(atom_map) do
    {:ok, ModelManifest.new(atom_map)}
  rescue
    e in ArgumentError ->
      {:error, {:validation, Exception.message(e)}}
  end
end
