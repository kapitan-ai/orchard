defmodule Orchard.NodeEnrollmentsTest do
  use Orchard.DataCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Orchard.Governance.AuditLog
  alias Orchard.NodeEnrollment.PKI
  alias Orchard.NodeEnrollments
  alias Orchard.Nodes.{Enrollment, Node}
  alias Orchard.Repo

  test "OpenSpec task 2.1 creates a versioned Node Enrollment with hash-only token persistence" do
    now = ~U[2026-07-10 01:00:00Z]
    expires_at = DateTime.add(now, 3_600, :second)
    cluster_id = Ecto.UUID.generate()
    expected_controller_id = Ecto.UUID.generate()
    trust_authority_id = Ecto.UUID.generate()

    assert {:ok, %{enrollment: created, bootstrap_token: bootstrap_token}} =
             NodeEnrollments.create(
               %{
                 cluster_id: cluster_id,
                 expected_controller_id: expected_controller_id,
                 trust_authority_id: trust_authority_id,
                 creator_type: "operator",
                 creator_id: "local-test-operator",
                 expires_at: expires_at,
                 node: %{display_name: "worker-one"},
                 resume_verifier_metadata: %{
                   "algorithm" => "sha256",
                   "version" => 1
                 },
                 audit_metadata: %{
                   "surface" => "test",
                   "bootstrap_token" => "must-not-persist"
                 }
               },
               now: now
             )

    assert {:ok, persisted} = NodeEnrollments.fetch(created.id)
    assert persisted.format_version == 1
    assert persisted.state == :pending_publication
    assert DateTime.compare(persisted.issued_at, now) == :eq
    assert DateTime.compare(persisted.expires_at, expires_at) == :eq
    assert persisted.published_at == nil
    assert persisted.consumed_at == nil
    assert persisted.revoked_at == nil
    assert persisted.output_failed_at == nil
    assert persisted.cluster_id == cluster_id
    assert persisted.expected_controller_id == expected_controller_id
    assert persisted.trust_authority_id == trust_authority_id
    assert persisted.creator_type == "operator"
    assert persisted.creator_id == "local-test-operator"
    assert persisted.csr_fingerprint == nil

    assert persisted.resume_verifier_metadata == %{
             "algorithm" => "sha256",
             "version" => 1
           }

    assert persisted.certificate_issuance_outcome == :not_started
    assert persisted.certificate_identifier == nil
    assert persisted.certificate_result == %{}
    assert persisted.audit_metadata == %{"surface" => "test"}

    assert persisted.node_id == persisted.node.id
    assert persisted.node.state == :provisioned
    assert persisted.node.display_name == "worker-one"

    assert String.starts_with?(bootstrap_token, "orch_enr_")
    assert persisted.token_prefix != bootstrap_token
    assert persisted.token_hash != bootstrap_token
    refute Map.has_key?(persisted, :bootstrap_token)
    refute inspect(persisted) =~ bootstrap_token

    assert {:ok, csr} = PKI.generate_csr(cluster_id, persisted.node_id)

    assert {:error, :node_enrollment_rejected} =
             NodeEnrollments.redeem(
               persisted.id,
               %{
                 cluster_id: cluster_id,
                 controller_id: expected_controller_id,
                 csr_pem: csr.csr_pem,
                 node_id: persisted.node_id,
                 runtime_endpoint: %{
                   host: "127.0.0.1",
                   hostname: "node-enrollments.orchard.test",
                   port: 50_061
                 },
                 token: bootstrap_token
               },
               now: now
             )

    assert {:ok, still_pending} = NodeEnrollments.fetch(persisted.id)
    assert still_pending.state == :pending_publication
    assert still_pending.node.state == :provisioned

    published_at = DateTime.add(now, 1, :second)

    assert {:ok, issued} =
             NodeEnrollments.mark_issued(created.id,
               now: published_at,
               actor_type: "operator",
               actor_id: "local-test-operator"
             )

    assert issued.state == :issued
    assert DateTime.compare(issued.published_at, published_at) == :eq
    assert {:ok, same_issued} = NodeEnrollments.mark_issued(created.id, now: published_at)
    assert same_issued.id == issued.id
    assert same_issued.lock_version == issued.lock_version

    actions =
      Repo.all(
        from(audit in AuditLog,
          where: audit.target_id == ^created.id,
          order_by: [asc: audit.id],
          select: audit.action
        )
      )

    assert actions == [
             "node_enrollment.publication_pending",
             "node_enrollment.issued"
           ]
  end

  test "stale pending publication reconciles to output_failed at the bounded threshold" do
    now = ~U[2026-07-10 03:00:00Z]
    result = create_pending!(now)

    assert {:ok, %{reconciled: 0}} =
             NodeEnrollments.reconcile_stale_pending_publications(
               now: DateTime.add(now, 299, :second),
               stale_after_seconds: 300
             )

    assert {:ok, %{reconciled: 1}} =
             NodeEnrollments.reconcile_stale_pending_publications(
               now: DateTime.add(now, 300, :second),
               stale_after_seconds: 300
             )

    assert {:ok, failed} = NodeEnrollments.fetch(result.enrollment.id)
    assert failed.state == :output_failed
    assert failed.published_at == nil
    assert failed.consumed_at == nil
    assert failed.node.state == :provisioned
    assert %DateTime{} = failed.output_failed_at
    refute inspect(failed) =~ result.bootstrap_token

    audits =
      Repo.all(
        from(audit in AuditLog,
          where: audit.target_id == ^result.enrollment.id,
          order_by: [asc: audit.id]
        )
      )

    assert Enum.map(audits, & &1.action) == [
             "node_enrollment.publication_pending",
             "node_enrollment.output_failed"
           ]

    assert List.last(audits).payload["reason"] == "publication_confirmation_timeout"
    refute inspect(audits) =~ result.bootstrap_token
  end

  test "concurrent publication success and failure serialize to one durable outcome" do
    now = ~U[2026-07-10 03:30:00Z]
    result = begin_unboxed_pending!(now)
    enrollment_id = result.enrollment.id

    issued_task =
      Task.async(fn ->
        receive do
          :go ->
            Sandbox.unboxed_run(Repo, fn ->
              NodeEnrollments.mark_issued(enrollment_id, now: now)
            end)
        end
      end)

    failed_task =
      Task.async(fn ->
        receive do
          :go ->
            Sandbox.unboxed_run(Repo, fn ->
              NodeEnrollments.mark_output_failed(enrollment_id, now: now)
            end)
        end
      end)

    send(issued_task.pid, :go)
    send(failed_task.pid, :go)

    results = [Task.await(issued_task), Task.await(failed_task)]

    assert Enum.count(results, &match?({:ok, _enrollment}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :invalid_enrollment_state})) == 1

    {enrollment, actions} =
      Sandbox.unboxed_run(Repo, fn ->
        assert {:ok, enrollment} = NodeEnrollments.fetch(enrollment_id)

        actions =
          Repo.all(
            from(audit in AuditLog,
              where: audit.target_id == ^enrollment_id,
              order_by: [asc: audit.id],
              select: audit.action
            )
          )

        {enrollment, actions}
      end)

    assert enrollment.state in [:issued, :output_failed]

    expected_transition =
      if enrollment.state == :issued,
        do: "node_enrollment.issued",
        else: "node_enrollment.output_failed"

    assert actions == ["node_enrollment.publication_pending", expected_transition]
  end

  test "returns the Enrollment for a provisioned node without exposing its token" do
    now = ~U[2026-07-10 04:00:00Z]
    result = create_pending!(now)

    assert {:ok, enrollment} = NodeEnrollments.latest_for_node(result.enrollment.node_id)
    assert enrollment.id == result.enrollment.id
    assert enrollment.node.id == result.enrollment.node_id
    refute inspect(enrollment) =~ result.bootstrap_token

    assert {:error, :enrollment_not_found} =
             NodeEnrollments.latest_for_node(Ecto.UUID.generate())
  end

  defp create_pending!(now, display_name \\ "stale-publication") do
    assert {:ok, result} =
             NodeEnrollments.create(
               %{
                 cluster_id: Ecto.UUID.generate(),
                 expected_controller_id: Ecto.UUID.generate(),
                 trust_authority_id: Ecto.UUID.generate(),
                 creator_type: "operator",
                 creator_id: "local-test-operator",
                 expires_at: DateTime.add(now, 3_600, :second),
                 node: %{display_name: display_name}
               },
               now: now
             )

    result
  end

  defp begin_unboxed_pending!(now) do
    :ok = Sandbox.checkin(Repo)
    display_name = "publication-race-#{System.unique_integer([:positive])}"
    result = Sandbox.unboxed_run(Repo, fn -> create_pending!(now, display_name) end)
    enrollment_id = result.enrollment.id
    node_id = result.enrollment.node_id

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.query!("ALTER TABLE audit_logs DISABLE TRIGGER audit_logs_append_only")

        try do
          Repo.delete_all(from(audit in AuditLog, where: audit.target_id == ^enrollment_id))
        after
          Repo.query!("ALTER TABLE audit_logs ENABLE TRIGGER audit_logs_append_only")
        end

        Repo.delete_all(from(enrollment in Enrollment, where: enrollment.id == ^enrollment_id))
        Repo.delete_all(from(node in Node, where: node.id == ^node_id))
      end)
    end)

    result
  end
end
