defmodule OrchardCLI.NodeIdentityStoreSecurityTest.RedemptionClient do
  @moduledoc false

  def redeem(_bundle, _identity) do
    send(Application.fetch_env!(:orchard_cli, :node_enrollment_test_pid), :credential_sent)
    {:error, :node_enrollment_rejected}
  end
end

defmodule OrchardCLI.NodeIdentityStoreSecurityTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Orchard.NodeEnrollment.PKI
  alias Orchard.NodeEnrollments
  alias Orchard.NodeTrust
  alias Orchard.Repo
  alias OrchardCLI.Commands.Node
  alias OrchardCLI.NodeIdentity.Store
  alias OrchardCLI.NodeIdentityStoreSecurityTest.RedemptionClient

  setup do
    :ok = Sandbox.checkout(Repo)
    Sandbox.mode(Repo, {:shared, self()})

    root =
      Path.join(
        System.tmp_dir!(),
        "orchard-node-identity-security-#{System.unique_integer([:positive])}"
      )

    trust_root = Path.join(root, "node-trust")

    previous = %{
      client: Application.get_env(:orchard_cli, :node_enrollment_client),
      control_plane: Application.get_env(:orchard_controller, :control_plane),
      identity_root: Application.get_env(:orchard_cli, :node_identity_root),
      test_pid: Application.get_env(:orchard_cli, :node_enrollment_test_pid),
      trust: Application.get_env(:orchard_controller, :node_trust)
    }

    File.mkdir_p!(root)
    Application.put_env(:orchard_controller, :control_plane, role: :single_controller)
    Application.put_env(:orchard_controller, :node_trust, root: trust_root)
    Application.put_env(:orchard_cli, :node_enrollment_client, RedemptionClient)
    Application.put_env(:orchard_cli, :node_enrollment_test_pid, self())

    on_exit(fn ->
      File.rm_rf!(root)
      restore_app_env(:orchard_cli, :node_enrollment_client, previous.client)
      restore_app_env(:orchard_controller, :control_plane, previous.control_plane)
      restore_app_env(:orchard_cli, :node_identity_root, previous.identity_root)
      restore_app_env(:orchard_cli, :node_enrollment_test_pid, previous.test_pid)
      restore_app_env(:orchard_controller, :node_trust, previous.trust)
    end)

    assert {:ok, trust} = NodeTrust.initialize(root: trust_root, actor_id: "security-test")
    {:ok, root: root, trust: trust}
  end

  test "corrupted private key, CSR, or metadata blocks redemption before the credential is sent",
       %{root: root, trust: trust} do
    for kind <- [:private_key, :csr, :metadata] do
      case_root = Path.join(root, "before-redemption-#{kind}")

      %{bundle_path: bundle_path, enrollment_id: enrollment_id, identity_root: identity_root} =
        prepare_case(case_root, trust)

      corrupt_identity!(identity_root, kind)
      Application.put_env(:orchard_cli, :node_identity_root, identity_root)

      assert {:error, _message, 1} =
               Node.run(["join", "--enrollment-bundle", bundle_path])

      refute_receive :credential_sent
      assert {:ok, enrollment} = NodeEnrollments.fetch(enrollment_id)
      assert enrollment.state == :issued
      assert enrollment.node.state == :provisioned
    end
  end

  test "corruption before finalization never persists registered local state", %{
    root: root,
    trust: trust
  } do
    for kind <- [:private_key, :csr, :metadata] do
      case_root = Path.join(root, "before-finalize-#{kind}")
      prepared = prepare_case(case_root, trust)
      response = redeem!(prepared)
      current_generation = current_generation(prepared.identity_root)

      corrupt_identity!(prepared.identity_root, kind)

      assert {:error, _reason} =
               Store.finalize(prepared.identity_root, prepared.identity, response)

      assert current_generation(prepared.identity_root) == current_generation
      assert raw_metadata(prepared.identity_root)["state"] == "prepared"
      assert length(File.ls!(Path.join(prepared.identity_root, "generations"))) == 1
    end
  end

  test "registered certificate, runtime CA, or identifier substitution fails closed", %{
    root: root,
    trust: trust
  } do
    for kind <- [:node_certificate, :runtime_ca, :certificate_identifier] do
      prepared = prepare_case(Path.join(root, "registered-corruption-#{kind}"), trust)
      response = redeem!(prepared)

      assert {:ok, %{state: "registered"}} =
               Store.finalize(prepared.identity_root, prepared.identity, response)

      corrupt_registered_identity!(prepared.identity_root, kind, root, trust)
      Application.put_env(:orchard_cli, :node_identity_root, prepared.identity_root)

      assert {:error, message, 1} =
               Node.run(["join", "--enrollment-bundle", prepared.bundle_path])

      assert message =~ "protected local Node identity state"
      refute message =~ "Node joined and registered"
      refute_receive :credential_sent

      assert {:error, :node_identity_storage_invalid} =
               Store.load_current(prepared.identity_root)
    end
  end

  test "missing current pointer with an existing generation never regenerates or sends credentials",
       %{root: root, trust: trust} do
    prepared = prepare_case(Path.join(root, "missing-current"), trust)
    generations_root = Path.join(prepared.identity_root, "generations")
    generations_before = generations_root |> File.ls!() |> Enum.sort()

    private_key_before =
      File.read!(Path.join(generation_root(prepared.identity_root), "node-private-key.pem"))

    File.rm!(Path.join(prepared.identity_root, "current"))
    Application.put_env(:orchard_cli, :node_identity_root, prepared.identity_root)

    assert {:error, message, 1} =
             Node.run(["join", "--enrollment-bundle", prepared.bundle_path])

    assert message =~ "protected local Node identity state"
    refute_receive :credential_sent
    assert generations_root |> File.ls!() |> Enum.sort() == generations_before

    assert File.read!(
             Path.join([generations_root, hd(generations_before), "node-private-key.pem"])
           ) == private_key_before

    refute File.exists?(Path.join(prepared.identity_root, "current"))
  end

  test "finalization rejects substituted certificates and non-deterministic identifiers", %{
    root: root,
    trust: trust
  } do
    prepared = prepare_case(Path.join(root, "certificate-original"), trust)
    response = redeem!(prepared)
    substitute = prepare_case(Path.join(root, "certificate-substitute"), trust)
    substitute_response = redeem!(substitute)

    invalid_responses = [
      Map.put(response, "certificate_identifier", "nodecert_substituted"),
      Map.put(response, "certificate_serial", "1"),
      Map.put(response, "node_certificate_pem", substitute_response["node_certificate_pem"])
    ]

    for invalid_response <- invalid_responses do
      assert {:error, :node_identity_binding_mismatch} =
               Store.finalize(prepared.identity_root, prepared.identity, invalid_response)

      assert raw_metadata(prepared.identity_root)["state"] == "prepared"
    end
  end

  test "SPEC.md §7.5.0 registered identity retains exact Controller certificate scope", %{
    root: root,
    trust: trust
  } do
    prepared = prepare_case(Path.join(root, "controller-certificate-scope"), trust)
    response = redeem!(prepared)

    assert is_binary(response["controller_certificate_identifier"])
    assert response["controller_certificate_identifier"] != ""

    assert response["controller_certificate_fingerprint"] ==
             trust.controller_certificate_fingerprint

    assert {:ok, _registered} =
             Store.finalize(prepared.identity_root, prepared.identity, response)

    assert {:ok, material} = Store.load_current(prepared.identity_root)

    assert material.controller_certificate_identifier ==
             response["controller_certificate_identifier"]

    assert material.controller_certificate_fingerprint ==
             response["controller_certificate_fingerprint"]
  end

  test "legacy registered identity remains loadable for explicit compatibility mode", %{
    root: root,
    trust: trust
  } do
    prepared = prepare_case(Path.join(root, "legacy-registered-identity"), trust)
    response = redeem!(prepared)

    assert {:ok, _registered} =
             Store.finalize(prepared.identity_root, prepared.identity, response)

    generation_root = generation_root(prepared.identity_root)
    metadata_path = Path.join(generation_root, "metadata.json")

    metadata =
      metadata_path
      |> File.read!()
      |> Jason.decode!()
      |> Map.drop([
        "controller_certificate_identifier",
        "controller_certificate_fingerprint"
      ])

    File.write!(metadata_path, Jason.encode!(metadata))
    File.rm!(Path.join(generation_root, "controller-certificate.pem"))

    assert {:ok, legacy} = Store.load_current(prepared.identity_root)
    assert legacy.state == "registered"
    assert legacy.controller_certificate_identifier == nil
    assert legacy.controller_certificate_fingerprint == nil
    assert legacy.controller_certificate_pem == nil
  end

  defp prepare_case(root, trust) do
    now = DateTime.utc_now()
    expires_at = DateTime.add(now, 3_600, :second)
    identity_root = Path.join(root, "identity")
    bundle_path = Path.join(root, "enrollment.json")

    File.mkdir_p!(root)

    assert {:ok, result} =
             NodeEnrollments.create(
               %{
                 cluster_id: trust.cluster_id,
                 expected_controller_id: trust.controller_id,
                 trust_authority_id: trust.trust_authority_id,
                 creator_type: "operator",
                 expires_at: expires_at,
                 node: %{
                   display_name: "security-#{System.unique_integer([:positive, :monotonic])}"
                 }
               },
               now: now
             )

    assert {:ok, _issued} = NodeEnrollments.mark_issued(result.enrollment.id, now: now)

    bundle = %{
      enrollment_id: result.enrollment.id,
      node_id: result.enrollment.node_id,
      cluster_id: trust.cluster_id,
      issued_at: result.enrollment.issued_at,
      expires_at: result.enrollment.expires_at,
      https_endpoint: "https://controller.orchard.test:443",
      https_trust_anchor_der: certificate_der(trust.ca_certificate_pem),
      https_trust_spki_sha256: trust.ca_spki_fingerprint,
      controller_id: trust.controller_id,
      controller_uri_san: trust.controller_uri_san,
      runtime_trust_spki_sha256: trust.ca_spki_fingerprint,
      token: result.bootstrap_token
    }

    write_bundle!(bundle_path, bundle, trust.ca_certificate_pem)
    assert {:ok, identity} = Store.prepare(identity_root, bundle)

    %{
      bundle: bundle,
      bundle_path: bundle_path,
      enrollment_id: result.enrollment.id,
      identity: identity,
      identity_root: identity_root,
      now: now
    }
  end

  defp redeem!(prepared) do
    assert {:ok, response} =
             NodeEnrollments.redeem(
               prepared.enrollment_id,
               %{
                 cluster_id: prepared.bundle.cluster_id,
                 controller_id: prepared.bundle.controller_id,
                 csr_pem: prepared.identity.csr_pem,
                 node_id: prepared.bundle.node_id,
                 runtime_endpoint: %{
                   host: "127.0.0.1",
                   hostname: "identity-security.orchard.test",
                   port: 30_000 + rem(System.unique_integer([:positive, :monotonic]), 30_000)
                 },
                 token: prepared.bundle.token
               },
               now: prepared.now
             )

    response
  end

  defp corrupt_identity!(identity_root, :private_key) do
    metadata = raw_metadata(identity_root)
    {:ok, replacement} = PKI.generate_csr(metadata["cluster_id"], metadata["node_id"])
    write_current_file!(identity_root, "node-private-key.pem", replacement.private_key_pem)
  end

  defp corrupt_identity!(identity_root, :csr) do
    metadata = raw_metadata(identity_root)
    {:ok, replacement} = PKI.generate_csr(metadata["cluster_id"], metadata["node_id"])
    write_current_file!(identity_root, "node-csr.pem", replacement.csr_pem)
  end

  defp corrupt_identity!(identity_root, :metadata) do
    metadata = Map.put(raw_metadata(identity_root), "csr_fingerprint", "sha256-corrupted")
    write_current_file!(identity_root, "metadata.json", Jason.encode!(metadata))
  end

  defp corrupt_registered_identity!(identity_root, :node_certificate, root, trust) do
    substitute = prepare_case(Path.join(root, "registered-certificate-substitute"), trust)
    substitute_response = redeem!(substitute)

    write_current_file!(
      identity_root,
      "node-certificate.pem",
      substitute_response["node_certificate_pem"]
    )
  end

  defp corrupt_registered_identity!(identity_root, :runtime_ca, _root, _trust) do
    {:ok, substitute} =
      Orchard.NodeTrust.PKI.generate(
        Ecto.UUID.generate(),
        Ecto.UUID.generate(),
        Ecto.UUID.generate(),
        Ecto.UUID.generate(),
        DateTime.utc_now()
      )

    write_current_file!(
      identity_root,
      "runtime-ca-certificate.pem",
      substitute.ca_certificate_pem
    )
  end

  defp corrupt_registered_identity!(
         identity_root,
         :certificate_identifier,
         _root,
         _trust
       ) do
    metadata =
      Map.put(raw_metadata(identity_root), "certificate_identifier", "nodecert_substituted")

    write_current_file!(identity_root, "metadata.json", Jason.encode!(metadata))
  end

  defp write_bundle!(path, bundle, trust_anchor_pem) do
    json = %{
      "version" => 1,
      "enrollment_id" => bundle.enrollment_id,
      "node_id" => bundle.node_id,
      "cluster_id" => bundle.cluster_id,
      "issued_at" => DateTime.to_iso8601(bundle.issued_at),
      "expires_at" => DateTime.to_iso8601(bundle.expires_at),
      "controller" => %{
        "https_endpoint" => bundle.https_endpoint,
        "https_trust_anchor_pem" => trust_anchor_pem,
        "https_trust_spki_sha256" => bundle.https_trust_spki_sha256,
        "id" => bundle.controller_id,
        "runtime_trust_spki_sha256" => bundle.runtime_trust_spki_sha256,
        "uri_san" => bundle.controller_uri_san
      },
      "token" => bundle.token
    }

    File.write!(path, Jason.encode!(json))
  end

  defp raw_metadata(identity_root) do
    identity_root
    |> generation_root()
    |> Path.join("metadata.json")
    |> File.read!()
    |> Jason.decode!()
  end

  defp write_current_file!(identity_root, filename, contents) do
    path = identity_root |> generation_root() |> Path.join(filename)
    File.write!(path, contents)
    File.chmod!(path, 0o600)
  end

  defp generation_root(identity_root) do
    Path.join([identity_root, "generations", current_generation(identity_root)])
  end

  defp current_generation(identity_root) do
    identity_root |> Path.join("current") |> File.read!() |> String.trim()
  end

  defp certificate_der(pem) do
    [{:Certificate, der, :not_encrypted}] = :public_key.pem_decode(pem)
    der
  end

  defp restore_app_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_app_env(app, key, value), do: Application.put_env(app, key, value)
end
