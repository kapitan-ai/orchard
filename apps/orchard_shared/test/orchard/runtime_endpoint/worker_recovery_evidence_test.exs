defmodule Orchard.RuntimeEndpoint.WorkerRecoveryEvidenceTest do
  use ExUnit.Case, async: true

  alias Orchard.RuntimeEndpoint.{Placement, WorkerRecoveryEvidence}

  test "SPEC §12.2 retained recovery projects failed and loading placement lifecycle states" do
    for {recovery_state, placement_state} <- [
          {"backoff", :failed},
          {"open", :failed},
          {"recovery_required", :failed},
          {"restarting", :loading},
          {"armed", :unknown}
        ] do
      record = %{
        model_ref: %{model_id: "recovery/model", version: "v1"},
        worker_recovery_json: Jason.encode!(projection(recovery_state))
      }

      assert [%Placement{state: ^placement_state}] = WorkerRecoveryEvidence.attach([], [record])
    end
  end

  test "SPEC §12.2 recovery evidence has one valid state eligibility reason triple" do
    assert {:ok, decoded} =
             projection("armed")
             |> WorkerRecoveryEvidence.encode()
             |> then(fn {:ok, json} -> WorkerRecoveryEvidence.decode(json) end)

    assert decoded.state == "armed"
    assert decoded.eligible
    assert decoded.reason == nil

    for evidence <- [
          %{projection("armed") | "eligible" => false},
          %{projection("backoff") | "eligible" => true},
          %{projection("open") | "reason" => "worker_restart_backoff"}
        ] do
      assert {:error, :invalid_worker_recovery_evidence} =
               WorkerRecoveryEvidence.validate(evidence)
    end

    assert {:error, :invalid_worker_recovery_evidence} =
             WorkerRecoveryEvidence.decode(%{"state" => "armed"})
  end

  test "SPEC §12.2 conflicting atom and string recovery evidence fails closed" do
    evidence = projection("armed") |> Map.put(:state, "open")

    assert %{"invalid" => "worker_recovery_evidence"} =
             WorkerRecoveryEvidence.normalize(evidence)

    conflicting_key =
      projection("armed")
      |> Map.put(:key, %{
        "node_id" => "00000000-0000-4000-a000-000000000002",
        node_id: "00000000-0000-4000-a000-000000000001",
        model_id: "recovery/model",
        version: "v1"
      })

    assert %{"invalid" => "worker_recovery_evidence"} =
             WorkerRecoveryEvidence.normalize(conflicting_key)
  end

  test "SPEC §12.2 attach preserves invalid records as incomplete evidence" do
    valid_ref_invalid_projection = %{
      model_ref: %{model_id: "recovery/model", version: "v1"},
      worker_recovery_json: Jason.encode!(%{"state" => "armed"})
    }

    invalid_ref = %{
      model_ref: %{model_id: "", version: "v1"},
      worker_recovery_json: Jason.encode!(projection("armed"))
    }

    assert [valid, invalid] =
             WorkerRecoveryEvidence.attach([], [valid_ref_invalid_projection, invalid_ref])

    assert valid.worker_recovery == %{"invalid" => "worker_recovery_evidence"}
    assert invalid.model_ref == nil
    assert invalid.worker_recovery == %{"invalid" => "worker_recovery_model_ref"}
  end

  defp projection(state) do
    eligible = state == "armed"

    %{
      "key" => %{
        "node_id" => "00000000-0000-4000-a000-000000000001",
        "model_id" => "recovery/model",
        "version" => "v1"
      },
      "epoch" => "epoch-1",
      "owner_epoch" => "epoch-1",
      "revision" => 3,
      "state" => state,
      "hydrated" => true,
      "eligible" => eligible,
      "reason" => reason(state)
    }
  end

  defp reason("backoff"), do: "worker_restart_backoff"
  defp reason("restarting"), do: "worker_restart_in_progress"
  defp reason("open"), do: "placement_crash_breaker_open"
  defp reason("recovery_required"), do: "placement_recovery_required"
  defp reason("armed"), do: nil
end
