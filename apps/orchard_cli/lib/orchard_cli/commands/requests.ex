defmodule OrchardCLI.Commands.Requests do
  @moduledoc false

  alias OrchardCLI.Commands.Deferred

  @commands [
    %{
      path: ["inspect"],
      usage: "orchardctl requests inspect",
      summary: "Inspect request execution details for operator diagnostics (SPEC.md 11.9).",
      status:
        "Defined by SPEC.md 11.9 for the diagnostics CLI; not implemented in the current build.",
      guidance: [
        "Use Orchard Console request views and controller logs for current request diagnostics.",
        "Use health and readiness endpoints for current machine-checkable status."
      ]
    }
  ]

  @spec run([String.t()]) :: OrchardCLI.command_result()
  def run(args), do: Deferred.run(args, %{name: "requests", commands: @commands})
end
