defmodule OrchardCLI.Commands.Node do
  @moduledoc false

  alias OrchardCLI.Commands.Deferred

  @commands [
    %{
      path: ["join"],
      usage: "orchardctl node join",
      summary: "Join a node to an Orchard controller (SPEC.md 11.9).",
      status:
        "Defined by SPEC.md 11.9 for the M3 node lifecycle milestone; not implemented in the current build.",
      guidance: [
        "For current source-dev multi-node testing, set ORCHARD_RUNTIME_CLIENT_TARGETS as documented in docs/local-dev.md.",
        "For packaged node-agent installs, generate node-agent env with orchardctl env init, then start and verify with orchardctl status."
      ]
    }
  ]

  @spec run([String.t()]) :: OrchardCLI.command_result()
  def run(args), do: Deferred.run(args, %{name: "node", commands: @commands})
end
