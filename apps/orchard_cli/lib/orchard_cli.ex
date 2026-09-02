defmodule OrchardCLI do
  @moduledoc """
  Dispatches `orchardctl` commands for source and packaged Orchard operators.
  """

  alias OrchardCLI.Commands.{
    ApiClients,
    ApiKeys,
    Cluster,
    Console,
    Env,
    Init,
    Migrate,
    Models,
    Node,
    Nodes,
    Requests,
    Start,
    Status,
    Stop,
    Tenants,
    TLS,
    Transport,
    Upgrade
  }

  @type command_result :: :ok | {:ok, String.t()} | {:error, String.t(), pos_integer()}

  @spec main([String.t()]) :: :ok | no_return()
  def main(args), do: main(args, &System.halt/1)

  @doc false
  @spec main([String.t()], (non_neg_integer() -> any())) :: :ok
  def main(args, halt_fn) do
    args
    |> dispatch_command()
    |> handle_result(halt_fn)
  end

  defp dispatch_command(["status" | rest]), do: Status.run(rest)
  defp dispatch_command(["start" | rest]), do: Start.run(rest)
  defp dispatch_command(["stop" | rest]), do: Stop.run(rest)
  defp dispatch_command(["init" | rest]), do: Init.run(rest)
  defp dispatch_command(["first-run" | rest]), do: Init.run(rest)
  defp dispatch_command(["migrate" | rest]), do: Migrate.run(rest)
  defp dispatch_command(["console" | rest]), do: Console.run(rest)
  defp dispatch_command(["cluster" | rest]), do: Cluster.run(rest)
  defp dispatch_command(["env" | rest]), do: Env.run(rest)
  defp dispatch_command(["node" | rest]), do: Node.run(rest)
  defp dispatch_command(["nodes" | rest]), do: Nodes.run(rest)
  defp dispatch_command(["models" | rest]), do: Models.run(rest)
  defp dispatch_command(["requests" | rest]), do: Requests.run(rest)
  defp dispatch_command(["tenants" | rest]), do: Tenants.run(rest)
  defp dispatch_command(["api-clients" | rest]), do: ApiClients.run(rest)
  defp dispatch_command(["api-keys" | rest]), do: ApiKeys.run(rest)
  defp dispatch_command(["tls" | rest]), do: TLS.run(rest)
  defp dispatch_command(["transport" | rest]), do: Transport.run(rest)
  defp dispatch_command(["upgrade" | rest]), do: Upgrade.run(rest)
  defp dispatch_command([]), do: print_usage()
  defp dispatch_command(["help" | _rest]), do: print_usage()
  defp dispatch_command(["--help" | _rest]), do: print_usage()
  defp dispatch_command(["-h" | _rest]), do: print_usage()
  defp dispatch_command(_args), do: {:error, usage(), 1}

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
    IO.puts(usage())
  end

  defp usage do
    "orchardctl\nAvailable commands: status, start, stop, init, first-run, migrate, console, cluster, env, node, nodes, models, requests, tenants, api-clients, api-keys, tls, transport, upgrade"
  end
end
