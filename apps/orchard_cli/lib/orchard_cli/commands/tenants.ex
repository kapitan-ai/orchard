defmodule OrchardCLI.Commands.Tenants do
  @moduledoc """
  CLI handler for `orchardctl tenants` commands.
  """

  alias Ecto.Changeset
  alias Orchard.Governance
  alias OrchardCLI.Commands.GovernanceHelpers
  alias OrchardCLI.RepoRuntime

  @spec run([String.t()]) :: OrchardCLI.command_result()
  def run(args) do
    case args do
      ["create" | rest] -> run_create(rest)
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
        required = missing_switches(opts, slug: "--slug", name: "--name")

        with :ok <- validate_required_switches(required),
             {:ok, slug} <- fetch_option(opts, :slug),
             {:ok, name} <- fetch_option(opts, :name) do
          create_tenant(slug, name)
        end
    end
  end

  defp parse_create_opts(args) do
    switches = [slug: :string, name: :string, help: :boolean]

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

  defp create_tenant(slug, name) do
    RepoRuntime.run(fn -> do_create_tenant(slug, name) end)
  end

  defp do_create_tenant(slug, name) do
    case Governance.create_tenant(%{slug: slug, name: name}) do
      {:ok, tenant} ->
        {:ok,
         Enum.join(
           [
             "Created tenant",
             "  Tenant ID: #{tenant.id}",
             "  Slug: #{tenant.slug}",
             "  Name: #{tenant.name}"
           ],
           "\n"
         )}

      {:error, %Changeset{} = changeset} ->
        {:error, format_changeset_error("tenant create failed", changeset), 1}
    end
  end

  defp validate_required_switches([]), do: :ok

  defp validate_required_switches(missing) do
    {:error,
     "Error: missing required option(s): #{Enum.join(missing, ", ")}\n\n#{create_usage()}", 1}
  end

  defp missing_switches(opts, switches) do
    Enum.flat_map(switches, fn {key, switch} ->
      if Keyword.get(opts, key) == nil, do: [switch], else: []
    end)
  end

  defp fetch_option(opts, key) do
    {:ok, Keyword.fetch!(opts, key)}
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
        "Usage: orchardctl tenants <command>",
        "",
        "Commands:",
        "  create  Create a tenant"
      ],
      "\n"
    )
  end

  defp create_usage do
    Enum.join(
      [
        "Usage: orchardctl tenants create --slug <slug> --name <name>",
        "",
        "Options:",
        "  --slug <slug>  Tenant slug",
        "  --name <name>  Tenant display name",
        "  --help         Show this help message"
      ],
      "\n"
    )
  end
end
