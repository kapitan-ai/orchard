defmodule OrchardCLI.Commands.Nodes do
  @moduledoc """
  CLI handler for `orchardctl nodes` commands.

  Supports:
    orchardctl nodes list
  """

  alias Orchard.Nodes
  alias OrchardCLI.Commands.Deferred

  @deferred_commands [
    %{
      path: ["admit"],
      usage: "orchardctl nodes admit",
      summary: "Admit a pending node into the cluster (SPEC.md 11.9).",
      status:
        "Defined by SPEC.md 11.9 for node lifecycle work; not implemented in the current build.",
      guidance: [
        "Use orchardctl nodes list to inspect registered nodes that already report to the controller.",
        "For current source-dev multi-node testing, configure ORCHARD_RUNTIME_CLIENT_TARGETS as documented in docs/local-dev.md."
      ]
    }
  ]

  @spec run([String.t()]) :: OrchardCLI.command_result()
  def run(args) do
    case args do
      ["list"] -> run_list()
      ["list", "--help"] -> {:ok, list_usage()}
      ["admit" | rest] -> Deferred.run(["admit" | rest], deferred_spec())
      ["help"] -> {:ok, group_usage()}
      ["--help"] -> {:ok, group_usage()}
      [] -> {:error, group_usage(), 1}
      _ -> {:error, group_usage(), 1}
    end
  end

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

  # ---------------------------------------------------------------------------
  # Summary formatting
  # ---------------------------------------------------------------------------

  defp format_summary(summary) do
    by_health = summary.by_health

    "Summary: " <>
      "total=#{summary.total} " <>
      "healthy=#{by_health[:healthy] || 0} " <>
      "degraded=#{by_health[:degraded] || 0} " <>
      "unhealthy=#{by_health[:unhealthy] || 0} " <>
      "unreachable=#{by_health[:unreachable] || 0}"
  end

  # ---------------------------------------------------------------------------
  # Table formatting
  # ---------------------------------------------------------------------------

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

    # Compute column widths
    all_rows = [headers | rows]

    widths =
      Enum.map(0..(length(headers) - 1), fn col_idx ->
        all_rows
        |> Enum.map(&Enum.at(&1, col_idx))
        |> Enum.map(&String.length/1)
        |> Enum.max()
      end)

    # Render
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
      nil -> "—"
      %DateTime{} = dt -> DateTime.to_iso8601(dt)
    end
  end

  defp format_field(:agent_version, node) do
    node.agent_version || "—"
  end

  defp format_row_cells(cells, widths) do
    cells
    |> Enum.zip(widths)
    |> Enum.map_join("  ", fn {cell, width} -> String.pad_trailing(cell, width) end)
  end

  # ---------------------------------------------------------------------------
  # Usage
  # ---------------------------------------------------------------------------

  defp group_usage do
    Enum.join(
      [
        "Usage: orchardctl nodes <command>",
        "",
        "Commands:",
        "  list   List registered nodes",
        "  admit  Admit a pending node into the cluster (SPEC.md 11.9; not implemented)"
      ],
      "\n"
    )
  end

  defp deferred_spec, do: %{name: "nodes", commands: @deferred_commands}

  defp list_usage do
    Enum.join(
      [
        "Usage: orchardctl nodes list",
        "",
        "Lists all registered nodes with state, health, and agent version."
      ],
      "\n"
    )
  end
end
