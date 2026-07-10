defmodule OrchardCLI.Commands.NodeTrustTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Orchard.Governance.AuditLog
  alias Orchard.Nodes.{ClusterIdentity, TrustAuthority}
  alias Orchard.NodeTrust
  alias Orchard.Repo
  alias OrchardCLI.Commands.Nodes

  setup do
    :ok = Sandbox.checkout(Repo)
    Sandbox.mode(Repo, {:shared, self()})

    root =
      Path.join(
        System.tmp_dir!(),
        "orchard-node-trust-cli-#{System.unique_integer([:positive])}"
      )

    previous = %{
      control_plane: Application.get_env(:orchard_controller, :control_plane),
      node_trust: Application.get_env(:orchard_controller, :node_trust)
    }

    Application.put_env(:orchard_controller, :control_plane, role: :single_controller)
    Application.put_env(:orchard_controller, :node_trust, root: root)

    on_exit(fn ->
      File.rm_rf!(root)
      restore_app_env(:orchard_controller, :control_plane, previous.control_plane)
      restore_app_env(:orchard_controller, :node_trust, previous.node_trust)
    end)

    {:ok, root: root}
  end

  test "clean-install nodes trust init is leader-gated, idempotent, and public-only", %{
    root: root
  } do
    assert {:ok, help} = Nodes.run(["trust", "init", "--help"])
    assert help =~ "orchardctl nodes trust init"

    Application.put_env(:orchard_controller, :control_plane, role: :standby)
    assert {:error, refusal, 1} = Nodes.run(["trust", "init"])
    assert refusal =~ "leader-only"
    refute File.exists?(root)
    assert Repo.aggregate(ClusterIdentity, :count, :id) == 0
    assert Repo.aggregate(TrustAuthority, :count, :id) == 0

    Application.put_env(:orchard_controller, :control_plane, role: :single_controller)

    assert {:ok, first_output} = Nodes.run(["trust", "init"])
    assert first_output =~ "Internal Node trust initialized"
    refute first_output =~ "PRIVATE KEY"
    refute first_output =~ "BEGIN CERTIFICATE"

    assert {:ok, material} = NodeTrust.public_material(root: root)
    assert first_output =~ material.cluster_id
    assert first_output =~ material.controller_id
    assert first_output =~ material.trust_authority_id
    assert first_output =~ material.ca_spki_fingerprint

    assert {:ok, second_output} = Nodes.run(["trust", "init"])
    assert second_output == first_output
    assert Repo.aggregate(ClusterIdentity, :count, :id) == 1
    assert Repo.aggregate(TrustAuthority, :count, :id) == 1

    audits =
      Repo.all(
        from(audit in AuditLog,
          where: audit.action == "node_trust.initialized"
        )
      )

    assert length(audits) == 1
    refute inspect(audits) =~ "PRIVATE KEY"
  end

  defp restore_app_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_app_env(app, key, value), do: Application.put_env(app, key, value)
end
