defmodule Orchard.ControllerInstancesTest do
  use Orchard.DataCase, async: false

  alias Orchard.ControllerInstances
  alias Orchard.ControllerInstances.ControllerInstance
  alias Orchard.NodeTrust

  setup do
    previous = Application.get_env(:orchard_controller, :control_plane)
    Application.put_env(:orchard_controller, :control_plane, role: :single_controller)

    root =
      Path.join(
        System.tmp_dir!(),
        "orchard-controller-instance-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)

    on_exit(fn ->
      File.rm_rf!(root)

      if previous do
        Application.put_env(:orchard_controller, :control_plane, previous)
      else
        Application.delete_env(:orchard_controller, :control_plane)
      end
    end)

    {:ok, root: root}
  end

  test "SPEC.md §3.3 persists one durable Controller identity without root material or path", %{
    root: root
  } do
    trust_root = Path.join(root, "node-trust")
    authorization_root = Path.join(root, "beam-authorization-root")
    now = ~U[2026-07-13 08:00:00.000000Z]

    assert {:ok, trust} = NodeTrust.initialize(root: trust_root, now: now)

    opts = [
      private_ipv4: "10.0.0.10",
      membership_scope: :remote_beam,
      node_trust_root: trust_root,
      authorization_root_path: authorization_root,
      now: now
    ]

    assert {:ok, instance} = ControllerInstances.ensure_local(opts)
    assert {:ok, ^instance} = ControllerInstances.ensure_local(opts)
    assert instance.id == trust.controller_id
    assert instance.certificate_uri_san == trust.controller_uri_san

    assert instance.canonical_beam_name ==
             "orchard_controller_#{String.replace(trust.controller_id, "-", "")}@10.0.0.10"

    assert %ControllerInstance{} = Repo.get!(ControllerInstance, instance.id)
    refute inspect(instance) =~ authorization_root
    refute inspect(instance) =~ "authorization-root.bin"
    refute inspect(instance) =~ "key:"
  end

  test "SPEC.md §8.3 local-only membership persists a complete loopback identity", %{root: root} do
    trust_root = Path.join(root, "node-trust")
    authorization_root = Path.join(root, "beam-authorization-root")
    now = ~U[2026-07-13 08:00:00.000000Z]

    assert {:ok, trust} = NodeTrust.initialize(root: trust_root, now: now)

    opts = [
      private_ipv4: "127.0.0.1",
      membership_scope: :local_only,
      node_trust_root: trust_root,
      authorization_root_path: authorization_root,
      now: now
    ]

    assert {:ok, instance} = ControllerInstances.ensure_local(opts)

    assert instance.canonical_beam_name ==
             "orchard_controller_#{String.replace(trust.controller_id, "-", "")}@127.0.0.1"

    assert {:ok, restarted} = ControllerInstances.ensure_local(opts)
    assert restarted.beam_authorization_root_id == instance.beam_authorization_root_id
    assert restarted.authorization_root_custody_ref == instance.authorization_root_custody_ref
  end

  test "SPEC.md §8.3 remote BEAM membership rejects a loopback host", %{root: root} do
    trust_root = Path.join(root, "node-trust")
    now = ~U[2026-07-13 08:00:00.000000Z]
    assert {:ok, _trust} = NodeTrust.initialize(root: trust_root, now: now)

    opts = [
      private_ipv4: "127.0.0.1",
      membership_scope: :remote_beam,
      node_trust_root: trust_root,
      authorization_root_path: Path.join(root, "beam-authorization-root"),
      now: now
    ]

    assert {:error, :beam_controller_private_ipv4_invalid} =
             ControllerInstances.ensure_local(opts)

    assert Repo.aggregate(ControllerInstance, :count) == 0
  end

  test "SPEC.md §8.3 an unresolved membership scope fails closed as configuration invalid", %{
    root: root
  } do
    trust_root = Path.join(root, "node-trust")
    now = ~U[2026-07-13 08:00:00.000000Z]
    assert {:ok, _trust} = NodeTrust.initialize(root: trust_root, now: now)

    base = [
      node_trust_root: trust_root,
      authorization_root_path: Path.join(root, "beam-authorization-root"),
      now: now
    ]

    for scope <- [[], [membership_scope: nil], [membership_scope: :single_host]],
        host <- ["127.0.0.1", "10.0.0.10"] do
      opts = base ++ scope ++ [private_ipv4: host]

      assert {:error, :beam_controller_instance_configuration_invalid} =
               ControllerInstances.ensure_local(opts)
    end

    assert Repo.aggregate(ControllerInstance, :count) == 0
  end

  test "SPEC.md §8.3 local-only membership still rejects a public host", %{root: root} do
    trust_root = Path.join(root, "node-trust")
    now = ~U[2026-07-13 08:00:00.000000Z]
    assert {:ok, _trust} = NodeTrust.initialize(root: trust_root, now: now)

    opts = [
      private_ipv4: "203.0.113.10",
      membership_scope: :local_only,
      node_trust_root: trust_root,
      authorization_root_path: Path.join(root, "beam-authorization-root"),
      now: now
    ]

    assert {:error, :beam_controller_private_ipv4_invalid} =
             ControllerInstances.ensure_local(opts)
  end

  test "SPEC.md §3.3 Controller identity initialization is idempotent without a clock override",
       %{
         root: root
       } do
    trust_root = Path.join(root, "node-trust")
    authorization_root = Path.join(root, "beam-authorization-root")

    assert {:ok, _trust} = NodeTrust.initialize(root: trust_root)

    opts = [
      private_ipv4: "10.0.0.10",
      membership_scope: :remote_beam,
      node_trust_root: trust_root,
      authorization_root_path: authorization_root
    ]

    assert {:ok, first} = ControllerInstances.ensure_local(opts)
    assert {:ok, second} = ControllerInstances.ensure_local(opts)
    assert second.id == first.id
    assert second.first_enrolled_at == first.first_enrolled_at
  end

  test "SPEC.md §8.3 local identity upsert permits other Controller identities", %{
    root: root
  } do
    trust_root = Path.join(root, "node-trust")
    authorization_root = Path.join(root, "beam-authorization-root")
    now = ~U[2026-07-13 08:00:00.000000Z]

    assert {:ok, _trust} = NodeTrust.initialize(root: trust_root, now: now)

    opts = [
      private_ipv4: "10.0.0.10",
      membership_scope: :remote_beam,
      node_trust_root: trust_root,
      authorization_root_path: authorization_root,
      now: now
    ]

    assert {:ok, _instance} = ControllerInstances.ensure_local(opts)

    %ControllerInstance{}
    |> ControllerInstance.changeset(%{
      id: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
      certificate_uri_san: "urn:orchard:controller:eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
      certificate_identifier: "serial:999",
      certificate_fingerprint_sha256: String.duplicate("e", 64),
      canonical_beam_name: "orchard_controller_eeeeeeeeeeee4eee8eeeeeeeeeeeeeee@10.0.0.11",
      beam_authorization_root_id: "ffffffff-ffff-4fff-8fff-ffffffffffff",
      authorization_root_custody_ref: "owner-only-local:ffffffff-ffff-4fff-8fff-ffffffffffff",
      status: :retired,
      first_enrolled_at: now
    })
    |> Repo.insert!()

    assert {:ok, local} = ControllerInstances.ensure_local(opts)
    assert local.id != "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"
    assert Repo.aggregate(ControllerInstance, :count) == 2
  end

  test "SPEC.md §7.3.1 local principal resolves only the locally authenticated identity", %{
    root: root
  } do
    trust_root = Path.join(root, "node-trust")
    authorization_root = Path.join(root, "beam-authorization-root")
    now = ~U[2026-07-13 08:00:00.000000Z]

    assert {:ok, trust} = NodeTrust.initialize(root: trust_root, now: now)

    opts = [
      private_ipv4: "10.0.0.10",
      membership_scope: :remote_beam,
      node_trust_root: trust_root,
      authorization_root_path: authorization_root,
      now: now
    ]

    assert {:ok, _instance} = ControllerInstances.ensure_local(opts)

    peer_id = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"

    %ControllerInstance{}
    |> ControllerInstance.changeset(%{
      id: peer_id,
      certificate_uri_san: "urn:orchard:controller:#{peer_id}",
      certificate_identifier: "serial:999",
      certificate_fingerprint_sha256: String.duplicate("e", 64),
      canonical_beam_name: "orchard_controller_eeeeeeeeeeee4eee8eeeeeeeeeeeeeee@10.0.0.11",
      beam_authorization_root_id: "ffffffff-ffff-4fff-8fff-ffffffffffff",
      authorization_root_custody_ref: "owner-only-local:ffffffff-ffff-4fff-8fff-ffffffffffff",
      status: :operational,
      first_enrolled_at: now
    })
    |> Repo.insert!()

    assert Repo.aggregate(ControllerInstance, :count) == 2
    assert {:ok, principal} = ControllerInstances.local_principal(opts)
    assert principal == trust.controller_uri_san
    refute principal == "urn:orchard:controller:#{peer_id}"
  end

  test "SPEC.md §7.3.1 local principal fails closed without local trust custody" do
    assert {:error, _reason} =
             ControllerInstances.local_principal(node_trust_root: "/nonexistent")
  end
end
