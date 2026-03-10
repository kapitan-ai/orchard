defmodule OrchardCLI.Commands.Models do
  @moduledoc """
  CLI handler for `orchardctl models` commands.

  Supports:
    orchardctl models import <path> [--activate]
    orchardctl models list
  """

  alias Orchard.Models.Importer

  @spec run([String.t()]) :: :ok
  def run(["import" | rest]) do
    {opts, args} = parse_import_args(rest)

    case args do
      [source_path] ->
        run_import(source_path, opts)

      [] ->
        IO.puts(:stderr, "Error: missing bundle path")
        IO.puts(:stderr, "Usage: orchardctl models import <path> [--activate]")

      _ ->
        IO.puts(:stderr, "Error: expected exactly one bundle path")
        IO.puts(:stderr, "Usage: orchardctl models import <path> [--activate]")
    end

    :ok
  end

  def run(["list"]) do
    models = Orchard.Models.list_active_models()

    if models == [] do
      IO.puts("No active models.")
    else
      Enum.each(models, fn model ->
        IO.puts(
          "#{model.model_id}@#{model.version}  state=#{model.state}  format=#{model.format}"
        )
      end)
    end

    :ok
  end

  def run(_args) do
    IO.puts("Usage: orchardctl models <import|list>")
    :ok
  end

  defp run_import(source_path, opts) do
    artifacts_root = Importer.default_artifacts_root()

    import_opts = [
      artifacts_root: artifacts_root,
      activate: Keyword.get(opts, :activate, false)
    ]

    case Importer.import_bundle(source_path, import_opts) do
      {:ok, model} ->
        IO.puts("Imported #{model.model_id}@#{model.version} (state: #{model.state})")

      {:error, {:duplicate, message}} ->
        IO.puts(:stderr, "Error: #{message}")

      {:error, {:source_not_found, path}} ->
        IO.puts(:stderr, "Error: source path not found: #{path}")

      {:error, {:source_not_directory, message}} ->
        IO.puts(:stderr, "Error: #{message}")

      {:error, {:manifest_not_found, path}} ->
        IO.puts(:stderr, "Error: manifest.json not found at #{path}")

      {:error, {:validation, message}} ->
        IO.puts(:stderr, "Error: invalid manifest: #{message}")

      {:error, {:json_decode, message}} ->
        IO.puts(:stderr, "Error: failed to parse manifest.json: #{message}")

      {:error, reason} ->
        IO.puts(:stderr, "Error: import failed: #{inspect(reason)}")
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
