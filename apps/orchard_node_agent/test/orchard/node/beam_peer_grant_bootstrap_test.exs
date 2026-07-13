defmodule Orchard.Node.BeamPeerGrantBootstrapTest do
  use ExUnit.Case, async: true

  alias Orchard.Cluster.V1.RetrieveBeamPeerGrantRequest
  alias Orchard.Node.BeamPeerGrantBootstrap

  defmodule IdentityLoader do
    def load_registered_identity(root, opts) do
      send(self(), {:identity_loaded, root, opts})
      {:ok, Process.get(:bootstrap_identity)}
    end
  end

  defmodule GrantStore do
    def load(root, identity, node_name) do
      send(self(), {:grant_store_loaded, root, identity, node_name})
      {:error, :beam_peer_grant_missing}
    end

    def ensure_current(_grant), do: :ok
  end

  defmodule GrantClient do
    def retrieve_and_install(root, identity, node_name, target, request) do
      send(self(), {:grant_retrieved, root, identity, node_name, target, request})
      {:ok, Process.get(:bootstrap_grant)}
    end
  end

  defmodule ExistingGrantStore do
    def load(root, identity, node_name) do
      send(self(), {:existing_grant_loaded, root, identity, node_name})
      {:ok, Process.get(:bootstrap_grant)}
    end

    def ensure_current(_grant), do: :ok
  end

  defmodule UnexpectedGrantClient do
    def retrieve_and_install(_root, _identity, _node_name, _target, _request) do
      send(self(), :unexpected_grant_retrieval)
      {:error, :beam_peer_grant_control_unavailable}
    end
  end

  defmodule CookieInstaller do
    def install(grant, node_name) do
      send(self(), {:cookie_installed, grant, node_name})
      :ok
    end
  end

  test "SPEC.md §7.5.0 bootstraps one exact grant from an owner-only nonsecret descriptor" do
    root =
      Path.join(
        System.tmp_dir!(),
        "orchard-node-peer-grant-bootstrap-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)

    descriptor_path = Path.join(root, "peer-grant-descriptor.json")
    controller_id = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    grant_id = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
    node_name = "orchard_node_agent_cccccccccccc4ccc8ccccccccccccccc@10.0.0.20"

    File.write!(
      descriptor_path,
      Jason.encode!(%{
        "grant_id" => grant_id,
        "generation" => 1,
        "controller_id" => controller_id,
        "control_endpoint" => "10.0.0.10:50072"
      })
    )

    File.chmod!(descriptor_path, 0o600)

    identity = %{
      controller_id: controller_id,
      node_id: "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
    }

    grant = %{
      grant_id: grant_id,
      generation: 1,
      controller_id: controller_id,
      controller_beam_name: "orchard_controller_bbbbbbbbbbbb4bbb8bbbbbbbbbbbbbbb@10.0.0.10",
      node_beam_name: node_name,
      encoded_secret: Base.url_encode64(:binary.copy(<<5>>, 32), padding: false)
    }

    Process.put(:bootstrap_identity, identity)
    Process.put(:bootstrap_grant, grant)

    assert {:ok, ^grant} =
             BeamPeerGrantBootstrap.bootstrap(
               identity_root: root,
               descriptor_path: descriptor_path,
               node_beam_name: node_name,
               identity_loader: IdentityLoader,
               grant_store: GrantStore,
               grant_client: GrantClient,
               cookie_installer: CookieInstaller
             )

    assert_received {:identity_loaded, ^root, [require_controller_certificate: true]}
    assert_received {:grant_store_loaded, ^root, ^identity, ^node_name}

    assert_received {:grant_retrieved, ^root, ^identity, ^node_name, "10.0.0.10:50072",
                     %RetrieveBeamPeerGrantRequest{
                       grant_id: ^grant_id,
                       generation: 1,
                       controller_id: ^controller_id
                     }}

    assert_received {:cookie_installed, ^grant, ^node_name}
  end

  test "SPEC.md §7.5.0 restart reuses the exact owner-only grant without control delivery" do
    root =
      Path.join(
        System.tmp_dir!(),
        "orchard-node-peer-grant-restart-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)

    descriptor_path = Path.join(root, "peer-grant-descriptor.json")
    controller_id = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    grant_id = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
    node_name = "orchard_node_agent_cccccccccccc4ccc8ccccccccccccccc@10.0.0.20"

    File.write!(
      descriptor_path,
      Jason.encode!(%{
        "grant_id" => grant_id,
        "generation" => 1,
        "controller_id" => controller_id,
        "control_endpoint" => "10.0.0.10:50072"
      })
    )

    File.chmod!(descriptor_path, 0o600)

    identity = %{
      controller_id: controller_id,
      node_id: "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
    }

    grant = %{
      grant_id: grant_id,
      generation: 1,
      controller_id: controller_id,
      controller_beam_name: "orchard_controller_bbbbbbbbbbbb4bbb8bbbbbbbbbbbbbbb@10.0.0.10",
      node_beam_name: node_name,
      encoded_secret: Base.url_encode64(:binary.copy(<<5>>, 32), padding: false)
    }

    Process.put(:bootstrap_identity, identity)
    Process.put(:bootstrap_grant, grant)

    assert {:ok, ^grant} =
             BeamPeerGrantBootstrap.bootstrap(
               identity_root: root,
               descriptor_path: descriptor_path,
               node_beam_name: node_name,
               identity_loader: IdentityLoader,
               grant_store: ExistingGrantStore,
               grant_client: UnexpectedGrantClient,
               cookie_installer: CookieInstaller
             )

    assert_received {:existing_grant_loaded, ^root, ^identity, ^node_name}
    assert_received {:cookie_installed, ^grant, ^node_name}
    refute_received :unexpected_grant_retrieval
  end

  test "SPEC.md §7.5.0 distributed startup forbids late control retrieval" do
    root =
      Path.join(
        System.tmp_dir!(),
        "orchard-node-peer-grant-load-only-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)

    descriptor_path = Path.join(root, "peer-grant-descriptor.json")
    controller_id = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    grant_id = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
    node_name = "orchard_node_agent_cccccccccccc4ccc8ccccccccccccccc@10.0.0.20"

    File.write!(
      descriptor_path,
      Jason.encode!(%{
        "grant_id" => grant_id,
        "generation" => 1,
        "controller_id" => controller_id,
        "control_endpoint" => "10.0.0.10:50072"
      })
    )

    File.chmod!(descriptor_path, 0o600)

    Process.put(:bootstrap_identity, %{
      controller_id: controller_id,
      node_id: "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
    })

    assert {:error, :beam_peer_grant_missing} =
             BeamPeerGrantBootstrap.bootstrap(
               identity_root: root,
               descriptor_path: descriptor_path,
               node_beam_name: node_name,
               retrieval: :forbid,
               identity_loader: IdentityLoader,
               grant_store: GrantStore,
               grant_client: UnexpectedGrantClient,
               cookie_installer: CookieInstaller
             )

    refute_received :unexpected_grant_retrieval
  end

  test "SPEC.md §7.5.0 bootstrap rejects a Node name not derived from registered identity" do
    root =
      Path.join(
        System.tmp_dir!(),
        "orchard-node-peer-grant-name-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)

    descriptor_path = Path.join(root, "peer-grant-descriptor.json")
    controller_id = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    grant_id = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
    wrong_name = "orchard_node_agent_eeeeeeeeeeee4eee8eeeeeeeeeeeeeee@10.0.0.20"

    File.write!(
      descriptor_path,
      Jason.encode!(%{
        "grant_id" => grant_id,
        "generation" => 1,
        "controller_id" => controller_id,
        "control_endpoint" => "10.0.0.10:50072"
      })
    )

    File.chmod!(descriptor_path, 0o600)

    Process.put(:bootstrap_identity, %{
      controller_id: controller_id,
      node_id: "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
    })

    Process.put(:bootstrap_grant, %{
      grant_id: grant_id,
      generation: 1,
      controller_id: controller_id,
      node_beam_name: wrong_name
    })

    assert {:error, :beam_peer_credential_mismatch} =
             BeamPeerGrantBootstrap.bootstrap(
               identity_root: root,
               descriptor_path: descriptor_path,
               node_beam_name: wrong_name,
               identity_loader: IdentityLoader,
               grant_store: ExistingGrantStore,
               grant_client: UnexpectedGrantClient,
               cookie_installer: CookieInstaller
             )

    refute_received {:cookie_installed, _grant, _node_name}
  end
end
