defmodule Orchard.BeamPeerGrants.ControllerStartupVerifierTest do
  use ExUnit.Case, async: true

  alias Orchard.BeamPeerGrants.ControllerStartupVerifier

  defmodule Launch do
    def load(_path), do: {:ok, Process.get(:controller_startup_manifest)}

    def verify_vm(manifest, opts) do
      send(self(), {:controller_vm_verified, manifest, opts})
      :ok
    end
  end

  defmodule Grants do
    def distribution_launch_material(grant_id, _opts) do
      send(self(), {:controller_scope_revalidated, grant_id})
      {:ok, Process.get(:controller_startup_material)}
    end
  end

  defmodule DistributionTLS do
    def verify_options(path, local, peer) do
      send(self(), {:controller_tls_verified, path, local, peer})
      :ok
    end
  end

  test "SPEC.md §7.5.0 reauthorizes the launch contract before Controller runtime startup" do
    scope = %{
      grant_id: "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
      generation: 1,
      cluster_id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
      controller_id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
      node_id: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
      controller_beam_name: "orchard_controller_bbbbbbbbbbbb4bbb8bbbbbbbbbbbbbbb@10.0.0.10",
      node_beam_name: "orchard_node_agent_cccccccccccc4ccc8ccccccccccccccc@10.0.0.20",
      controller_certificate_identifier: "serial:100",
      controller_certificate_fingerprint_sha256: "sha256-controller",
      node_certificate_identifier: "serial:200",
      node_certificate_fingerprint_sha256: "sha256-node",
      beam_authorization_root_id: "ffffffff-ffff-4fff-8fff-ffffffffffff"
    }

    material = %{
      scope: scope,
      local_identity: %{
        generation_id: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
        certfile: "/protected/controller.pem",
        keyfile: "/protected/controller-key.pem",
        cacertfile: "/protected/ca.pem"
      },
      peer_identity: %{
        uri_san: "urn:orchard:cluster:aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa:node:#{scope.node_id}",
        certificate_serial: "200",
        certificate_fingerprint: "sha256-node"
      }
    }

    manifest =
      scope
      |> Map.put(:role, :controller)
      |> Map.put(:local_identity_generation_id, material.local_identity.generation_id)
      |> Map.put(:optfile_path, "/protected/ssl-dist.conf")

    Process.put(:controller_startup_manifest, manifest)
    Process.put(:controller_startup_material, material)
    optfile_path = manifest.optfile_path
    local_identity = material.local_identity
    peer_identity = material.peer_identity
    grant_id = scope.grant_id

    assert :ok =
             ControllerStartupVerifier.verify(
               manifest_path: "/protected/launch.json",
               distribution_launch: Launch,
               grants: Grants,
               distribution_tls: DistributionTLS,
               current_node: scope.controller_beam_name,
               static_targets: [],
               cookie_file: nil
             )

    assert_received {:controller_scope_revalidated, ^grant_id}
    assert_received {:controller_vm_verified, ^manifest, vm_opts}
    assert vm_opts[:current_node] == scope.controller_beam_name
    assert_received {:controller_tls_verified, ^optfile_path, ^local_identity, ^peer_identity}
  end
end
