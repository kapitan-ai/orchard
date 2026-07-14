defmodule Orchard.Node.BeamPeerGrantStartupVerifierTest do
  use ExUnit.Case, async: true

  alias Orchard.Node.BeamPeerGrantStartupVerifier

  defmodule Launch do
    def load(_path), do: {:ok, Process.get(:startup_manifest)}

    def verify_vm(manifest, opts) do
      send(self(), {:vm_verified, manifest, opts})
      :ok
    end
  end

  defmodule IdentityLoader do
    def load_registered_identity(_root, require_controller_certificate: true) do
      {:ok, Process.get(:startup_identity)}
    end
  end

  defmodule DescriptorLoader do
    def load(_path), do: {:ok, Process.get(:startup_descriptor)}
  end

  defmodule GrantStore do
    def load(_root, _identity, _node_name), do: {:ok, Process.get(:startup_grant)}
    def ensure_current(_grant), do: :ok
  end

  defmodule DistributionTLS do
    def verify_options(path, local, peer) do
      send(self(), {:tls_verified, path, local, peer})
      :ok
    end
  end

  test "SPEC.md §7.5.0 verifies stored custody and exact VM launch before Node runtime startup" do
    node_id = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
    controller_id = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    grant_id = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
    node_name = "orchard_node_agent_cccccccccccc4ccc8ccccccccccccccc@10.0.0.20"
    controller_name = "orchard_controller_bbbbbbbbbbbb4bbb8bbbbbbbbbbbbbbb@10.0.0.10"

    identity = %{
      generation_id: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
      cluster_id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
      node_id: node_id,
      controller_id: controller_id,
      node_uri_san: "urn:orchard:cluster:aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa:node:#{node_id}",
      controller_uri_san:
        "urn:orchard:cluster:aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa:controller:#{controller_id}",
      certificate_identifier: "serial:200",
      certificate_fingerprint: "sha256-node",
      controller_certificate_identifier: "serial:100",
      controller_certificate_fingerprint: "sha256-controller",
      certfile: "/protected/node.pem",
      keyfile: "/protected/node-key.pem",
      cacertfile: "/protected/ca.pem"
    }

    grant = %{
      grant_id: grant_id,
      generation: 1,
      contract_version: 1,
      purpose: "runtime_endpoint",
      not_before_at: ~U[2026-07-13 08:00:00.000000Z],
      expires_at: ~U[2026-07-13 08:30:00.000000Z],
      cluster_id: identity.cluster_id,
      controller_id: controller_id,
      node_id: node_id,
      controller_beam_name: controller_name,
      node_beam_name: node_name,
      controller_certificate_identifier: identity.controller_certificate_identifier,
      controller_certificate_fingerprint_sha256: identity.controller_certificate_fingerprint,
      node_certificate_identifier: identity.certificate_identifier,
      node_certificate_fingerprint_sha256: identity.certificate_fingerprint,
      beam_authorization_root_id: "ffffffff-ffff-4fff-8fff-ffffffffffff"
    }

    manifest =
      grant
      |> Map.put(:role, :node_agent)
      |> Map.put(:local_identity_generation_id, identity.generation_id)
      |> Map.put(:optfile_path, "/protected/ssl-dist.conf")

    Process.put(:startup_identity, identity)
    Process.put(:startup_grant, grant)
    Process.put(:startup_manifest, manifest)

    Process.put(:startup_descriptor, %{
      grant_id: grant_id,
      generation: 1,
      controller_id: controller_id
    })

    assert :ok =
             BeamPeerGrantStartupVerifier.verify(
               manifest_path: "/protected/launch.json",
               identity_root: "/protected/node",
               descriptor_path: "/protected/descriptor.json",
               node_beam_name: node_name,
               distribution_launch: Launch,
               identity_loader: IdentityLoader,
               descriptor_loader: DescriptorLoader,
               grant_store: GrantStore,
               distribution_tls: DistributionTLS,
               current_node: node_name,
               static_targets: [],
               cookie_file: nil
             )

    assert_received {:vm_verified, ^manifest, vm_opts}
    assert vm_opts[:current_node] == node_name
    assert vm_opts[:static_targets] == []
    assert vm_opts[:cookie_file] == nil

    assert_received {:tls_verified, "/protected/ssl-dist.conf",
                     %{certfile: "/protected/node.pem"},
                     %{
                       uri_san: controller_uri,
                       certificate_serial: "100",
                       certificate_fingerprint: "sha256-controller"
                     }}

    assert controller_uri == identity.controller_uri_san

    Process.delete(:startup_manifest)
    extended_expiry_manifest = Map.put(manifest, :expires_at, ~U[2026-07-13 09:00:00.000000Z])
    Process.put(:startup_manifest, extended_expiry_manifest)

    assert {:error, :beam_distribution_launch_contract_invalid} =
             BeamPeerGrantStartupVerifier.verify(
               manifest_path: "/protected/launch.json",
               identity_root: "/protected/node",
               descriptor_path: "/protected/descriptor.json",
               node_beam_name: node_name,
               distribution_launch: Launch,
               identity_loader: IdentityLoader,
               descriptor_loader: DescriptorLoader,
               grant_store: GrantStore,
               distribution_tls: DistributionTLS,
               current_node: node_name,
               static_targets: [],
               cookie_file: nil
             )

    refute_received {:vm_verified, ^extended_expiry_manifest, _opts}
  end
end
