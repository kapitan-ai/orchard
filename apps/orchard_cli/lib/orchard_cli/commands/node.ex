defmodule OrchardCLI.Commands.Node do
  @moduledoc false

  alias OrchardCLI.Commands.NodeJoin

  @spec run([String.t()]) :: OrchardCLI.command_result()
  def run(["join" | args]), do: NodeJoin.run(args)
  def run(["--help"]), do: {:ok, usage()}
  def run(["help"]), do: {:ok, usage()}
  def run(_args), do: {:error, usage(), 1}

  defp usage do
    """
    Usage: orchardctl node <command>

    Commands:
      join  Join this Node with a versioned Node Enrollment Bundle
    """
    |> String.trim()
  end
end
