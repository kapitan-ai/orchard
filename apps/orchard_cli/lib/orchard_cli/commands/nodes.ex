defmodule OrchardCLI.Commands.Nodes do
  @moduledoc """
  CLI handler for `orchardctl nodes` commands.
  """

  alias Orchard.PackagedNodeCommand
  alias OrchardCLI.Commands.NodeEnrollment
  alias OrchardCLI.Commands.NodeTrust, as: NodeTrustCommand
  alias OrchardCLI.RepoRuntime

  @spec run([String.t()]) :: OrchardCLI.command_result()
  def run(["enrollment" | rest]), do: NodeEnrollment.run(rest)
  def run(["trust" | rest]), do: NodeTrustCommand.run(rest)
  def run(args), do: PackagedNodeCommand.run(args, &RepoRuntime.run/2)
end
