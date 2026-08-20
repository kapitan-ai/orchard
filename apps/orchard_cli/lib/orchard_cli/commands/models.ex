defmodule OrchardCLI.Commands.Models do
  @moduledoc """
  CLI handler for `orchardctl models` commands.

  Supports:
    orchardctl models import <path> [--activate]
    orchardctl models list
    orchardctl models delete <model_id@version>
  """

  alias Orchard.Models
  alias Orchard.Models.Importer
  alias OrchardCLI.Commands.Models.Access, as: AccessCommand
  alias OrchardCLI.Commands.Models.Reference
  alias OrchardCLI.Commands.Models.RoutingPolicy, as: RoutingPolicyCommand
  alias OrchardCLI.RepoRuntime

  @spec run([String.t()]) :: OrchardCLI.command_result()
  def run(["import" | rest]) do
    {opts, args} = parse_import_args(rest)

    case args do
      [source_path] ->
        run_import(source_path, opts)

      [] ->
        {:error, "Error: missing bundle path\n#{import_usage()}", 1}

      _ ->
        {:error, "Error: expected exactly one bundle path\n#{import_usage()}", 1}
    end
  end

  def run(["list"]) do
    RepoRuntime.run(fn -> list_active_models() end)
  end

  def run(["delete" | rest]), do: run_delete(rest)
  def run(["access" | rest]), do: AccessCommand.run(rest)
  def run(["routing-policy" | rest]), do: RoutingPolicyCommand.run(rest)

  def run(_args) do
    {:error, group_usage(), 1}
  end

  defp run_import(source_path, opts) do
    RepoRuntime.run(fn -> do_run_import(source_path, opts) end)
  end

  defp list_active_models do
    Models.list_active_models()
    |> render_active_models()
  end

  defp render_active_models([]), do: {:ok, "No active models."}

  defp render_active_models(models) do
    lines =
      Enum.map_join(models, "\n", fn model ->
        "#{model.model_id}@#{model.version}  state=#{model.state}  format=#{model.format}"
      end)

    {:ok, lines}
  end

  defp do_run_import(source_path, opts) do
    artifacts_root = Importer.default_artifacts_root()

    import_opts = [
      artifacts_root: artifacts_root,
      activate: Keyword.get(opts, :activate, false)
    ]

    case Importer.import_bundle(source_path, import_opts) do
      {:ok, model} ->
        {:ok, "Imported #{model.model_id}@#{model.version} (state: #{model.state})"}

      {:error, reason} ->
        format_import_error(reason)
    end
  end

  defp format_import_error({:duplicate, message}), do: {:error, "Error: #{message}", 1}

  defp format_import_error({:source_not_found, path}),
    do: {:error, "Error: source path not found: #{path}", 1}

  defp format_import_error({:source_not_directory, message}),
    do: {:error, "Error: #{message}", 1}

  defp format_import_error({:manifest_not_found, path}),
    do: {:error, "Error: manifest.json not found at #{path}", 1}

  defp format_import_error({:validation, message}),
    do: {:error, "Error: invalid manifest: #{message}", 1}

  defp format_import_error({:json_decode, message}),
    do: {:error, "Error: failed to parse manifest.json: #{message}", 1}

  defp format_import_error({:missing_chat_template, message}),
    do: {:error, "Error: #{message}", 1}

  defp format_import_error(reason),
    do: {:error, "Error: import failed: #{inspect(reason)}", 1}

  defp run_delete([]) do
    {:error, "Error: missing model identity\n#{delete_usage()}", 1}
  end

  defp run_delete([identity]) do
    case Reference.parse_model_identity(identity) do
      {:ok, %{model_id: model_id, version: version}} ->
        RepoRuntime.run(fn -> do_run_delete(model_id, version, identity) end)

      :error ->
        {:error,
         "Error: expected model identity in the form <model_id@version>\n#{delete_usage()}", 1}
    end
  end

  defp run_delete(_args) do
    {:error, "Error: expected exactly one model identity\n#{delete_usage()}", 1}
  end

  defp do_run_delete(model_id, version, identity) do
    case Models.get_model_by_identity(model_id, version) do
      nil ->
        {:error, "Error: model not found: #{identity}", 1}

      model ->
        handle_delete_result(Models.delete_model(model.id), identity)
    end
  end

  defp handle_delete_result({:ok, model}, _identity) do
    {:ok, "Deleted #{model.model_id}@#{model.version}"}
  end

  defp handle_delete_result({:artifacts_cleanup_failed, model}, _identity) do
    {:error, "Error: deleted #{model.model_id}@#{model.version}, but artifact cleanup failed", 1}
  end

  defp handle_delete_result({:error, :not_found}, identity) do
    {:error, "Error: model not found: #{identity}", 1}
  end

  defp handle_delete_result({:error, :not_retired}, identity) do
    {:error, "Error: only retired models can be deleted: #{identity}", 1}
  end

  defp handle_delete_result({:error, {:model_in_use, count}}, identity) do
    {:error,
     "Error: cannot delete #{identity}: #{count} non-terminal request(s) still reference it", 1}
  end

  defp handle_delete_result({:error, reason}, identity) do
    {:error, "Error: delete failed for #{identity}: #{inspect(reason)}", 1}
  end

  defp group_usage,
    do: "Usage: orchardctl models <import|list|delete|access|routing-policy>"

  defp import_usage, do: "Usage: orchardctl models import <path> [--activate]"
  defp delete_usage, do: "Usage: orchardctl models delete <model_id@version>"

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
