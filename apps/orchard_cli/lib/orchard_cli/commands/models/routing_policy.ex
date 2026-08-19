defmodule OrchardCLI.Commands.Models.RoutingPolicy do
  @moduledoc false

  alias Orchard.Inference.AdmissionPolicy
  alias Orchard.Models.Access
  alias OrchardCLI.Commands.Models.Reference
  alias OrchardCLI.RepoRuntime

  @spec run([String.t()]) :: OrchardCLI.command_result()
  def run(["create" | rest]), do: run_create(rest)
  def run(["list" | rest]), do: run_list(rest)
  def run(["inspect" | rest]), do: run_inspect(rest)
  def run(_args), do: {:error, usage(), 1}

  defp run_create(args) do
    with {:ok, opts} <- parse_create(args) do
      RepoRuntime.run(fn -> create_policy(opts) end)
    end
  end

  defp create_policy(opts) do
    with {:ok, tenant_id} <- resolve_scope(opts),
         {:ok, residency} <- parse_residency(opts[:residency_preference]) do
      defaults = AdmissionPolicy.default_routing_opts()

      attrs = %{
        tenant_id: tenant_id,
        name: opts[:name],
        allowed_pool_ids: [],
        preferred_pool_ids: [],
        residency_preference: residency,
        max_cold_start_ms: opts[:max_cold_start_ms] || defaults[:max_cold_start_ms],
        max_queue_wait_ms: opts[:max_queue_wait_ms] || defaults[:queue_wait_ms],
        priority: opts[:priority] || 100
      }

      attrs
      |> Access.create_routing_policy(actor_type: "operator", surface: "orchardctl")
      |> render_create()
    else
      {:error, reason} -> render_error(reason, opts)
    end
  end

  defp run_list(args) do
    with {:ok, opts} <- parse_scope_only(args, list_usage()) do
      RepoRuntime.run(fn -> list_policies(opts) end)
    end
  end

  defp list_policies(opts) do
    with {:ok, scope} <- resolve_list_scope(opts),
         {:ok, policies} <- Access.list_routing_policies(scope) do
      render_list(policies)
    else
      {:error, reason} -> render_error(reason, opts)
    end
  end

  defp run_inspect(args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: [id: :string])

    if invalid == [] and positional == [] and is_binary(opts[:id]) do
      RepoRuntime.run(fn -> inspect_policy(opts[:id]) end)
    else
      {:error, "Error: --id is required\n#{inspect_usage()}", 1}
    end
  end

  defp inspect_policy(id) do
    case Access.get_routing_policy(id) do
      {:ok, policy} -> {:ok, render_policy(policy)}
      {:error, :routing_policy_not_found} -> {:error, "Error: routing policy not found: #{id}", 1}
    end
  end

  defp parse_create(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [
          tenant: :string,
          global: :boolean,
          name: :string,
          residency_preference: :string,
          max_cold_start_ms: :integer,
          max_queue_wait_ms: :integer,
          priority: :integer
        ]
      )

    cond do
      invalid != [] or positional != [] ->
        {:error, "Error: invalid arguments\n#{create_usage()}", 1}

      scope_count(opts) != 1 ->
        {:error, "Error: choose exactly one of --tenant or --global\n#{create_usage()}", 1}

      blank?(opts[:name]) ->
        {:error, "Error: --name is required\n#{create_usage()}", 1}

      blank?(opts[:residency_preference]) ->
        {:error, "Error: --residency-preference is required\n#{create_usage()}", 1}

      true ->
        {:ok, opts}
    end
  end

  defp parse_scope_only(args, usage) do
    {opts, positional, invalid} =
      OptionParser.parse(args, strict: [tenant: :string, global: :boolean])

    if invalid == [] and positional == [] and scope_count(opts) == 1,
      do: {:ok, opts},
      else: {:error, "Error: choose exactly one of --tenant or --global\n#{usage}", 1}
  end

  defp resolve_scope(opts) do
    if opts[:global] do
      {:ok, nil}
    else
      case Reference.resolve_tenant(opts[:tenant]) do
        {:ok, tenant} -> {:ok, tenant.id}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp resolve_list_scope(opts) do
    if opts[:global], do: {:ok, :global}, else: Reference.resolve_tenant(opts[:tenant])
  end

  defp parse_residency(value) do
    case value do
      "required_loaded" -> {:ok, :required_loaded}
      "prefer_loaded" -> {:ok, :prefer_loaded}
      "allow_cold_load" -> {:ok, :allow_cold_load}
      _other -> {:error, :invalid_residency_preference}
    end
  end

  defp render_create({:ok, policy}), do: {:ok, "Created #{render_policy(policy)}"}

  defp render_create({:error, changeset}) do
    {:error, "Error: routing policy creation failed: #{format_changeset(changeset)}", 1}
  end

  defp render_list([]), do: {:ok, "No routing policies."}
  defp render_list(policies), do: {:ok, Enum.map_join(policies, "\n", &render_policy/1)}

  defp render_policy(policy) do
    scope = if policy.tenant_id, do: "tenant=#{policy.tenant_id}", else: "global"

    "#{policy.id}  name=#{policy.name}  #{scope}  residency=#{policy.residency_preference}  cold_start_ms=#{policy.max_cold_start_ms}  queue_wait_ms=#{policy.max_queue_wait_ms}"
  end

  defp render_error(:tenant_not_found, opts),
    do: {:error, "Error: tenant not found: #{opts[:tenant]}", 1}

  defp render_error(:invalid_residency_preference, _opts),
    do: {:error, "Error: invalid residency preference", 1}

  defp format_changeset(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)
    |> Enum.map_join(", ", fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
  end

  defp scope_count(opts) do
    Enum.count([opts[:tenant], opts[:global]], &present?/1)
  end

  defp present?(value), do: value not in [nil, false, ""]
  defp blank?(value), do: not present?(value)

  defp usage, do: Enum.join([create_usage(), list_usage(), inspect_usage()], "\n")

  defp create_usage do
    "Usage: orchardctl models routing-policy create (--tenant <uuid-or-slug> | --global) --name <name> --residency-preference <required_loaded|prefer_loaded|allow_cold_load> [--max-cold-start-ms <n>] [--max-queue-wait-ms <n>]"
  end

  defp list_usage,
    do: "Usage: orchardctl models routing-policy list (--tenant <uuid-or-slug> | --global)"

  defp inspect_usage,
    do: "Usage: orchardctl models routing-policy inspect --id <uuid>"
end
