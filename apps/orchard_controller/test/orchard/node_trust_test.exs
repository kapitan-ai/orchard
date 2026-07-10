defmodule Orchard.NodeTrustTest do
  use Orchard.DataCase, async: false

  import Bitwise
  import Ecto.Query

  alias Orchard.Governance.{AuditLog, ClusterBootstrap}
  alias Orchard.Nodes.{ClusterIdentity, TrustAuthority}
  alias Orchard.NodeTrust

  test "OpenSpec task 2.2 initializes internal Node trust separately from cluster credentials" do
    root = protected_root()
    on_exit(fn -> File.rm_rf!(root) end)

    assert {:ok, initialized} =
             NodeTrust.initialize(root: root, actor_id: "local-test-operator")

    assert {:ok, ^initialized} =
             NodeTrust.initialize(root: root, actor_id: "local-test-operator")

    assert {:ok, public_material} = NodeTrust.public_material(root: root)
    assert public_material == initialized

    assert {:ok, _cluster_id} = Ecto.UUID.cast(public_material.cluster_id)
    assert {:ok, _controller_id} = Ecto.UUID.cast(public_material.controller_id)
    assert {:ok, _authority_id} = Ecto.UUID.cast(public_material.trust_authority_id)

    expected_uri =
      "urn:orchard:cluster:#{public_material.cluster_id}:controller:" <>
        public_material.controller_id

    assert public_material.controller_uri_san == expected_uri
    assert public_material.ca_certificate_pem =~ "BEGIN CERTIFICATE"
    assert public_material.controller_certificate_pem =~ "BEGIN CERTIFICATE"
    refute inspect(public_material) =~ "PRIVATE KEY"

    cluster_id = public_material.cluster_id
    controller_id = public_material.controller_id
    trust_authority_id = public_material.trust_authority_id

    assert %ClusterIdentity{
             id: ^cluster_id,
             runtime_controller_id: ^controller_id
           } = Repo.one!(ClusterIdentity)

    assert %TrustAuthority{
             id: ^trust_authority_id,
             cluster_id: ^cluster_id,
             state: :active
           } = authority = Repo.one!(TrustAuthority)

    refute Map.has_key?(authority, :ca_private_key)
    refute Map.has_key?(authority, :controller_private_key)
    refute inspect(authority) =~ "PRIVATE KEY"

    generation = root |> Path.join("current") |> File.read!() |> String.trim()
    generation_root = Path.join([root, "generations", generation])

    assert private_mode(root) == 0o700
    assert private_mode(Path.join(root, "generations")) == 0o700
    assert private_mode(generation_root) == 0o700

    for filename <- [
          "ca-private-key.pem",
          "ca-certificate.pem",
          "controller-private-key.pem",
          "controller-certificate.pem",
          "metadata.json"
        ] do
      assert private_mode(Path.join(generation_root, filename)) == 0o600
    end

    assert File.read!(Path.join(generation_root, "ca-private-key.pem")) =~
             "BEGIN EC PRIVATE KEY"

    assert File.read!(Path.join(generation_root, "controller-private-key.pem")) =~
             "BEGIN EC PRIVATE KEY"

    controller_der = certificate_der(public_material.controller_certificate_pem)
    assert :binary.match(controller_der, expected_uri) != :nomatch

    audit_log =
      Repo.one!(
        from(audit_log in AuditLog,
          where:
            audit_log.scope == "cluster" and
              audit_log.action == "node_trust.initialized"
        )
      )

    assert audit_log.actor_id == "local-test-operator"

    assert audit_log.payload == %{
             "ca_certificate_fingerprint" => public_material.ca_certificate_fingerprint,
             "cluster_id" => public_material.cluster_id,
             "controller_certificate_fingerprint" =>
               public_material.controller_certificate_fingerprint,
             "controller_id" => public_material.controller_id,
             "trust_authority_id" => public_material.trust_authority_id
           }

    refute inspect(audit_log.payload) =~ "PRIVATE KEY"

    assert {:ok, %{api_client_id: api_client_id}} =
             ClusterBootstrap.mint_first_admin(
               client_name: "node-trust-separate-admin",
               actor_id: "local-test-operator"
             )

    assert is_binary(api_client_id)
  end

  defp protected_root do
    Path.join(
      System.tmp_dir!(),
      "orchard-node-trust-#{System.unique_integer([:positive, :monotonic])}"
    )
  end

  defp private_mode(path) do
    {:ok, stat} = File.stat(path)
    stat.mode &&& 0o777
  end

  defp certificate_der(pem) do
    [{:Certificate, der, :not_encrypted}] = :public_key.pem_decode(pem)
    der
  end
end
