defmodule Orchard.BeamPeerGrants.ControllerPreflightTest do
  use ExUnit.Case, async: true

  alias Orchard.BeamPeerGrants.ControllerPreflight

  defmodule Grants do
    def distribution_launch_material(grant_id, opts) do
      send(self(), {:launch_material_loaded, grant_id, opts})
      {:ok, Process.get(:controller_launch_material)}
    end
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
      send(self(), {:launch_contract_written, path, attrs})
      :ok
    end
  end

  test "SPEC.md §7.5.0 prepares the Controller exact-pair Distribution launch" do
    grant_id = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
    optfile_path = "/protected/controller/ssl-dist.conf"
    manifest_path = "/protected/controller/launch.json"

    material = %{
      local_identity: %{
        generation_id: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
        certfile: "/protected/controller.pem",
        keyfile: "/protected/controller-key.pem",
        cacertfile: "/protected/ca.pem"
      },
      peer_identity: %{
        uri_san:
          "urn:orchard:cluster:aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa:node:cccccccc-cccc-4ccc-8ccc-cccccccccccc",
        certificate_serial: "200",
        certificate_fingerprint: "sha256-node"
      },
      scope: %{
        grant_id: grant_id,
        generation: 1,
        contract_version: 1,
        purpose: "runtime_endpoint",
        cluster_id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        controller_id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
        node_id: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
        controller_beam_name: "orchard_controller_bbbbbbbbbbbb4bbb8bbbbbbbbbbbbbbb@10.0.0.10",
        node_beam_name: "orchard_node_agent_cccccccccccc4ccc8ccccccccccccccc@10.0.0.20",
        controller_certificate_identifier: "serial:100",
        controller_certificate_fingerprint_sha256: "sha256-controller",
        node_certificate_identifier: "serial:200",
        node_certificate_fingerprint_sha256: "sha256-node",
        beam_authorization_root_id: "ffffffff-ffff-4fff-8fff-ffffffffffff",
        not_before_at: ~U[2026-07-13 00:00:00Z],
        expires_at: ~U[2026-08-12 00:00:00Z]
      }
    }

    Process.put(:controller_launch_material, material)
    local_identity = material.local_identity
    peer_identity = material.peer_identity

    assert {:ok, %{grant_id: ^grant_id}} =
             ControllerPreflight.prepare(
               current_node: :nonode@nohost,
               grant_id: grant_id,
               optfile_path: optfile_path,
               manifest_path: manifest_path,
               grants: Grants,
               distribution_tls: DistributionTLS,
               distribution_launch: DistributionLaunch
             )

    assert_received {:launch_material_loaded, ^grant_id, _opts}
    assert_received {:tls_options_written, ^optfile_path, ^local_identity, ^peer_identity}

    assert_received {:tls_options_verified, ^optfile_path, ^local_identity, ^peer_identity}

    assert_received {:launch_contract_written, ^manifest_path, launch}
    assert launch.role == :controller
    assert launch.grant_id == grant_id
    assert launch.optfile_path == optfile_path
    assert launch.local_identity_generation_id == material.local_identity.generation_id
  end
end
