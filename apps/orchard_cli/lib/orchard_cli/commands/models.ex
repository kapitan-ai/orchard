defmodule OrchardCLI.Commands.Models do
  @moduledoc """
  CLI handler for `orchardctl models` commands.

  Supports:
    orchardctl models import <path> [--activate]
    orchardctl models list
  """

  alias Orchard.Models.Importer

  @spec run([String.t()]) :: OrchardCLI.command_result()
  def run(["import" | rest]) do
    {opts, args} = parse_import_args(rest)

    case args do
      [source_path] ->
        run_import(source_path, opts)

      [] ->
        {:error,
         "Error: missing bundle path\nUsage: orchardctl models import <path> [--activate]", 1}

      _ ->
        {:error,
         "Error: expected exactly one bundle path\nUsage: orchardctl models import <path> [--activate]",
         1}
    end
  end

  def run(["list"]) do
    models = Orchard.Models.list_active_models()

    if models == [] do
      {:ok, "No active models."}
    else
      lines =
        Enum.map_join(models, "\n", fn model ->
          "#{model.model_id}@#{model.version}  state=#{model.state}  format=#{model.format}"
        end)

      {:ok, lines}
    end
  end

  def run(_args) do
    {:error, "Usage: orchardctl models <import|list>", 1}
  end

  defp run_import(source_path, opts) do
    artifacts_root = Importer.default_artifacts_root()

    import_opts = [
      artifacts_root: artifacts_root,
      activate: Keyword.get(opts, :activate, false)
    ]

    case Importer.import_bundle(source_path, import_opts) do
      {:ok, model} ->
        {:ok, "Imported #{model.model_id}@#{model.version} (state: #{model.state})"}

      {:error, {:duplicate, message}} ->
        {:error, "Error: #{message}", 1}

      {:error, {:source_not_found, path}} ->
        {:error, "Error: source path not found: #{path}", 1}

      {:error, {:source_not_directory, message}} ->
        {:error, "Error: #{message}", 1}

      {:error, {:manifest_not_found, path}} ->
        {:error, "Error: manifest.json not found at #{path}", 1}

      {:error, {:validation, message}} ->
        {:error, "Error: invalid manifest: #{message}", 1}

      {:error, {:json_decode, message}} ->
        {:error, "Error: failed to parse manifest.json: #{message}", 1}

      {:error, reason} ->
        {:error, "Error: import failed: #{inspect(reason)}", 1}
    end
  end

  defp parse_import_args(args) do
    {flags, positional} =
      Enum.split_with(args, &String.starts_with?(&1, "--"))

    opts =
      Enum.reduce(flags, [], fn
        "--activate", acc -> [{:activate, true} | acc]
        _other, acc -> acc
      end)

    {opts, positional}
  end
end
