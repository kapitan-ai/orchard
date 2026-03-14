defmodule OrchardCLI do
  @moduledoc """
  Placeholder `orchardctl` entrypoint for Milestone 0.
  """

  alias OrchardCLI.Commands.{Cluster, Models, Nodes, Requests, Support, TLS, Upgrade}

  @type command_result :: :ok | {:ok, String.t()} | {:error, String.t(), pos_integer()}

  @spec main([String.t()]) :: :ok | no_return()
  def main(args), do: main(args, &System.halt/1)

  @doc false
  @spec main([String.t()], (non_neg_integer() -> any())) :: :ok
  def main(args, halt_fn) do
    result =
      case args do
        ["cluster" | rest] -> Cluster.run(rest)
        ["nodes" | rest] -> Nodes.run(rest)
        ["models" | rest] -> Models.run(rest)
        ["requests" | rest] -> Requests.run(rest)
        ["support" | rest] -> Support.run(rest)
        ["tls" | rest] -> TLS.run(rest)
        ["upgrade" | rest] -> Upgrade.run(rest)
        _ -> print_usage()
      end

    handle_result(result, halt_fn)
  end

  defp handle_result(:ok, _halt_fn), do: :ok

  defp handle_result({:ok, message}, _halt_fn) do
    IO.puts(message)
    :ok
  end

  defp handle_result({:error, message, exit_code}, halt_fn) do
    IO.puts(:stderr, message)
    halt_fn.(exit_code)
    :ok
  end

  defp print_usage do
    IO.puts("orchardctl (M0 scaffold)")
    IO.puts("Available command groups: cluster, nodes, models, requests, support, tls, upgrade")
  end
end
