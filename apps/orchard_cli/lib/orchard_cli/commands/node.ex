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
        "For current source-dev multi-node testing, use BEAM Runtime Endpoint targets as documented in docs/local-dev.md.",
        "For packaged node-agent installs today, use a role-selected PKG install, run orchardctl env init --service node-agent, set ORCHARD_BEAM_NODE_NAME and ORCHARD_BEAM_COOKIE_FILE in node-agent.env, set controller ORCHARD_RUNTIME_ENDPOINT_TARGETS to orchard_node_agent@<worker-ipv4> values, then run orchardctl start and orchardctl status.",
        "Use ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=grpc and ORCHARD_RUNTIME_CLIENT_TARGETS only for the gRPC compatibility fallback.",
        "node join/admission/certificate bootstrap remains deferred."
      ]
    }
  ]

  @spec run([String.t()]) :: OrchardCLI.command_result()
  def run(args), do: Deferred.run(args, %{name: "node", commands: @commands})
end
