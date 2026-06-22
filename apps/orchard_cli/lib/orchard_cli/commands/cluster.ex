defmodule OrchardCLI.Commands.Cluster do
  @moduledoc false

  alias OrchardCLI.Commands.Deferred

  @commands [
    %{
      path: ["init"],
      usage: "orchardctl cluster init",
      summary: "Initialize controller-side cluster bootstrap state (SPEC.md 11.9).",
      status:
        "Defined by SPEC.md 11.9 for node lifecycle work; not implemented in the current build.",
      guidance: [
        "For packaged controller setup, follow packaging/pkg/README.md with env init, migrate, transport configuration, start, and status.",
        "For source-dev split roles, use bin/dev-controller and bin/dev-node-agent."
      ]
    }
  ]

  @spec run([String.t()]) :: OrchardCLI.command_result()
  def run(args), do: Deferred.run(args, %{name: "cluster", commands: @commands})
end
