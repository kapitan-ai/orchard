defmodule Orchard.Node.BeamPeerGrantPreflightTest do
  use ExUnit.Case, async: true

  alias Orchard.Node.BeamPeerGrantPreflight

  defmodule Bootstrap do
    def bootstrap(opts) do
      send(self(), {:bootstrap_opts, opts})
      {:ok, %{grant_id: "dddddddd-dddd-4ddd-8ddd-dddddddddddd"}}
    end
  end

  defmodule IdentityLoader do
    def load_registered_identity(_root, require_controller_certificate: true) do
      {:ok, Process.get(:preflight_identity)}
    end
  end

  defmodule DescriptorLoader do
    def load(_path), do: {:ok, Process.get(:preflight_descriptor)}
  end

  defmodule GrantStore do
    def load(_root, _identity, _node_name), do: {:ok, Process.get(:preflight_grant)}
    def ensure_current(_grant), do: :ok
  end

  defmodule CertificateIdentity do
    def from_pem("node-certificate"), do: {:ok, Process.get(:node_certificate)}
    def from_pem("controller-certificate"), do: {:ok, Process.get(:controller_certificate)}
  end

  defmodule DistributionTLS do
    def write_options(path, local, peer) do
      send(self(), {:tls_options_written, path, local, peer})
      :ok
    end

    def verify_options(path, local, peer) do
      send(self(), {:tls_options_verified, path, local, peer})
      :ok
    end
  end

  defmodule DistributionLaunch do
    def write(path, attrs) do
      send(self(), {:launch_written, path, attrs})
      :ok
    end
  end

  test "SPEC.md §7.5.0 retrieves and stores the grant only in a non-distributed preflight" do
    assert {:ok, %{grant_id: "dddddddd-dddd-4ddd-8ddd-dddddddddddd"}} =
             BeamPeerGrantPreflight.retrieve_and_store(
               current_node: :nonode@nohost,
               bootstrap: Bootstrap,
               identity_root: "/protected/node",
               descriptor_path: "/protected/descriptor.json",
               node_beam_name: "orchard_node_agent_cccccccccccc4ccc8ccccccccccccccc@10.0.0.20"
             )

    assert_received {:bootstrap_opts, opts}
    assert opts[:cookie_installer] == BeamPeerGrantPreflight.NoopCookieInstaller
  end

  test "SPEC.md §7.5.0 prepares exact Node TLS Distribution from stored grant custody" do
    root =
      Path.join(
        System.tmp_dir!(),
        "orchard-node-preflight-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)

    node_certfile = Path.join(root, "node.pem")
    controller_certfile = Path.join(root, "controller.pem")
    File.write!(node_certfile, "node-certificate")
    File.write!(controller_certfile, "controller-certificate")

    node_id = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
    controller_id = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
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
      certificate_identifier: "nodecert-local-binding",
      certificate_serial: "200",
      certificate_fingerprint: "sha256-node",
      controller_certificate_identifier: "serial:100",
      controller_certificate_fingerprint: "sha256-controller",
      certfile: node_certfile,
      keyfile: Path.join(root, "node-key.pem"),
      cacertfile: Path.join(root, "ca.pem"),
      controller_certfile: controller_certfile
    }

    descriptor = %{
      grant_id: "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
      generation: 1,
      controller_id: controller_id
    }

    grant = %{
      grant_id: descriptor.grant_id,
      generation: descriptor.generation,
      contract_version: 1,
      purpose: "runtime_endpoint",
      cluster_id: identity.cluster_id,
      controller_id: controller_id,
      node_id: node_id,
      controller_beam_name: controller_name,
      node_beam_name: node_name,
      controller_certificate_identifier: identity.controller_certificate_identifier,
      controller_certificate_fingerprint_sha256: identity.controller_certificate_fingerprint,
      node_certificate_identifier: identity.certificate_identifier,
      node_certificate_fingerprint_sha256: identity.certificate_fingerprint,
      beam_authorization_root_id: "ffffffff-ffff-4fff-8fff-ffffffffffff",
      not_before_at: ~U[2026-07-13 00:00:00Z],
      expires_at: ~U[2026-08-12 00:00:00Z]
    }

    Process.put(:preflight_identity, identity)
    Process.put(:preflight_descriptor, descriptor)
    Process.put(:preflight_grant, grant)

    Process.put(:node_certificate, %{
      serial: "200",
      fingerprint: "sha256-node",
      uri_sans: [identity.node_uri_san],
      extended_key_usages: [:server_auth, :client_auth]
    })

    Process.put(:controller_certificate, %{
      serial: "100",
      fingerprint: "sha256-controller",
      uri_sans: [identity.controller_uri_san],
      extended_key_usages: [:server_auth, :client_auth]
    })

    optfile_path = Path.join(root, "ssl-dist.conf")
    manifest_path = Path.join(root, "launch.json")

    assert {:ok, %{grant_id: grant_id}} =
             BeamPeerGrantPreflight.prepare_distribution(
               current_node: :nonode@nohost,
               identity_root: root,
               descriptor_path: Path.join(root, "descriptor.json"),
               node_beam_name: node_name,
               optfile_path: optfile_path,
               manifest_path: manifest_path,
               identity_loader: IdentityLoader,
               descriptor_loader: DescriptorLoader,
               grant_store: GrantStore,
               certificate_identity: CertificateIdentity,
               distribution_tls: DistributionTLS,
               distribution_launch: DistributionLaunch
             )

    assert grant_id == grant.grant_id

    assert_received {:tls_options_written, ^optfile_path, %{certfile: ^node_certfile},
                     %{
                       uri_san: controller_uri,
                       certificate_serial: "100",
                       certificate_fingerprint: "sha256-controller"
                     }}

    assert controller_uri == identity.controller_uri_san
    assert_received {:tls_options_verified, ^optfile_path, _local, _peer}
    assert_received {:launch_written, ^manifest_path, %{role: :node_agent} = launch}
    assert launch.grant_id == grant.grant_id
    assert launch.local_identity_generation_id == identity.generation_id
  end
end
