Code.require_file(Path.join(__DIR__, "beam-peer-grant-control-files.exs"))

defmodule Orchard.BeamPeerGrantControlApplication do
  alias Orchard.BeamPeerGrantControlFiles
  alias Orchard.{BeamPeerGrants, NodeEnrollments, Nodes, NodeTrust, Repo}
  alias Orchard.NodeEnrollment.PKI
  alias OrchardCLI.NodeIdentity.Store

  @stop_timeout_ms 120_000

  def run([root, ipv4]) do
    :ok = BeamPeerGrantControlFiles.validate_root(root)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    trust_root = required_env!("ORCHARD_NODE_TRUST_ROOT")
    identity_root = required_env!("ORCHARD_NODE_IDENTITY_ROOT")
    descriptor_path = required_env!("ORCHARD_BEAM_PEER_GRANT_DESCRIPTOR")
    control_port = required_env!("ORCHARD_BEAM_PEER_GRANT_CONTROL_PORT")

    start_repo!()
    {:ok, trust} = NodeTrust.initialize(root: trust_root, now: now)
    stop_repo!()

    Application.put_env(:orchard_controller, :control_plane, role: :single_controller)
    Application.put_env(:orchard_controller, :start_endpoint, false)
    {:ok, _apps} = Application.ensure_all_started(:orchard_controller)

    {:ok, enrollment} =
      NodeEnrollments.create(
        %{
          cluster_id: trust.cluster_id,
          expected_controller_id: trust.controller_id,
          trust_authority_id: trust.trust_authority_id,
          creator_type: "operator",
          expires_at: DateTime.add(now, 1, :hour),
          node: %{display_name: "peer-grant-application-smoke"}
        },
        now: now
      )

    {:ok, _issued} = NodeEnrollments.mark_issued(enrollment.enrollment.id, now: now)

    bundle = %{
      enrollment_id: enrollment.enrollment.id,
      node_id: enrollment.enrollment.node_id,
      cluster_id: trust.cluster_id,
      issued_at: enrollment.enrollment.issued_at,
      expires_at: enrollment.enrollment.expires_at,
      https_endpoint: "https://#{ipv4}:4000",
      https_trust_anchor_der: certificate_der(trust.ca_certificate_pem),
      https_trust_spki_sha256: trust.ca_spki_fingerprint,
      controller_id: trust.controller_id,
      controller_uri_san: trust.controller_uri_san,
      runtime_trust_spki_sha256: trust.ca_spki_fingerprint,
      token: enrollment.bootstrap_token
    }

    {:ok, prepared} = Store.prepare(identity_root, bundle)

    {:ok, response} =
      NodeEnrollments.redeem(
        enrollment.enrollment.id,
        %{
          cluster_id: trust.cluster_id,
          controller_id: trust.controller_id,
          csr_pem: prepared.csr_pem,
          node_id: enrollment.enrollment.node_id,
          runtime_endpoint: %{
            host: ipv4,
            hostname: "peer-grant-smoke.orchard.test",
            port: 50_071
          },
          token: enrollment.bootstrap_token
        },
        now: now
      )

    {:ok, _registered_identity} = Store.finalize(identity_root, prepared, response)

    {:ok, %{node: node, grants: [grant]}} =
      Nodes.admit_node(
        enrollment.enrollment.node_id,
        %{
          trust_evidence_ref: "application-smoke:#{Ecto.UUID.generate()}",
          pool_id: Ecto.UUID.generate(),
          routing_policy_id: Ecto.UUID.generate()
        },
        now: now
      )

    :ok =
      BeamPeerGrants.write_admitted_descriptor(
        node.id,
        descriptor_path,
        "#{ipv4}:#{control_port}"
      )

    write_env!(Path.join(root, "scope.env"), %{
      "CONTROLLER_ID" => grant.controller_id,
      "CONTROLLER_NAME" => grant.controller_beam_name,
      "GRANT_ID" => grant.id,
      "NODE_ID" => node.id,
      "NODE_NAME" => grant.node_beam_name
    })

    :ok = BeamPeerGrantControlFiles.publish_ready(Path.join(root, "control.ready"))

    :ok =
      BeamPeerGrantControlFiles.wait_for_stop(
        Path.join(root, "control.stop"),
        @stop_timeout_ms
      )

    :ok = Application.stop(:orchard_controller)
  end

  def run(_args), do: raise("expected ROOT and IPv4")

  defp start_repo! do
    {:ok, _apps} = Application.ensure_all_started(:ecto_sql)
    {:ok, _apps} = Application.ensure_all_started(:postgrex)
    {:ok, _pid} = Repo.start_link()
  end

  defp stop_repo! do
    :ok = Supervisor.stop(Repo)
  end

  defp certificate_der(pem) do
    [{:Certificate, der, :not_encrypted}] = :public_key.pem_decode(pem)
    der
  end

  defp write_env!(path, values) do
    contents = Enum.map_join(values, "\n", fn {key, value} -> "#{key}=#{shell_quote(value)}" end)
    File.write!(path, contents <> "\n", [:exclusive])
    File.chmod!(path, 0o600)
  end

  defp required_env!(name) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" -> value
      _other -> raise "#{name} is required"
    end
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
end

Orchard.BeamPeerGrantControlApplication.run(System.argv())
