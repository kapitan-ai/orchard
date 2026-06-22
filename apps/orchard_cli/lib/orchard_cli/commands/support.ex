defmodule OrchardCLI.Commands.Support do
  @moduledoc false

  alias OrchardCLI.Commands.Deferred

  @commands [
    %{
      path: ["bundle", "create"],
      usage: "orchardctl support bundle create",
      summary: "Create a local diagnostic support bundle (SPEC.md 11.9).",
      status:
        "Defined by SPEC.md 11.9 for the M5 diagnostics milestone; not implemented in the current build.",
      guidance: [
        "Use orchardctl status, controller logs, node-agent logs, and packaging/pkg/README.md troubleshooting steps for current diagnostics.",
        "Do not collect secrets from controller.env, node-agent.env, TLS keys, or license bundles into ad hoc support archives."
      ]
    }
  ]

  @spec run([String.t()]) :: OrchardCLI.command_result()
  def run(args), do: Deferred.run(args, %{name: "support", commands: @commands})
end
