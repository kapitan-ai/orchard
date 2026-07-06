defmodule OrchardCLI.Commands.Nodes do
  @moduledoc """
  CLI handler for `orchardctl nodes` commands.
  """

  alias Orchard.API.Admin.NodeAdmissionPresenter

  alias Orchard.ClusterManagement.{
    ActionPreview,
    ActionPreviewBuilder,
    MemoryBudgetPresenter,
    NodeStatus,
    StatusBuilder
  }

  alias Orchard.ControlPlane
  alias Orchard.Nodes
  alias Orchard.Nodes.AdmissionCandidate
  alias Orchard.Nodes.Lifecycle

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

  defp run_command(command, rest) do
    case lifecycle_command_action(command) do
      {:ok, action} -> run_lifecycle(action, rest)
      :error -> {:error, group_usage(), 1}
    end
  end

  defp run_inspect(["--help"]), do: {:ok, inspect_usage()}
  defp run_inspect(["help"]), do: {:ok, inspect_usage()}

  defp run_inspect(args) do
    with {:ok, %{id: node_id, json?: json?}} <- parse_inspect_args(args),
         {:ok, node} <- guarded_fetch_node(node_id) do
      output = node |> NodeAdmissionPresenter.node() |> with_memory_budget()
      {:ok, render_node(output, json?)}
    else
      {:error, :node_not_found} -> {:error, "Error: node not found.", 1}
      {:help, usage} -> {:ok, usage}
      {:error, message, code} -> {:error, message, code}
    end
  end

  defp run_pending(["--help"]), do: {:ok, pending_usage()}
  defp run_pending(["help"]), do: {:ok, pending_usage()}

  defp run_pending(args) do
    case parse_pending_args(args) do
      {:ok, %{json?: json?}} ->
        output = NodeAdmissionPresenter.list_candidates(guarded_pending_candidates())
        {:ok, render_pending(output, json?)}

      {:help, usage} ->
        {:ok, usage}

      {:error, message, code} ->
        {:error, message, code}
    end
  end

  defp run_admit(["--help"]), do: {:ok, admit_usage()}
  defp run_admit(["help"]), do: {:ok, admit_usage()}

  defp run_admit(args) do
    case parse_admit_args(args) do
      {:ok, %{dry_run?: true} = opts} ->
        preview =
          guarded_preview(
            fn -> ActionPreviewBuilder.admit_node(opts.id, opts.attrs) end,
            :admit,
            opts.id
          )

        {:ok, render_preview(preview, opts.json?)}

      {:ok, opts} ->
        preview = ActionPreviewBuilder.admit_node(opts.id, opts.attrs)

        if preview_blocked?(preview) or not opts.yes? do
          confirmation_error(preview, opts, :admit)
        else
          execute_admit(opts)
        end

      {:help, usage} ->
        {:ok, usage}

      {:error, message, code} ->
        {:error, message, code}
    end
  end

  defp run_reject(["--help"]), do: {:ok, reject_usage()}
  defp run_reject(["help"]), do: {:ok, reject_usage()}

  defp run_reject(args) do
    case parse_reject_args(args) do
      {:ok, %{dry_run?: true} = opts} ->
        preview =
          guarded_preview(
            fn -> ActionPreviewBuilder.reject_admission(opts.id, opts.attrs) end,
            :reject,
            opts.id
          )

        {:ok, render_preview(preview, opts.json?)}

      {:ok, opts} ->
        preview = ActionPreviewBuilder.reject_admission(opts.id, opts.attrs)

        if preview_blocked?(preview) or not opts.yes? or reason_missing?(opts.attrs) do
          confirmation_error(preview, opts, :reject)
        else
          execute_reject(opts)
        end

      {:help, usage} ->
        {:ok, usage}

      {:error, message, code} ->
        {:error, message, code}
    end
  end

  defp run_lifecycle(action, ["--help"]), do: {:ok, lifecycle_usage(action)}
  defp run_lifecycle(action, ["help"]), do: {:ok, lifecycle_usage(action)}

  defp run_lifecycle(action, args) do
    case parse_lifecycle_args(action, args) do
      {:ok, %{dry_run?: true} = opts} ->
        preview =
          guarded_preview(
            fn -> ActionPreviewBuilder.node_lifecycle(action, opts.id, opts.attrs) end,
            action,
            opts.id
          )

        {:ok, render_preview(preview, opts.json?)}

      {:ok, opts} ->
        preview = ActionPreviewBuilder.node_lifecycle(action, opts.id, opts.attrs)

        case lifecycle_confirmation_error(preview, opts) do
          nil -> execute_lifecycle(opts)
          message -> confirmation_error(preview, opts, action, message)
        end

      {:help, usage} ->
        {:ok, usage}

      {:error, message, code} ->
        {:error, message, code}
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

  defp execute_lifecycle(opts) do
    with :ok <- ControlPlane.authorize_write_path(:node_lifecycle),
         {:ok, result} <- Lifecycle.execute(opts.action, opts.id, opts.attrs) do
      output =
        NodeAdmissionPresenter.lifecycle_result(Lifecycle.audit_action(opts.action), result)

      {:ok, render_action_result(output, opts.json?)}
    else
      {:error, reason} -> action_error(reason, opts.json?)
    end
  end

  defp guarded_fetch_node(node_id) do
    guarded_read(fn -> Nodes.fetch_node(node_id) end, {:error, :node_not_found})
  end

  defp guarded_pending_candidates do
    guarded_read(
      fn ->
        Nodes.list_admission_candidates(
          admission_category: AdmissionCandidate.review_categories()
        )
      end,
      []
    )
  end

  defp guarded_preview(build_fun, action, target_id) do
    guarded_read(build_fun, ActionPreviewBuilder.not_found_preview(action, target_id))
  end

  defp guarded_read(fun, fallback) do
    if repo_available?() do
      fun.()
    else
      fallback
    end
  rescue
    _exception in [DBConnection.ConnectionError, DBConnection.OwnershipError, Postgrex.Error] ->
      fallback
  end

  defp repo_available? do
    pid = Process.whereis(Orchard.Repo)
    is_pid(pid) and Process.alive?(pid)
  end

  defp parse_inspect_args(args) do
    case OptionParser.parse(args, strict: [json: :boolean, help: :boolean]) do
      {opts, [node_id], []} ->
        if Keyword.get(opts, :help, false) do
          {:help, inspect_usage()}
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
          {:help, pending_usage()}
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
          {:help, admit_usage()}
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
          {:help, reject_usage()}
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

  defp parse_lifecycle_args(action, args) do
    case OptionParser.parse(args, strict: lifecycle_switches()) do
      {opts, [node_id], []} ->
        if Keyword.get(opts, :help, false) do
          {:help, lifecycle_usage(action)}
        else
          {:ok,
           %{
             action: action,
             id: node_id,
             json?: Keyword.get(opts, :json, false),
             dry_run?: Keyword.get(opts, :dry_run, false),
             yes?: Keyword.get(opts, :yes, false),
             acknowledge?: Keyword.get(opts, :acknowledge, false),
             typed_node_id: Keyword.get(opts, :typed_node_id),
             attrs: lifecycle_attrs(opts)
           }}
        end

      {_opts, _rest, [{flag, _value} | _unknown]} ->
        unknown_option(flag)

      _other ->
        {:error, lifecycle_usage(action), 1}
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

  defp lifecycle_switches do
    [
      acknowledge: :boolean,
      dry_run: :boolean,
      help: :boolean,
      json: :boolean,
      reason: :string,
      typed_node_id: :string,
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

  defp lifecycle_attrs(opts), do: put_opt(%{}, opts, :reason)

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

  defp confirmation_error(%ActionPreview{} = preview, %{json?: true}, _action, _message) do
    {:error, render_preview(preview, true), 2}
  end

  defp confirmation_error(%ActionPreview{} = preview, _opts, _action, message) do
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

  defp lifecycle_confirmation_error(%ActionPreview{} = preview, opts) do
    if preview_blocked?(preview) do
      "Error: #{action_name(opts.action)} cannot execute because preview blockers are present."
    else
      Enum.find_value(preview.confirmation_requirements, &lifecycle_requirement_error(&1, opts))
    end
  end

  defp lifecycle_requirement_error("requires_yes_flag", %{yes?: false} = opts) do
    "Error: #{action_name(opts.action)} requires --yes before execution."
  end

  defp lifecycle_requirement_error("requires_typed_node_id", opts) do
    if opts.typed_node_id == opts.id do
      nil
    else
      "Error: #{action_name(opts.action)} requires --typed-node-id matching the target node id."
    end
  end

  defp lifecycle_requirement_error(requirement, %{acknowledge?: false} = opts)
       when requirement in [
              "requires_drain_consequence_acknowledgement",
              "requires_decommission_consequence_acknowledgement"
            ] do
    "Error: #{action_name(opts.action)} requires --acknowledge before execution."
  end

  defp lifecycle_requirement_error(_requirement, _opts), do: nil

  defp action_name(:admit), do: "node admission"
  defp action_name(:reject), do: "node admission rejection"
  defp action_name(:cordon), do: "node cordon"
  defp action_name(:uncordon), do: "node uncordon"
  defp action_name(:drain), do: "node drain"
  defp action_name(:cancel_drain), do: "node cancel drain"
  defp action_name(:maintenance), do: "node maintenance"
  defp action_name(:resume), do: "node resume"
  defp action_name(:decommission), do: "node decommission"

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

  defp human_reason(:controller_leadership_unproven),
    do: "this controller has not proven local leadership."

  defp human_reason(:decommission_already_running), do: "node decommission is already running."
  defp human_reason(:drain_already_running), do: "node drain is already running."
  defp human_reason(:drain_not_running), do: "node drain is not running."
  defp human_reason(:inventory_missing), do: "registered node inventory is missing."

  defp human_reason(:lifecycle_transition_invalid),
    do: "node lifecycle state does not allow this action."

  defp human_reason(:maintenance_requires_drain), do: "node must be draining before maintenance."

  defp human_reason(:drain_completion_unverified),
    do: "manual maintenance is unavailable until node drain completion can be verified."

  defp human_reason(:node_not_found), do: "node was not found."
  defp human_reason(:node_not_active), do: "node is not active."
  defp human_reason(:node_not_admitted), do: "node is not admitted."
  defp human_reason(:node_not_pending_admission), do: "node is not pending admission."
  defp human_reason(:node_not_registered), do: "node is not registered."
  defp human_reason(:node_unhealthy), do: "node health is unhealthy."
  defp human_reason(:node_unreachable), do: "node is unreachable."
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

    [
      "Node #{node.id}",
      "Display name: #{node.display_name}",
      "Hostname: #{node.hostname}",
      "State: #{node.state}",
      "Health: #{node.health}",
      "Admission: #{get_in(status, [:admission, :category])}",
      "Scheduling: #{format_scheduling(get_in(status, [:scheduling]))}",
      format_memory_budget(node[:memory_budget])
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
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

  defp render_action_result(
         %{
           object: "node_lifecycle_action_result",
           action: action,
           node: node
         },
         false
       ) do
    "#{lifecycle_result_label(action)} node #{node.id}. State: #{node.state}."
  end

  defp with_memory_budget(node) do
    runtime_impl = Application.get_env(:orchard_controller, :console, [])[:runtime_impl]

    case MemoryBudgetPresenter.for_node(node, runtime_impl || OrchardConsole.Runtime) do
      nil -> node
      memory_budget -> Map.put(node, :memory_budget, memory_budget)
    end
  end

  defp format_memory_budget(nil), do: nil

  defp format_memory_budget(%{runtime_memory_budgets: budgets} = memory_budget) do
    rows = Enum.map_join(budgets, "\n", &format_memory_budget_row/1)

    ["Memory budget:\n" <> rows, format_truncation_notice(memory_budget)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp format_memory_budget(_memory_budget), do: nil

  defp format_truncation_notice(%{runtime_memory_budgets_truncated_count: count})
       when is_integer(count) and count > 0 do
    "  Note: #{count} additional memory budget row(s) truncated upstream."
  end

  defp format_truncation_notice(_memory_budget), do: nil

  defp format_memory_budget_row(budget) do
    Enum.join(
      [
        "  Model: #{budget[:model_ref] || "unknown model"}",
        "  Mode: #{budget[:mode] || "unknown"}",
        "  Status: #{format_budget_status(budget)}",
        "  Target working set: #{format_integer_or_unknown(budget[:target_working_set_bytes])}",
        "  Headroom: #{format_headroom(budget)}",
        "  KV cache bytes/token: #{format_integer_or_unknown(budget[:kv_cache_bytes_per_token])}",
        "  Max context tokens: #{format_integer_or_unknown(budget[:max_context_tokens])}",
        "  Recommended context tokens: #{format_integer_or_unknown(budget[:recommended_context_tokens])}"
      ],
      "\n"
    )
  end

  defp format_budget_status(%{status_code: code, status_message: message})
       when is_binary(message) and message != "",
       do: "#{code} (#{message})"

  defp format_budget_status(%{status_code: code}) when is_binary(code), do: code
  defp format_budget_status(_budget), do: "unreported"

  defp format_headroom(%{headroom_available: true}), do: "estimate reported"
  defp format_headroom(_budget), do: "estimate unavailable"

  defp format_integer_or_unknown(value) when is_integer(value) and value > 0,
    do: Integer.to_string(value)

  defp format_integer_or_unknown(_value), do: "unknown"

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

  defp lifecycle_result_label("node_lifecycle.cordoned"), do: "Cordoned"
  defp lifecycle_result_label("node_lifecycle.uncordoned"), do: "Uncordoned"
  defp lifecycle_result_label("node_lifecycle.drain_started"), do: "Started drain for"
  defp lifecycle_result_label("node_lifecycle.drain_cancelled"), do: "Cancelled drain for"
  defp lifecycle_result_label("node_lifecycle.maintenance_entered"), do: "Moved to maintenance"
  defp lifecycle_result_label("node_lifecycle.resumed"), do: "Resumed"

  defp lifecycle_result_label("node_lifecycle.decommission_started"),
    do: "Started decommission for"

  defp lifecycle_result_label(_action), do: "Updated"

  defp lifecycle_command_action("cordon"), do: {:ok, :cordon}
  defp lifecycle_command_action("uncordon"), do: {:ok, :uncordon}
  defp lifecycle_command_action("drain"), do: {:ok, :drain}
  defp lifecycle_command_action("cancel-drain"), do: {:ok, :cancel_drain}
  defp lifecycle_command_action("maintenance"), do: {:ok, :maintenance}
  defp lifecycle_command_action("resume"), do: {:ok, :resume}
  defp lifecycle_command_action("decommission"), do: {:ok, :decommission}
  defp lifecycle_command_action(_command), do: :error

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
        "  reject   Reject pending node admission",
        "  cordon   Stop scheduling new work to an active node",
        "  uncordon Allow scheduling to a cordoned node",
        "  drain    Start draining an active or cordoned node",
        "  cancel-drain Stop an in-progress drain and leave the node cordoned",
        "  maintenance Move a draining node into maintenance",
        "  resume   Resume a maintenance node",
        "  decommission Start decommissioning a node"
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

  defp lifecycle_usage(:cordon) do
    lifecycle_usage("cordon", "Previews or cordons an active node.")
  end

  defp lifecycle_usage(:uncordon) do
    lifecycle_usage("uncordon", "Previews or uncordons a cordoned node.")
  end

  defp lifecycle_usage(:drain) do
    lifecycle_usage(
      "drain",
      "Previews or starts draining an active or cordoned node.",
      "Execution requires --yes, --acknowledge, and a preview with no blockers."
    )
  end

  defp lifecycle_usage(:cancel_drain) do
    lifecycle_usage(
      "cancel-drain",
      "Previews or cancels an in-progress drain and leaves the node cordoned."
    )
  end

  defp lifecycle_usage(:maintenance) do
    lifecycle_usage(
      "maintenance",
      "Previews the draining node maintenance transition.",
      "Execution is deferred until node drain completion can be verified."
    )
  end

  defp lifecycle_usage(:resume) do
    lifecycle_usage("resume", "Previews or resumes a maintenance node.")
  end

  defp lifecycle_usage(:decommission) do
    lifecycle_usage(
      "decommission",
      "Previews or starts decommissioning a node.",
      "Execution requires --yes, --acknowledge, --typed-node-id, and a preview with no blockers."
    )
  end

  defp lifecycle_usage(
         command,
         summary,
         execution_line \\ "Execution requires --yes and a preview with no blockers."
       ) do
    Enum.join(
      [
        "Usage: orchardctl nodes #{command} <node-id> [--dry-run] [--json] [--yes] [--reason REASON] [--acknowledge] [--typed-node-id NODE_ID]",
        "",
        summary,
        execution_line
      ],
      "\n"
    )
  end
end
