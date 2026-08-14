defmodule Orchard.ManagedNodeAgent.LifecycleStateTest do
  use ExUnit.Case, async: true

  alias Orchard.ManagedNodeAgent.LifecycleState

  test "managed stop evidence uses the shared closed operation vocabulary" do
    assert LifecycleState.operation_kinds() ==
             ["handover", "managed_recovery", "start_attempt", "managed_stop"]

    evidence = evidence()

    assert evidence.kind == "managed_stop"
    assert evidence.phase == "initial"

    assert evidence.intended_mutations == [
             "suppress_start_eligibility",
             "invalidate_one_shot_authorization",
             "disable_launchd_job_domain",
             "unload_launchd_job"
           ]

    refute Map.has_key?(evidence, :staging_generation)
    refute Map.has_key?(evidence, :activation)
    refute Map.has_key?(evidence, :rollback)
    refute Map.has_key?(evidence, :start_policy)

    assert evidence.target_identity.active_support_root ==
             "/Library/Application Support/Orchard"

    assert evidence.target_identity.release_name == "orchard_node_agent"
    assert evidence.target_identity.executable_basename == "beam.smp"

    assert :ok = LifecycleState.validate_evidence(evidence)
  end

  test "managed stop evidence rejects fields owned by other operation kinds" do
    assert {:error, :invalid_evidence} =
             evidence()
             |> Map.put(:activation, %{generation: 2})
             |> LifecycleState.validate_evidence()
  end

  test "suppression invalidates authorization and advances generation" do
    prior =
      {:ok,
       %{
         schema_version: 1,
         eligibility: %{state: "one_shot_pending", generation: 8},
         one_shot_authorization: %{attempt_id: "stale"}
       }}

    assert %{
             eligibility: %{state: "suppressed", generation: 9},
             one_shot_authorization: nil
           } = LifecycleState.suppressed_state(prior)

    assert LifecycleState.suppressed_state({:error, :missing}).eligibility.generation == 1

    assert :ok =
             prior
             |> LifecycleState.suppressed_state()
             |> LifecycleState.validate_start_state()

    assert {:error, :invalid_start_state} =
             prior
             |> LifecycleState.suppressed_state()
             |> Map.put(:one_shot_authorization, %{attempt_id: "stale"})
             |> LifecycleState.validate_start_state()
  end

  test "terminal coherent managed stop never denies a later managed start" do
    terminal =
      evidence()
      |> LifecycleState.advance("terminal_coherent", terminal_proof(), timestamp())

    refute LifecycleState.denies_later_start?(terminal)
  end

  test "new evidence supersedes interrupted and failed records without trusting them" do
    terminal =
      evidence()
      |> Map.put(:operation_id, "done")
      |> LifecycleState.advance("terminal_coherent", terminal_proof(), timestamp())

    records = [
      %{"operation_id" => "old", "kind" => "handover", "phase" => "suppression_proven"},
      %{"operation_id" => "failed", "kind" => "managed_stop", "phase" => "terminal_failed"},
      %{
        operation_id: "broken",
        kind: "unknown",
        phase: "invalid",
        filename: "broken.json",
        sha256: "abcd"
      },
      terminal
    ]

    assert LifecycleState.reconciliations(records) == [
             %{
               operation_id: "old",
               kind: "handover",
               phase: "suppression_proven",
               disposition: "supersedes_without_trust"
             },
             %{
               operation_id: "failed",
               kind: "managed_stop",
               phase: "terminal_failed",
               disposition: "supersedes_without_trust"
             },
             %{
               operation_id: "broken",
               kind: "unknown",
               phase: "invalid",
               disposition: "supersedes_without_trust",
               filename: "broken.json",
               sha256: "abcd"
             }
           ]
  end

  defp terminal_proof do
    %{
      outcome: "stopped",
      persistent_disablement: true,
      job_unloaded: true,
      suppression_generation: 2,
      affirmative_absence: true
    }
  end

  defp evidence do
    LifecycleState.new_managed_stop(
      "00000000-0000-4000-8000-000000000001",
      %{pid: 10, start_sec: 20, start_usec: 30},
      %{
        label: "com.orchard.node-agent",
        plist_path: "/Library/LaunchDaemons/com.orchard.node-agent.plist"
      },
      %{eligibility: "missing", launchd_job: "loaded", managed_process: "absent"},
      [],
      timestamp()
    )
  end

  defp timestamp, do: "2026-08-14T00:00:00Z"
end
