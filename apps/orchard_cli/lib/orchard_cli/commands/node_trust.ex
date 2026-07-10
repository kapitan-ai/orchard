defmodule OrchardCLI.Commands.NodeTrust do
  @moduledoc false

  alias Orchard.NodeTrust
  alias OrchardCLI.RepoRuntime

  @spec run([String.t()]) :: OrchardCLI.command_result()
  def run(["init", "--help"]), do: {:ok, usage()}
  def run(["init", "help"]), do: {:ok, usage()}

  def run(["init"]) do
    RepoRuntime.run(fn -> initialize() end)
  end

  def run(_args), do: {:error, usage(), 1}

  defp initialize do
    case NodeTrust.initialize(actor_id: "local-orchardctl") do
      {:ok, material} -> {:ok, success_message(material)}
      {:error, reason} -> command_error(reason)
    end
  end

  defp success_message(material) do
    "Internal Node trust initialized\n" <>
      "Cluster ID: #{material.cluster_id}\n" <>
      "Controller ID: #{material.controller_id}\n" <>
      "Trust Authority ID: #{material.trust_authority_id}\n" <>
      "Runtime CA SPKI: #{material.ca_spki_fingerprint}"
  end

  defp command_error(:controller_standby) do
    {:error, "Error: internal Node trust initialization is leader-only.", 1}
  end

  defp command_error(:controller_leadership_unproven) do
    {:error, "Error: Controller leadership could not be proven; Node trust was not initialized.",
     1}
  end

  defp command_error(:node_trust_root_required) do
    {:error, "Error: protected local Node trust storage is not configured.", 1}
  end

  defp command_error(_reason) do
    {:error, "Error: internal Node trust initialization failed closed.", 1}
  end

  defp usage do
    Enum.join(
      [
        "Usage: orchardctl nodes trust init",
        "",
        "Initializes protected internal Node trust on the local leader Controller.",
        "The operation is idempotent and does not print private key material."
      ],
      "\n"
    )
  end
end
