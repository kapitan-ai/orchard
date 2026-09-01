defmodule Orchard.Governance.AuditWriterTest.RaisingCommitVerifier do
  def get(_schema, _id), do: raise("forced commit verification failure")
end

defmodule Orchard.Governance.AuditWriterTest do
  use Orchard.DataCase, async: false

  alias Orchard.Governance.{AuditLog, AuditWriter}
  alias Orchard.Metrics.{Normalizer, Status}
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
    {"circuit_breaker.node.cleared", "circuit_breaker", "succeeded"},
    {"portal_user.invited", "portal_user", "succeeded"},
    {"provisioning_batch.failed", "service_account", "failed"},
    {"cluster_admin_bootstrap.minted", "cluster", "succeeded"}
  ]

  test "SPEC.md §10.9 refuses to run inside an independently owned Repo transaction" do
    ref = attach_metric()
    owner = self()

    assert {:ok, {:error, :audit_writer_not_outermost}} =
             Repo.transaction(fn ->
               AuditWriter.transaction(fn ->
                 send(owner, :audit_callback_ran)

                 "tenant.created"
                 |> valid_changeset()
                 |> AuditWriter.insert()
               end)
             end)

    refute_received :audit_callback_ran
    refute_receive {^ref, _measurements, _metadata}
    refute Repo.get_by(AuditLog, action: "tenant.created")
  end

  test "SPEC.md §10.9 refuses a direct audit insert inside an unmanaged transaction" do
    ref = attach_metric()

    assert {:ok, {:error, changeset}} =
             Repo.transaction(fn ->
               "tenant.created"
               |> valid_changeset()
               |> AuditWriter.insert()
             end)

    assert "audit writer must own the outermost transaction" in errors_on(changeset).base
    refute_receive {^ref, _measurements, _metadata}
    refute Repo.get_by(AuditLog, action: "tenant.created")
  end

  test "SPEC.md §9.1 nested audit transactions publish only after the outer commit" do
    ref = attach_metric()

    assert {:ok, :committed} =
             AuditWriter.transaction(fn ->
               assert {:ok, {:ok, %AuditLog{}}} =
                        AuditWriter.transaction(fn ->
                          "tenant.created"
                          |> valid_changeset()
                          |> AuditWriter.insert()
                        end)

               refute_receive {^ref, _measurements, _metadata}
               :committed
             end)

    assert_receive {^ref, %{value: 1}, %{action: "tenant", outcome: "succeeded"}}
  end

  test "SPEC.md §9.1 nested audit success cannot escape an outer rollback" do
    ref = attach_metric()

    assert {:error, :forced_outer_rollback} =
             AuditWriter.transaction(fn ->
               assert {:ok, {:ok, %AuditLog{}}} =
                        AuditWriter.transaction(fn ->
                          "tenant.created"
                          |> valid_changeset()
                          |> AuditWriter.insert()
                        end)

               Repo.rollback(:forced_outer_rollback)
             end)

    refute_receive {^ref, _measurements, _metadata}
    refute Repo.get_by(AuditLog, action: "tenant.created")
  end

  test "SPEC.md §9.1 a raw inner savepoint rollback cannot publish queued success" do
    ref = attach_metric()

    assert {:ok, :outer_committed} =
             AuditWriter.transaction(fn ->
               Repo.query!("SAVEPOINT audit_writer_inner")

               assert {:ok, %AuditLog{}} =
                        "tenant.created"
                        |> valid_changeset()
                        |> AuditWriter.insert()

               Repo.query!("ROLLBACK TO SAVEPOINT audit_writer_inner")

               :outer_committed
             end)

    refute_receive {^ref, _measurements, _metadata}
    refute Repo.get_by(AuditLog, action: "tenant.created")
  end

  test "SPEC.md §9.1 post-commit verification failure cannot change the committed result" do
    previous = Application.get_env(:orchard_controller, :audit_commit_verifier_impl, :missing)

    Application.put_env(
      :orchard_controller,
      :audit_commit_verifier_impl,
      Orchard.Governance.AuditWriterTest.RaisingCommitVerifier
    )

    on_exit(fn ->
      Status.recover({:audit_commit_verification, :unavailable})

      case previous do
        :missing -> Application.delete_env(:orchard_controller, :audit_commit_verifier_impl)
        value -> Application.put_env(:orchard_controller, :audit_commit_verifier_impl, value)
      end
    end)

    ref = attach_metric()

    assert {:ok, :committed} =
             AuditWriter.transaction(fn ->
               assert {:ok, %AuditLog{}} =
                        "tenant.created"
                        |> valid_changeset()
                        |> AuditWriter.insert()

               :committed
             end)

    assert Repo.get_by(AuditLog, action: "tenant.created")
    refute_receive {^ref, _measurements, _metadata}
    assert :ets.member(Status, {:audit_commit_verification, :unavailable})

    Application.put_env(:orchard_controller, :audit_commit_verifier_impl, Repo)

    assert {:ok, :verified} =
             AuditWriter.transaction(fn ->
               assert {:ok, %AuditLog{}} =
                        "tenant.updated"
                        |> valid_changeset()
                        |> AuditWriter.insert()

               :verified
             end)

    assert_receive {^ref, %{value: 1}, %{action: "tenant", outcome: "succeeded"}}
    refute :ets.member(Status, {:audit_commit_verification, :unavailable})
  end

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

  test "SPEC.md §9.1 an unmapped audit action domain emits no out-of-vocabulary label" do
    ref = attach_metric()

    assert {:error, :invalid_labels} =
             Normalizer.normalize(:audit_events, %{action: "unknown", outcome: "succeeded"})

    assert {:ok, %AuditLog{}} =
             "unmapped_domain.created" |> valid_changeset() |> AuditWriter.insert()

    refute_receive {^ref, _measurements, _metadata}
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
