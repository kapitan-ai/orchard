defmodule OrchardCLI.Commands.ApiKeys do
  @moduledoc """
  CLI handler for `orchardctl api-keys` commands.
  """

  alias Ecto.Changeset
  alias Orchard.Governance
  alias OrchardCLI.Commands.GovernanceHelpers
  alias OrchardCLI.RepoRuntime

  @spec run([String.t()]) :: OrchardCLI.command_result()
  def run(args) do
    case args do
      ["create" | rest] -> run_create(rest)
      ["revoke" | rest] -> run_revoke(rest)
      ["help"] -> {:ok, group_usage()}
      ["--help"] -> {:ok, group_usage()}
      [] -> {:error, group_usage(), 1}
      _ -> {:error, group_usage(), 1}
    end
  end

  defp run_create(args) do
    case parse_create_opts(args) do
      {:help} ->
        {:ok, create_usage()}

      {:error, _, _} = error ->
        error

      {:ok, opts} ->
        with {:ok, tenant_id, name} <- validate_create_opts(opts),
             {:ok, result} <- create_api_key(tenant_id, name) do
          {:ok, result}
        else
          {:error, _, _} = error -> error
        end
    end
  end

  defp run_revoke(args) do
    case parse_revoke_opts(args) do
      {:help} ->
        {:ok, revoke_usage()}

      {:error, _, _} = error ->
        error

      {:ok, opts} ->
        with {:ok, api_key_id} <- validate_revoke_opts(opts),
             {:ok, result} <- revoke_api_key(api_key_id) do
          {:ok, result}
        else
          {:error, _, _} = error -> error
        end
    end
  end

  defp parse_create_opts(args) do
    switches = [tenant_id: :string, name: :string, help: :boolean]

    case OptionParser.parse(args, strict: switches) do
      {parsed, [], []} ->
        if Keyword.get(parsed, :help, false), do: {:help}, else: {:ok, parsed}

      {_parsed, positional, []} ->
        {:error,
         "Error: unexpected argument(s): #{Enum.join(positional, ", ")}\n\n#{create_usage()}", 1}

      {_parsed, _positional, invalid} ->
        invalid_str = Enum.map_join(invalid, ", ", fn {flag, _value} -> flag end)
        {:error, "Error: unknown option(s): #{invalid_str}\n\n#{create_usage()}", 1}
    end
  end

  defp parse_revoke_opts(args) do
    switches = [api_key_id: :string, help: :boolean]

    case OptionParser.parse(args, strict: switches) do
      {parsed, [], []} ->
        if Keyword.get(parsed, :help, false), do: {:help}, else: {:ok, parsed}

      {_parsed, positional, []} ->
        {:error,
         "Error: unexpected argument(s): #{Enum.join(positional, ", ")}\n\n#{revoke_usage()}", 1}

      {_parsed, _positional, invalid} ->
        invalid_str = Enum.map_join(invalid, ", ", fn {flag, _value} -> flag end)
        {:error, "Error: unknown option(s): #{invalid_str}\n\n#{revoke_usage()}", 1}
    end
  end

  defp validate_create_opts(opts) do
    required = missing_switches(opts, tenant_id: "--tenant-id", name: "--name")

    with :ok <- validate_required_switches(required, create_usage()),
         {:ok, tenant_id} <- validate_uuid(Keyword.fetch!(opts, :tenant_id), "--tenant-id") do
      {:ok, tenant_id, Keyword.fetch!(opts, :name)}
    end
  end

  defp validate_revoke_opts(opts) do
    required = missing_switches(opts, api_key_id: "--api-key-id")

    case validate_required_switches(required, revoke_usage()) do
      :ok -> validate_uuid(Keyword.fetch!(opts, :api_key_id), "--api-key-id")
      {:error, _, _} = error -> error
    end
  end

  defp create_api_key(tenant_id, name) do
    RepoRuntime.run(fn -> do_create_api_key(tenant_id, name) end)
  end

  defp do_create_api_key(tenant_id, name) do
    case Governance.create_api_key(tenant_id, %{name: name}) do
      {:ok, %{api_key: api_key, token: token}} ->
        {:ok,
         Enum.join(
           [
             "Created API key",
             "  API key ID: #{api_key.id}",
             "  Tenant ID: #{api_key.tenant_id}",
             "  Name: #{api_key.name}",
             "  Token: #{token}"
           ],
           "\n"
         )}

      {:error, %Changeset{} = changeset} ->
        {:error, format_changeset_error("API key create failed", changeset), 1}

      {:error, :tenant_not_found} ->
        {:error, "Error: tenant not found: #{tenant_id}", 1}

      {:error, :invalid_api_key_secret} ->
        {:error, "Error: API key create failed: unable to generate a valid token.", 1}
    end
  end

  defp revoke_api_key(api_key_id) do
    RepoRuntime.run(fn -> do_revoke_api_key(api_key_id) end)
  end

  defp do_revoke_api_key(api_key_id) do
    case Governance.revoke_api_key(api_key_id) do
      {:ok, api_key} ->
        {:ok,
         Enum.join(
           [
             "API key is revoked",
             "  API key ID: #{api_key.id}",
             "  Tenant ID: #{api_key.tenant_id}",
             "  Name: #{api_key.name}",
             "  Revoked at: #{DateTime.to_iso8601(api_key.revoked_at)}"
           ],
           "\n"
         )}

      {:error, %Changeset{} = changeset} ->
        {:error, format_changeset_error("API key revoke failed", changeset), 1}

      {:error, :api_key_not_found} ->
        {:error, "Error: API key not found: #{api_key_id}", 1}
    end
  end

  defp validate_required_switches([], _usage), do: :ok

  defp validate_required_switches(missing, usage) do
    {:error, "Error: missing required option(s): #{Enum.join(missing, ", ")}\n\n#{usage}", 1}
  end

  defp missing_switches(opts, switches) do
    Enum.flat_map(switches, fn {key, switch} ->
      if Keyword.get(opts, key) == nil, do: [switch], else: []
    end)
  end

  defp validate_uuid(raw_value, switch_name) do
    case Ecto.UUID.cast(raw_value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, "Error: #{switch_name} must be a valid UUID: #{raw_value}", 1}
    end
  end

  defp format_changeset_error(prefix, changeset) do
    lines = GovernanceHelpers.format_changeset_errors(changeset)

    Enum.join(
      ["Error: #{prefix}:"] ++ Enum.map(lines, &"  - #{&1}"),
      "\n"
    )
  end

  defp group_usage do
    Enum.join(
      [
        "Usage: orchardctl api-keys <command>",
        "",
        "Commands:",
        "  create  Create an API key",
        "  revoke  Revoke an API key"
      ],
      "\n"
    )
  end

  defp create_usage do
    Enum.join(
      [
        "Usage: orchardctl api-keys create --tenant-id <uuid> --name <name>",
        "",
        "Options:",
        "  --tenant-id <uuid>  Tenant UUID",
        "  --name <name>       API key display name",
        "  --help              Show this help message"
      ],
      "\n"
    )
  end

  defp revoke_usage do
    Enum.join(
      [
        "Usage: orchardctl api-keys revoke --api-key-id <uuid>",
        "",
        "Options:",
        "  --api-key-id <uuid>  API key UUID",
        "  --help               Show this help message"
      ],
      "\n"
    )
  end
end
