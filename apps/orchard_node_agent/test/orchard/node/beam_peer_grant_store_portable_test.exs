defmodule Orchard.Node.BeamPeerGrantStorePortableTest do
  use ExUnit.Case, async: true

  alias Orchard.Node.BeamPeerGrantStore

  test "KAP-82 Linux flock custody atomically stages and activates one successor" do
    root = private_root!()
    on_exit(fn -> File.rm_rf!(root) end)
    now = DateTime.utc_now()
    initial_identity = identity("node-cert-1", "sha256-node-1")
    initial = delivery(initial_identity, 1, now)

    assert {:ok, %{generation: 1}} =
             BeamPeerGrantStore.install(root, initial_identity, initial, initial.node_beam_name)

    successor_identity = identity("node-cert-2", "sha256-node-2")
    successor = delivery(successor_identity, 2, now)

    assert {:ok, %{generation: 2}} =
             BeamPeerGrantStore.stage(
               root,
               successor_identity,
               successor,
               successor.node_beam_name
             )

    assert {:ok, %{generation: 1}} =
             BeamPeerGrantStore.load(root, initial_identity, initial.node_beam_name)

    assert {:ok, %{generation: 2}} =
             BeamPeerGrantStore.activate_staged(
               root,
               successor_identity,
               successor.node_beam_name,
               2
             )

    assert {:ok, %{generation: 2}} =
             BeamPeerGrantStore.load(root, successor_identity, successor.node_beam_name)

    refute File.exists?(
             Path.join([root, "beam-peer-grants", successor.controller_id <> ".staged.json"])
           )
  end

  test "KAP-82 staged custody refuses symlinks without replacing active authority" do
    root = private_root!()
    on_exit(fn -> File.rm_rf!(root) end)
    now = DateTime.utc_now()
    initial_identity = identity("node-cert-1", "sha256-node-1")
    initial = delivery(initial_identity, 1, now)

    assert {:ok, _stored} =
             BeamPeerGrantStore.install(root, initial_identity, initial, initial.node_beam_name)

    staged_path =
      Path.join([root, "beam-peer-grants", initial.controller_id <> ".staged.json"])

    target = Path.join(root, "attacker-target")
    File.write!(target, "do-not-replace")
    File.ln_s!(target, staged_path)
    successor_identity = identity("node-cert-2", "sha256-node-2")
    successor = delivery(successor_identity, 2, now)

    assert {:error, :beam_peer_grant_store_invalid} =
             BeamPeerGrantStore.stage(
               root,
               successor_identity,
               successor,
               successor.node_beam_name
             )

    assert File.read!(target) == "do-not-replace"

    assert {:ok, %{generation: 1}} =
             BeamPeerGrantStore.load(root, initial_identity, initial.node_beam_name)
  end

  defp private_root! do
    root =
      Path.join(
        System.tmp_dir!(),
        "orchard-portable-peer-grant-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    root
  end

  defp identity(certificate_identifier, certificate_fingerprint) do
    %{
      cluster_id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
      controller_id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
      controller_certificate_identifier: "serial:100",
      controller_certificate_fingerprint: "sha256-controller",
      node_id: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
      certificate_identifier: certificate_identifier,
      certificate_fingerprint: certificate_fingerprint
    }
  end

  defp delivery(identity, generation, reference_time) do
    secret_byte = <<generation>>
    encoded_secret = Base.url_encode64(:binary.copy(secret_byte, 32), padding: false)
    not_before_at = DateTime.add(reference_time, -60, :second)

    %{
      grant_id:
        if(generation == 1,
          do: "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
          else: "ffffffff-ffff-4fff-8fff-ffffffffffff"
        ),
      generation: generation,
      cluster_id: identity.cluster_id,
      controller_id: identity.controller_id,
      controller_beam_name: "orchard_controller_bbbbbbbbbbbb4bbb8bbbbbbbbbbbbbbb@10.0.0.10",
      controller_certificate_identifier: identity.controller_certificate_identifier,
      controller_certificate_fingerprint_sha256: identity.controller_certificate_fingerprint,
      beam_authorization_root_id: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
      node_id: identity.node_id,
      node_beam_name: "orchard_node_agent_cccccccccccc4ccc8ccccccccccccccc@10.0.0.20",
      node_certificate_identifier: identity.certificate_identifier,
      node_certificate_fingerprint_sha256: identity.certificate_fingerprint,
      contract_version: 1,
      purpose: "runtime_endpoint",
      issued_at: not_before_at,
      not_before_at: not_before_at,
      cutover_at: nil,
      expires_at: DateTime.add(not_before_at, 30, :day),
      encoded_secret: encoded_secret,
      secret_hash: :crypto.hash(:sha256, encoded_secret)
    }
  end
end
