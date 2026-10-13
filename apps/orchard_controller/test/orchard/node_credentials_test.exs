defmodule Orchard.NodeCredentialsTest do
  use Orchard.DataCase, async: false

  import Ecto.Query

  alias Orchard.Governance.AuditLog
  alias Orchard.NodeCredentials
  alias Orchard.NodeCredentials.Generation
  alias Orchard.NodeEnrollment.PKI
  alias Orchard.NodeEnrollments
  alias Orchard.NodeTrust
  alias Orchard.Repo
  alias Orchard.TransportTLS.CertificateIdentity

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "orchard-node-credentials-#{System.unique_integer([:positive])}"
      )

    previous_control_plane = Application.get_env(:orchard_controller, :control_plane)
    previous_node_trust = Application.get_env(:orchard_controller, :node_trust)
    Application.put_env(:orchard_controller, :control_plane, role: :single_controller)
    Application.put_env(:orchard_controller, :node_trust, root: root)

    on_exit(fn ->
      File.rm_rf!(root)
      restore_env(:control_plane, previous_control_plane)
      restore_env(:node_trust, previous_node_trust)
    end)

    assert {:ok, trust} = NodeTrust.initialize(root: root)
    {:ok, trust: trust}
  end

  test "KAP-82 enrollment establishes exact 90-day current authority and renewal boundary", %{
    trust: trust
  } do
    now = ~U[2026-09-19 10:00:00Z]
    enrolled = enroll!(trust, now)

    assert {:ok, current} = NodeCredentials.current(enrolled.node_id, now: now)
    assert current.generation == 1
    assert current.state == :current
    assert DateTime.diff(current.not_after_at, now, :day) == 90
    assert DateTime.diff(current.renew_after_at, now, :day) == 60
    assert current.certificate_identifier == enrolled.response["certificate_identifier"]
    refute inspect(current) =~ enrolled.private_key_pem

    assert {:error, :node_credential_renewal_not_due} =
             NodeCredentials.stage_renewal(enrolled.node_id, enrolled.next_csr.csr_pem,
               now: DateTime.add(current.renew_after_at, -1, :second)
             )

    assert Repo.aggregate(Generation, :count, :id) == 1
  end

  test "KAP-82 rotation overlaps accepted authority then atomically fences the predecessor", %{
    trust: trust
  } do
    now = ~U[2026-09-19 11:00:00Z]
    enrolled = enroll!(trust, now)
    assert {:ok, predecessor} = NodeCredentials.current(enrolled.node_id, now: now)
    stage_at = predecessor.renew_after_at

    assert {:ok, staged} =
             NodeCredentials.stage_renewal(enrolled.node_id, enrolled.next_csr.csr_pem,
               now: stage_at,
               evidence: %{"surface" => "test"}
             )

    assert staged.generation == 2
    assert staged.state == :staged
    assert DateTime.compare(staged.overlap_ends_at, DateTime.add(stage_at, 7, :day)) == :eq

    assert {:ok, ^predecessor} =
             NodeCredentials.authorize_peer(
               enrolled.node_id,
               predecessor.certificate_identifier,
               predecessor.certificate_fingerprint_sha256,
               now: stage_at
             )

    assert {:ok, ^staged} =
             NodeCredentials.authorize_peer(
               enrolled.node_id,
               staged.certificate_identifier,
               staged.certificate_fingerprint_sha256,
               now: stage_at
             )

    overlap_end = DateTime.add(stage_at, 7, :day)

    assert {:error, :node_credential_not_current} =
             NodeCredentials.authorize_peer(
               enrolled.node_id,
               predecessor.certificate_identifier,
               predecessor.certificate_fingerprint_sha256,
               now: overlap_end
             )

    assert {:error, :node_credential_not_current} =
             NodeCredentials.activate_staged(enrolled.node_id, staged.generation,
               now: overlap_end
             )

    assert {:ok, activated} =
             NodeCredentials.activate_staged(enrolled.node_id, staged.generation, now: stage_at)

    assert activated.state == :current

    assert {:error, :node_credential_not_current} =
             NodeCredentials.authorize_peer(
               enrolled.node_id,
               predecessor.certificate_identifier,
               predecessor.certificate_fingerprint_sha256,
               now: stage_at
             )

    assert {:ok, %Generation{generation: 2}} =
             NodeCredentials.current(enrolled.node_id, now: stage_at)

    assert Repo.get!(Generation, predecessor.id).state == :superseded
  end

  test "KAP-82 revocation and clock uncertainty fail closed with durable audit", %{trust: trust} do
    now = ~U[2026-09-19 12:00:00Z]
    enrolled = enroll!(trust, now)
    assert {:ok, current} = NodeCredentials.current(enrolled.node_id, now: now)

    assert {:error, :node_credential_clock_uncertainty_invalid} =
             NodeCredentials.current(enrolled.node_id,
               now: now,
               clock_uncertainty_seconds: 301
             )

    assert {:error, :node_credential_not_current} =
             NodeCredentials.current(enrolled.node_id,
               now: DateTime.add(current.not_after_at, -299, :second),
               clock_uncertainty_seconds: 300
             )

    assert {:ok, [%Generation{state: :revoked}]} =
             NodeCredentials.revoke(enrolled.node_id, "operator decommission", now: now)

    assert {:error, :node_credential_not_found} =
             NodeCredentials.current(enrolled.node_id, now: now)

    actions =
      Repo.all(
        from(audit in AuditLog,
          where: audit.target_type == "node_credential_generation",
          order_by: [asc: audit.id],
          select: audit.action
        )
      )

    assert actions == [
             "node_enrollment.credential_activated",
             "node_enrollment.credential_revoked"
           ]
  end

  defp enroll!(trust, now) do
    assert {:ok, created} =
             NodeEnrollments.create(
               %{
                 cluster_id: trust.cluster_id,
                 expected_controller_id: trust.controller_id,
                 trust_authority_id: trust.trust_authority_id,
                 creator_type: "operator",
                 expires_at: DateTime.add(now, 1, :hour),
                 node: %{display_name: "credential-lifecycle-test"}
               },
               now: now
             )

    assert {:ok, _issued} = NodeEnrollments.mark_issued(created.enrollment.id, now: now)
    assert {:ok, csr} = PKI.generate_csr(trust.cluster_id, created.enrollment.node_id)

    assert {:ok, response} =
             NodeEnrollments.redeem(
               created.enrollment.id,
               %{
                 cluster_id: trust.cluster_id,
                 controller_id: trust.controller_id,
                 csr_pem: csr.csr_pem,
                 node_id: created.enrollment.node_id,
                 runtime_endpoint: %{
                   host: "127.0.0.1",
                   hostname: "credential-lifecycle.orchard.test",
                   port: 50_061
                 },
                 token: created.bootstrap_token
               },
               now: now
             )

    assert {:ok, certificate} = CertificateIdentity.from_pem(response["node_certificate_pem"])
    assert {:ok, next_csr} = PKI.generate_csr(trust.cluster_id, created.enrollment.node_id)

    %{
      node_id: created.enrollment.node_id,
      private_key_pem: csr.private_key_pem,
      certificate: certificate,
      response: response,
      next_csr: next_csr
    }
  end

  defp restore_env(key, nil), do: Application.delete_env(:orchard_controller, key)
  defp restore_env(key, value), do: Application.put_env(:orchard_controller, key, value)
end
