defmodule OrchardCLI.Commands.Nodes do
  @moduledoc """
  CLI handler for `orchardctl nodes` commands.
  """

  alias Orchard.API.Admin.NodeAdmissionPresenter
  alias Orchard.ClusterManagement.{ActionPreview, ActionPreviewBuilder, NodeStatus, StatusBuilder}
  alias Orchard.ControlPlane
  alias Orchard.Nodes
  alias Orchard.Nodes.AdmissionCandidate

  @spec run([String.t()]) :: OrchardCLI.command_result()
  def run(args) do
    case args do
      ["list"] -> run_list()
      ["list", "--json"] -> run_list_json()
      ["list", "--help"] -> {:ok, list_usage()}
      ["help"] -> {:ok, group_usage()}
      ["--help"] -> {:ok, group_usage()}
      [] -> {:error, group_usage(), 1}
      [command | rest] -> run_command(command, rest)
    end
  end

  defp run_command("inspect", rest), do: run_inspect(rest)
  defp run_command("pending", rest), do: run_pending(rest)
  defp run_command("admit", rest), do: run_admit(rest)
  defp run_command("reject", rest), do: run_reject(rest)
  defp run_command(_command, _rest), do: {:error, group_usage(), 1}

  defp run_inspect(["--help"]), do: {:ok, inspect_usage()}
  defp run_inspect(["help"]), do: {:ok, inspect_usage()}

  defp run_inspect(args) do
    with {:ok, %{id: node_id, json?: json?}} <- parse_inspect_args(args),
         {:ok, node} <- Nodes.fetch_node(node_id) do
      output = NodeAdmissionPresenter.node(node)
      {:ok, render_node(output, json?)}
    else
      {:error, :node_not_found} -> {:error, "Error: node not found.", 1}
      {:error, message, code} -> {:error, message, code}
    end
  end

  defp run_pending(["--help"]), do: {:ok, pending_usage()}
  defp run_pending(["help"]), do: {:ok, pending_usage()}

  defp run_pending(args) do
    with {:ok, %{json?: json?}} <- parse_pending_args(args) do
      candidates =
        Nodes.list_admission_candidates(
          admission_category: AdmissionCandidate.review_categories()
        )

      output = NodeAdmissionPresenter.list_candidates(candidates)
      {:ok, render_pending(output, json?)}
    end
  end

  defp run_admit(["--help"]), do: {:ok, admit_usage()}
  defp run_admit(["help"]), do: {:ok, admit_usage()}

  defp run_admit(args) do
    with {:ok, opts} <- parse_admit_args(args) do
      preview = ActionPreviewBuilder.admit_node(opts.id, opts.attrs)

      cond do
        opts.dry_run? ->
          {:ok, render_preview(preview, opts.json?)}

        preview_blocked?(preview) or not opts.yes? ->
          confirmation_error(preview, opts, :admit)

        true ->
          execute_admit(opts)
      end
    end
  end

  defp run_reject(["--help"]), do: {:ok, reject_usage()}
  defp run_reject(["help"]), do: {:ok, reject_usage()}

  defp run_reject(args) do
    with {:ok, opts} <- parse_reject_args(args) do
      preview = ActionPreviewBuilder.reject_admission(opts.id, opts.attrs)

      cond do
        opts.dry_run? ->
          {:ok, render_preview(preview, opts.json?)}

        preview_blocked?(preview) or not opts.yes? or reason_missing?(opts.attrs) ->
          confirmation_error(preview, opts, :reject)

        true ->
          execute_reject(opts)
      end
    end
  end

  defp execute_admit(opts) do
    with :ok <- ControlPlane.authorize_write_path(:node_admission),
         {:ok, result} <- Nodes.admit_node(opts.id, opts.attrs) do
      output = NodeAdmissionPresenter.admit_result(result)
      {:ok, render_action_result(output, opts.json?)}
    else
      {:error, reason} -> action_error(reason, opts.json?)
    end
  end

  defp execute_reject(opts) do
    with :ok <- ControlPlane.authorize_write_path(:node_admission),
         {:ok, result} <- Nodes.reject_admission(opts.id, opts.attrs) do
      output = NodeAdmissionPresenter.reject_result(result)
      {:ok, render_action_result(output, opts.json?)}
    else
      {:error, reason} -> action_error(reason, opts.json?)
    end
  end

  defp parse_inspect_args(args) do
    case OptionParser.parse(args, strict: [json: :boolean, help: :boolean]) do
      {opts, [node_id], []} ->
        if Keyword.get(opts, :help, false) do
          {:error, inspect_usage(), 0}
        else
          {:ok, %{id: node_id, json?: Keyword.get(opts, :json, false)}}
        end

      {_opts, _rest, [{flag, _value} | _unknown]} ->
        unknown_option(flag)

      _other ->
        {:error, inspect_usage(), 1}
    end
  end

  defp parse_pending_args(args) do
    case OptionParser.parse(args, strict: [json: :boolean, help: :boolean]) do
      {opts, [], []} ->
        if Keyword.get(opts, :help, false) do
          {:error, pending_usage(), 0}
        else
          {:ok, %{json?: Keyword.get(opts, :json, false)}}
        end

      {_opts, _rest, [{flag, _value} | _unknown]} ->
        unknown_option(flag)

      _other ->
        {:error, pending_usage(), 1}
    end
  end

  defp parse_admit_args(args) do
    case OptionParser.parse(args, strict: admit_switches()) do
      {opts, [node_id], []} ->
        if Keyword.get(opts, :help, false) do
          {:error, admit_usage(), 0}
        else
          {:ok,
           %{
             id: node_id,
             json?: Keyword.get(opts, :json, false),
             dry_run?: Keyword.get(opts, :dry_run, false),
             yes?: Keyword.get(opts, :yes, false),
             attrs: admission_attrs(opts)
           }}
        end

      {_opts, _rest, [{flag, _value} | _unknown]} ->
        unknown_option(flag)

      _other ->
        {:error, admit_usage(), 1}
    end
  end

  defp parse_reject_args(args) do
    case OptionParser.parse(args, strict: reject_switches()) do
      {opts, [target_id], []} ->
        if Keyword.get(opts, :help, false) do
          {:error, reject_usage(), 0}
        else
          {:ok,
           %{
             id: target_id,
             json?: Keyword.get(opts, :json, false),
             dry_run?: Keyword.get(opts, :dry_run, false),
             yes?: Keyword.get(opts, :yes, false),
             attrs: reject_attrs(opts)
           }}
        end

      {_opts, _rest, [{flag, _value} | _unknown]} ->
        unknown_option(flag)

      _other ->
        {:error, reject_usage(), 1}
    end
  end

  defp admit_switches do
    [
      dry_run: :boolean,
      help: :boolean,
      json: :boolean,
      pool: :string,
      pool_id: :string,
      policy_ref: :string,
      routing_policy_id: :string,
      trust_evidence_ref: :string,
      trust_ref: :string,
      yes: :boolean
    ]
  end

  defp reject_switches do
    [
      dry_run: :boolean,
      help: :boolean,
      json: :boolean,
      reason: :string,
      yes: :boolean
    ]
  end

  defp admission_attrs(opts) do
    %{}
    |> put_opt(opts, :trust_evidence_ref)
    |> put_opt(opts, :trust_ref)
    |> put_opt(opts, :pool_id)
    |> put_opt(opts, :pool)
    |> put_opt(opts, :routing_policy_id)
    |> put_opt(opts, :policy_ref)
  end

  defp reject_attrs(opts), do: put_opt(%{}, opts, :reason)

  defp put_opt(attrs, opts, key) do
    case Keyword.get(opts, key) do
      nil -> attrs
      value -> Map.put(attrs, Atom.to_string(key), value)
    end
  end

  defp unknown_option(flag), do: {:error, "Unknown option: #{flag}", 2}

  defp confirmation_error(%ActionPreview{} = preview, %{json?: true}, _action) do
    {:error, render_preview(preview, true), 2}
  end

  defp confirmation_error(%ActionPreview{} = preview, opts, action) do
    message = confirmation_message(preview, opts, action)
    {:error, message <> "\n\n" <> render_preview(preview, false), 2}
  end

  defp confirmation_message(preview, opts, action) do
    cond do
      preview_blocked?(preview) ->
        "Error: #{action_name(action)} cannot execute because preview blockers are present."

      not opts.yes? ->
        "Error: #{action_name(action)} requires --yes before execution."

      true ->
        "Error: #{action_name(action)} requires a nonblank --reason before execution."
    end
  end

  defp action_name(:admit), do: "node admission"
  defp action_name(:reject), do: "node admission rejection"

  defp action_error(reason, true) when is_atom(reason) do
    {:error, Jason.encode!(%{object: "error", code: Atom.to_string(reason)}, pretty: true), 1}
  end

  defp action_error(_reason, true) do
    {:error, Jason.encode!(%{object: "error", code: "action_failed"}, pretty: true), 1}
  end

  defp action_error(reason, false) when is_atom(reason),
    do: {:error, "Error: #{human_reason(reason)}", 1}

  defp action_error(_reason, false),
    do: {:error, "Error: the admission action could not be completed.", 1}

  defp human_reason(:admission_not_pending), do: "admission is not pending."
  defp human_reason(:admission_rejected), do: "admission rejection must be cleared first."
  defp human_reason(:controller_standby), do: "this controller is in standby mode."
  defp human_reason(:inventory_missing), do: "registered node inventory is missing."
  defp human_reason(:node_not_found), do: "node was not found."
  defp human_reason(:node_not_pending_admission), do: "node is not pending admission."
  defp human_reason(:node_not_registered), do: "node is not registered."
  defp human_reason(:policy_required), do: "required policy inputs are missing."
  defp human_reason(:pool_required), do: "node pool assignment is required."
  defp human_reason(:reason_required), do: "a nonblank rejection reason is required."
  defp human_reason(:trust_not_established), do: "node trust evidence is required."
  defp human_reason(reason), do: "#{reason}."

  defp preview_blocked?(%ActionPreview{blockers: blockers}), do: blockers != []

  defp reason_missing?(attrs) do
    case Map.get(attrs, "reason") do
      reason when is_binary(reason) -> String.trim(reason) == ""
      _other -> true
    end
  end

  defp render_node(node, true), do: encode_json(node)

  defp render_node(node, false) do
    status = node.status

    Enum.join(
      [
        "Node #{node.id}",
        "Display name: #{node.display_name}",
        "Hostname: #{node.hostname}",
        "State: #{node.state}",
        "Health: #{node.health}",
        "Admission: #{get_in(status, [:admission, :category])}",
        "Scheduling: #{format_scheduling(get_in(status, [:scheduling]))}"
      ],
      "\n"
    )
  end

  defp render_pending(%{data: []}, false), do: "No admission candidates pending review."
  defp render_pending(output, true), do: encode_json(pending_payload(output))

  defp render_pending(output, false) do
    output.data
    |> Enum.map_join("\n", fn candidate ->
      status = candidate.status

      "#{candidate.id}  #{candidate.admission_category}  #{candidate.target_ref || "-"}  " <>
        "#{format_scheduling(get_in(status, [:scheduling]))}"
    end)
  end

  defp pending_payload(output) do
    %{
      object: "cluster_management.node_admission_review",
      contract_version: NodeStatus.contract_version(),
      data: output.data
    }
  end

  defp render_preview(%ActionPreview{} = preview, true) do
    preview
    |> ActionPreview.to_map()
    |> encode_json()
  end

  defp render_preview(%ActionPreview{} = preview, false) do
    map = ActionPreview.to_map(preview)

    Enum.join(
      [
        "Action: #{map.action}",
        "Target: #{get_in(map, [:target, :type])}:#{get_in(map, [:target, :id])}",
        "Blockers: #{format_codes(map.blockers, :code)}",
        "Confirmation requirements: #{format_codes(map.confirmation_requirements)}",
        "Expected transition: #{get_in(map, [:expected_transition, :from]) || "-"} -> #{get_in(map, [:expected_transition, :to]) || "-"}"
      ],
      "\n"
    )
  end

  defp render_action_result(output, true), do: encode_json(output)

  defp render_action_result(%{action: "node_admission.admitted", node: node}, false) do
    "Admitted node #{node.id}. State: #{node.state}."
  end

  defp render_action_result(%{action: "node_admission.rejected", candidate: candidate}, false) do
    "Rejected admission candidate #{candidate.id}."
  end

  defp encode_json(payload), do: Jason.encode!(payload, pretty: true)

  defp format_scheduling(nil), do: "unknown"

  defp format_scheduling(%{eligible: true}), do: "eligible"

  defp format_scheduling(%{reason_codes: codes}) do
    "blocked (#{Enum.join(codes, ", ")})"
  end

  defp format_codes([], _key), do: "none"

  defp format_codes(values, key) do
    Enum.map_join(values, ", ", &Map.fetch!(&1, key))
  end

  defp format_codes([]), do: "none"
  defp format_codes(values), do: Enum.join(values, ", ")

  # NOTE: list_nodes/0 and summary/0 gracefully degrade to []/zero when the
  # repo is unavailable. The CLI cannot distinguish "no nodes" from "DB down".
  # This is consistent with the console and health endpoint behavior.
  defp run_list do
    nodes = Nodes.list_nodes()
    summary = Nodes.summary()

    summary_line = format_summary(summary)

    if nodes == [] do
      {:ok, summary_line <> "\n\nNo nodes registered."}
    else
      table = format_table(nodes)
      {:ok, summary_line <> "\n\n" <> table}
    end
  end

  defp run_list_json do
    nodes = Nodes.list_nodes()

    payload = %{
      object: "cluster_management.node_status_list",
      contract_version: NodeStatus.contract_version(),
      data: StatusBuilder.node_status_maps(nodes),
      summary: Nodes.summary()
    }

    {:ok, encode_json(payload)}
  end

  defp format_summary(summary) do
    by_health = summary.by_health

    "Summary: " <>
      "total=#{summary.total} " <>
      "healthy=#{by_health[:healthy] || 0} " <>
      "degraded=#{by_health[:degraded] || 0} " <>
      "unhealthy=#{by_health[:unhealthy] || 0} " <>
      "unreachable=#{by_health[:unreachable] || 0}"
  end

  @columns [
    {:id, "NODE ID"},
    {:display_name, "DISPLAY NAME"},
    {:hostname, "HOSTNAME"},
    {:state, "STATE"},
    {:health, "HEALTH"},
    {:last_heartbeat_at, "LAST SEEN"},
    {:agent_version, "AGENT VERSION"}
  ]

  defp format_table(nodes) do
    rows = Enum.map(nodes, &format_row/1)
    headers = Enum.map(@columns, fn {_key, header} -> header end)
    all_rows = [headers | rows]

    widths =
      Enum.map(0..(length(headers) - 1), fn col_idx ->
        all_rows
        |> Enum.map(&Enum.at(&1, col_idx))
        |> Enum.map(&String.length/1)
        |> Enum.max()
      end)

    header_line = format_row_cells(headers, widths)
    separator = Enum.map_join(widths, "  ", &String.duplicate("-", &1))
    data_lines = Enum.map_join(rows, "\n", &format_row_cells(&1, widths))

    header_line <> "\n" <> separator <> "\n" <> data_lines
  end

  defp format_row(node) do
    Enum.map(@columns, fn {key, _header} -> format_field(key, node) end)
  end

  defp format_field(:id, node), do: to_string(node.id)
  defp format_field(:display_name, node), do: to_string(node.display_name)
  defp format_field(:hostname, node), do: to_string(node.hostname)
  defp format_field(:state, node), do: to_string(node.state)
  defp format_field(:health, node), do: to_string(node.health)

  defp format_field(:last_heartbeat_at, node) do
    case node.last_heartbeat_at do
      nil -> "-"
      %DateTime{} = dt -> DateTime.to_iso8601(dt)
    end
  end

  defp format_field(:agent_version, node), do: node.agent_version || "-"

  defp format_row_cells(cells, widths) do
    cells
    |> Enum.zip(widths)
    |> Enum.map_join("  ", fn {cell, width} -> String.pad_trailing(cell, width) end)
  end

  defp group_usage do
    Enum.join(
      [
        "Usage: orchardctl nodes <command>",
        "",
        "Commands:",
        "  list     List registered nodes",
        "  inspect  Inspect one node",
        "  pending  Review pending or rejected node admission candidates",
        "  admit    Admit a registered pending node into the cluster",
        "  reject   Reject pending node admission"
      ],
      "\n"
    )
  end

  defp list_usage do
    Enum.join(
      [
        "Usage: orchardctl nodes list [--json]",
        "",
        "Lists all registered nodes with state, health, and agent version."
      ],
      "\n"
    )
  end

  defp inspect_usage do
    Enum.join(
      [
        "Usage: orchardctl nodes inspect <node-id> [--json]",
        "",
        "Shows one node with shared cluster-management status categories."
      ],
      "\n"
    )
  end

  defp pending_usage do
    Enum.join(
      [
        "Usage: orchardctl nodes pending [--json]",
        "",
        "Lists admission candidates pending review or rejected for review follow-up."
      ],
      "\n"
    )
  end

  defp admit_usage do
    Enum.join(
      [
        "Usage: orchardctl nodes admit <node-id> [--dry-run] [--json] [--yes] --trust-evidence-ref REF --pool-id ID --routing-policy-id ID",
        "",
        "Previews or admits a registered pending node.",
        "Execution requires --yes and a preview with no blockers."
      ],
      "\n"
    )
  end

  defp reject_usage do
    Enum.join(
      [
        "Usage: orchardctl nodes reject <node-id|candidate-id> [--dry-run] [--json] [--yes] --reason REASON",
        "",
        "Previews or rejects pending node admission.",
        "Execution requires --yes, --reason, and a preview with no blockers."
      ],
      "\n"
    )
  end
end
