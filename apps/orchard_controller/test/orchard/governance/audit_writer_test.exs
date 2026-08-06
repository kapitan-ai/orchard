defmodule Orchard.Governance.AuditWriterTest do
  use Orchard.DataCase, async: false

  alias Orchard.Governance.{AuditLog, AuditWriter}
  alias Orchard.Repo

  setup do
    if Process.whereis(Orchard.Metrics.Supervisor) == nil do
      start_supervised!(Orchard.Metrics.Supervisor)
    end

    :ok
  end

  @current_actions [
    {"tenant.created", "tenant", "succeeded"},
    {"api_key.auth_failed", "api_key", "denied"},
    {"service_account.disabled", "service_account", "succeeded"},
    {"role_binding.created", "role_binding", "succeeded"},
    {"support_bundle.generated", "support_bundle", "succeeded"},
    {"node_admission.rejected", "node_admission", "denied"},
    {"node_enrollment.issued", "node_admission", "succeeded"},
    {"node_trust.initialized", "node_admission", "succeeded"},
    {"node_lifecycle.cordoned", "node_lifecycle", "succeeded"},
    {"provisioning_batch.failed", "service_account", "failed"},
    {"cluster_admin_bootstrap.minted", "cluster", "succeeded"}
  ]

  test "SPEC.md §9.1 emits one bounded audit event for every current audit action domain" do
    ref = attach_metric()

    for {action, action_domain, outcome} <- @current_actions do
      assert {:ok, %AuditLog{}} = action |> valid_changeset() |> AuditWriter.insert()

      assert_receive {^ref, %{value: 1}, %{action: ^action_domain, outcome: ^outcome}}
      refute_receive {^ref, _measurements, _metadata}
    end
  end

  test "SPEC.md §9.1 failed audit writes emit one failed outcome without sensitive labels" do
    ref = attach_metric()

    changeset =
      %AuditLog{}
      |> AuditLog.changeset(%{
        scope: "cluster",
        actor_type: "operator",
        action: "api_key.created"
      })

    assert {:error, %Ecto.Changeset{}} = AuditWriter.insert(changeset)
    assert_receive {^ref, %{value: 1}, %{action: "api_key", outcome: "failed"}}
    refute_receive {^ref, _measurements, _metadata}
  end

  test "SPEC.md §9.1 rolled-back audit rows do not emit succeeded metrics" do
    ref = attach_metric()

    assert {:error, :forced_rollback} =
             AuditWriter.transaction(fn ->
               assert {:ok, %AuditLog{}} =
                        "tenant.created"
                        |> valid_changeset()
                        |> AuditWriter.insert()

               Repo.rollback(:forced_rollback)
             end)

    refute_receive {^ref, %{value: 1}, %{action: "tenant", outcome: "succeeded"}}
    refute Repo.get_by(AuditLog, action: "tenant.created")
  end

  test "metrics timeout does not alter the authoritative audit write result" do
    admission = Process.whereis(Orchard.Metrics.SeriesAdmission)
    :ok = :sys.suspend(admission)

    on_exit(fn ->
      if Process.alive?(admission), do: :sys.resume(admission)
    end)

    assert {:ok, %AuditLog{action: "cluster.write"}} =
             "cluster.write"
             |> valid_changeset()
             |> AuditWriter.insert()

    :ok = :sys.resume(admission)
  end

  defp valid_changeset(action) do
    AuditLog.changeset(%AuditLog{}, %{
      scope: "cluster",
      tenant_id: nil,
      actor_type: "operator",
      action: action,
      target_type: "cluster",
      occurred_at: DateTime.utc_now()
    })
  end

  defp attach_metric do
    owner = self()
    ref = make_ref()
    handler_id = {__MODULE__, ref}

    :ok =
      :telemetry.attach(
        handler_id,
        [:orchard, :metrics, :audit_events],
        fn _event, measurements, metadata, _config ->
          send(owner, {ref, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    ref
  end
end
