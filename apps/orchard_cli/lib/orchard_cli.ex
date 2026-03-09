defmodule OrchardCLI do
  @moduledoc """
  Placeholder `orchardctl` entrypoint for Milestone 0.
  """

  alias OrchardCLI.Commands.{Cluster, Models, Nodes, Requests, Support, Upgrade}

  @spec main([String.t()]) :: :ok
  def main(args) do
    case args do
      ["cluster" | rest] -> Cluster.run(rest)
      ["nodes" | rest] -> Nodes.run(rest)
      ["models" | rest] -> Models.run(rest)
      ["requests" | rest] -> Requests.run(rest)
      ["support" | rest] -> Support.run(rest)
      ["upgrade" | rest] -> Upgrade.run(rest)
      _ -> print_usage()
    end

    :ok
  end

  defp print_usage do
    IO.puts("orchardctl (M0 scaffold)")
    IO.puts("Available command groups: cluster, nodes, models, requests, support, upgrade")
  end
end
