defmodule OrchardCLI.Commands.Models.Access do
  @moduledoc false

  alias Orchard.Models.Access, as: ModelAccess
  alias OrchardCLI.Commands.Models.Reference
  alias OrchardCLI.RepoRuntime

  @spec run([String.t()]) :: OrchardCLI.command_result()
  def run(["grant" | rest]), do: run_mutation(:grant, rest)
  def run(["disable" | rest]), do: run_mutation(:disable, rest)
  def run(["revoke" | rest]), do: run_mutation(:revoke, rest)
  def run(["list" | rest]), do: run_list(rest)
  def run(["inspect" | rest]), do: run_inspect(rest)
  def run(_args), do: {:error, usage(), 1}

  defp run_mutation(action, args) do
    with {:ok, identity, opts} <- parse_identity_and_tenant(args, action) do
      RepoRuntime.run(fn -> execute_mutation(action, identity, opts) end)
    end
  end

  defp execute_mutation(action, identity, opts) do
    with {:ok, tenant} <- Reference.resolve_tenant(opts[:tenant]),
         {:ok, model} <- Reference.resolve_model(identity),
         {:ok, policy_id} <- resolve_policy_id(opts[:routing_policy_id], action) do
      action
      |> mutate(tenant, model, policy_id)
      |> render_mutation(action, tenant, model)
    else
      {:error, reason} -> render_reference_error(reason, identity, opts)
    end
  end

  defp mutate(:grant, tenant, model, policy_id) do
    ModelAccess.grant_model_access(tenant, model, policy_id,
      actor_type: "operator",
      surface: "orchardctl"
    )
  end

  defp mutate(:disable, tenant, model, _policy_id) do
    ModelAccess.disable_model_access(tenant, model,
      actor_type: "operator",
      surface: "orchardctl"
    )
  end

  defp mutate(:revoke, tenant, model, _policy_id) do
    ModelAccess.revoke_model_access(tenant, model,
      actor_type: "operator",
      surface: "orchardctl"
    )
  end

  defp run_list(args) do
    with {:ok, tenant_ref} <- parse_tenant_only(args, list_usage()) do
      RepoRuntime.run(fn -> list_for_tenant(tenant_ref) end)
    end
  end

  defp list_for_tenant(tenant_ref) do
    with {:ok, tenant} <- Reference.resolve_tenant(tenant_ref),
         {:ok, access_rows} <- ModelAccess.list_model_access(tenant) do
      render_list(tenant, access_rows)
    else
      {:error, :tenant_not_found} -> tenant_not_found(tenant_ref)
    end
  end

  defp run_inspect(args) do
    with {:ok, identity, opts} <- parse_identity_and_tenant(args, :inspect) do
      RepoRuntime.run(fn -> inspect_access(identity, opts[:tenant]) end)
    end
  end

  defp inspect_access(identity, tenant_ref) do
    with {:ok, tenant} <- Reference.resolve_tenant(tenant_ref),
         {:ok, model} <- Reference.resolve_model(identity),
         {:ok, access} <- ModelAccess.get_model_access(tenant, model) do
      {:ok, render_access(access, tenant.slug)}
    else
      {:error, reason} ->
        render_reference_error(reason, identity, tenant: tenant_ref)
    end
  end

  defp parse_identity_and_tenant(args, action) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [tenant: :string, routing_policy_id: :string]
      )

    cond do
      invalid != [] ->
        {:error, "Error: invalid option\n#{mutation_usage(action)}", 1}

      length(positional) != 1 ->
        {:error, "Error: expected one model identity\n#{mutation_usage(action)}", 1}

      is_nil(opts[:tenant]) ->
        {:error, "Error: --tenant is required\n#{mutation_usage(action)}", 1}

      action != :grant and opts[:routing_policy_id] ->
        {:error, "Error: --routing-policy-id is only valid for grant\n#{mutation_usage(action)}",
         1}

      true ->
        {:ok, hd(positional), opts}
    end
  end

  defp parse_tenant_only(args, usage) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: [tenant: :string])

    cond do
      invalid != [] or positional != [] -> {:error, "Error: invalid arguments\n#{usage}", 1}
      is_nil(opts[:tenant]) -> {:error, "Error: --tenant is required\n#{usage}", 1}
      true -> {:ok, opts[:tenant]}
    end
  end

  defp resolve_policy_id(nil, :grant), do: {:ok, nil}
  defp resolve_policy_id(_policy_id, action) when action != :grant, do: {:ok, nil}

  defp resolve_policy_id(policy_id, :grant) do
    case Reference.resolve_policy(policy_id) do
      {:ok, policy} -> {:ok, policy.id}
      {:error, reason} -> {:error, reason}
    end
  end

  defp render_mutation({:ok, result}, action, tenant, model) do
    identity = model_identity(model)
    routing = routing_label(result.access)
    {:ok, mutation_message(action, result.outcome, identity, tenant.slug, routing)}
  end

  defp render_mutation({:error, reason}, _action, _tenant, _model) do
    {:error, "Error: model access mutation failed: #{format_reason(reason)}", 1}
  end

  defp mutation_message(:grant, :created, identity, tenant, routing),
    do: "Granted #{identity} to #{tenant} (routing=#{routing})"

  defp mutation_message(:grant, :enabled, identity, tenant, routing),
    do: "Enabled #{identity} for #{tenant} (routing=#{routing})"

  defp mutation_message(:grant, :policy_changed, identity, tenant, routing),
    do: "Updated #{identity} for #{tenant} (routing=#{routing})"

  defp mutation_message(:grant, :unchanged, identity, tenant, routing),
    do: "Already granted #{identity} to #{tenant} (routing=#{routing})"

  defp mutation_message(:disable, :disabled, identity, tenant, _routing),
    do: "Disabled #{identity} for #{tenant}"

  defp mutation_message(:disable, :already_disabled, identity, tenant, _routing),
    do: "Already disabled #{identity} for #{tenant}"

  defp mutation_message(:disable, :not_granted, identity, tenant, _routing),
    do: "No grant for #{identity} and #{tenant}"

  defp mutation_message(:revoke, :revoked, identity, tenant, _routing),
    do: "Revoked #{identity} from #{tenant}"

  defp mutation_message(:revoke, :not_granted, identity, tenant, _routing),
    do: "No grant for #{identity} and #{tenant}"

  defp render_list(tenant, []), do: {:ok, "No model access records for #{tenant.slug}."}

  defp render_list(tenant, access_rows) do
    lines = Enum.map_join(access_rows, "\n", &render_access(&1, tenant.slug))
    {:ok, lines}
  end

  defp render_access(access, tenant_slug) do
    state = if access.enabled, do: "enabled", else: "disabled"

    "#{model_identity(access.model)}  tenant=#{tenant_slug}  state=#{state}  routing=#{routing_label(access)}"
  end

  defp routing_label(nil), do: "defaults"
  defp routing_label(%{routing_policy_id: nil}), do: "defaults"
  defp routing_label(%{routing_policy_id: policy_id}), do: policy_id

  defp model_identity(model), do: "#{model.model_id}@#{model.version}"

  defp render_reference_error(:tenant_not_found, _identity, opts),
    do: tenant_not_found(opts[:tenant])

  defp render_reference_error(:invalid_model_identity, identity, _opts),
    do: {:error, "Error: invalid model identity: #{identity}", 1}

  defp render_reference_error(:model_not_found, identity, _opts),
    do: {:error, "Error: model not found: #{identity}", 1}

  defp render_reference_error(:routing_policy_not_found, _identity, opts),
    do: {:error, "Error: routing policy not found: #{opts[:routing_policy_id]}", 1}

  defp render_reference_error(reason, _identity, _opts),
    do: {:error, "Error: #{format_reason(reason)}", 1}

  defp tenant_not_found(reference), do: {:error, "Error: tenant not found: #{reference}", 1}
  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_reason(reason), do: inspect(reason)

  defp usage do
    Enum.join(
      [
        mutation_usage(:grant),
        mutation_usage(:disable),
        mutation_usage(:revoke),
        list_usage(),
        mutation_usage(:inspect)
      ],
      "\n"
    )
  end

  defp mutation_usage(:grant),
    do:
      "Usage: orchardctl models access grant <model_id@version> --tenant <uuid-or-slug> [--routing-policy-id <uuid>]"

  defp mutation_usage(:disable),
    do: "Usage: orchardctl models access disable <model_id@version> --tenant <uuid-or-slug>"

  defp mutation_usage(:revoke),
    do: "Usage: orchardctl models access revoke <model_id@version> --tenant <uuid-or-slug>"

  defp mutation_usage(:inspect),
    do: "Usage: orchardctl models access inspect <model_id@version> --tenant <uuid-or-slug>"

  defp list_usage,
    do: "Usage: orchardctl models access list --tenant <uuid-or-slug>"
end
