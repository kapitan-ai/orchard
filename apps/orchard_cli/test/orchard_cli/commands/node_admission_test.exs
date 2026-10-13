defmodule OrchardCLI.Commands.NodeAdmissionTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Orchard.ControllerInstances.ControllerInstance
  alias Orchard.NodeAdmissionPreauthorizations
  alias Orchard.NodeEnrollments
  alias Orchard.NodeTrust
  alias Orchard.Repo
  alias OrchardCLI.Commands.NodeAdmission

  setup do
    :ok = Sandbox.checkout(Repo)
    Sandbox.mode(Repo, {:shared, self()})

    root =
      Path.join(
        System.tmp_dir!(),
        "orchard-node-admission-cli-#{System.unique_integer([:positive])}"
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

    now = ~U[2026-09-21 12:00:00Z]
    assert {:ok, trust} = NodeTrust.initialize(root: root, actor_id: "kap-109-cli-test")
    insert_controller!(trust.controller_id, now)

    {:ok, now: now, trust: trust}
  end

  test "mode mutation requires exact confirmation and renders stable JSON" do
    args = ["mode", "set", "enrollment-preauthorized", "--reason", "authorize exact joins"]
    assert {:error, preview, 2} = NodeAdmission.run(args)
    digest = preview_digest(preview)

    assert {:ok, json} = NodeAdmission.run(args ++ ["--confirm-digest", digest, "--json"])

    assert Jason.decode!(json) == %{
             "action" => "node_admission.mode_changed",
             "mode" => "enrollment_preauthorized",
             "version" => 2
           }

    assert NodeAdmissionPreauthorizations.get_mode().mode == :enrollment_preauthorized
  end

  test "revocation requires exact confirmation and reports only bounded evidence", %{
    now: now,
    trust: trust
  } do
    enable_preauthorized_mode!(now)
    preauthorization = issue_preauthorization!(trust, now)

    args = [
      "preauthorization",
      "revoke",
      preauthorization.id,
      "--reason",
      "bundle custody lost",
      "--json"
    ]

    assert {:error, preview_json, 2} = NodeAdmission.run(args)
    digest = preview_json |> Jason.decode!() |> Map.fetch!("preview_digest")

    assert {:ok, result_json} = NodeAdmission.run(args ++ ["--confirm-digest", digest])

    assert Jason.decode!(result_json) == %{
             "action" => "node_admission.preauthorization_revoked",
             "preauthorization_id" => preauthorization.id,
             "state" => "revoked"
           }

    assert {:ok, revoked} = NodeAdmissionPreauthorizations.fetch(preauthorization.id)
    assert revoked.state == :revoked
    refute result_json =~ "orch_enr_"
  end

  test "invalid input fails before database mutation" do
    assert {:error, message, 1} = NodeAdmission.run(["mode", "set", "open", "--reason", "x"])
    assert message =~ "invalid admission mode"

    assert {:error, message, 1} =
             NodeAdmission.run(["preauthorization", "revoke", "not-a-uuid", "--reason", "x"])

    assert message =~ "invalid preauthorization ID"
    assert NodeAdmissionPreauthorizations.get_mode().mode == :manual
  end

  defp enable_preauthorized_mode!(now) do
    attrs = %{actor_type: "operator", actor_id: "test", reason: "test issuance"}

    assert {:ok, preview} =
             NodeAdmissionPreauthorizations.preview_mode_change(:enrollment_preauthorized, attrs)

    assert {:ok, _mode} =
             NodeAdmissionPreauthorizations.change_mode(:enrollment_preauthorized, attrs,
               confirmation_digest: preview.digest,
               now: now
             )
  end

  defp issue_preauthorization!(trust, now) do
    preview_attrs = %{
      id: Ecto.UUID.generate(),
      enrollment_id: Ecto.UUID.generate(),
      node_id: Ecto.UUID.generate(),
      cluster_id: trust.cluster_id,
      issuing_controller_id: trust.controller_id,
      actor_type: "operator",
      actor_id: "test",
      expires_at: DateTime.add(now, 600, :second),
      pool_id: "general",
      pool_revision: "1",
      routing_policy_id: "default",
      routing_policy_revision: "1",
      controller_dispatch_ceiling: 1,
      capacity_policy_reason: "bounded CLI test",
      bound_predicates: %{},
      confirmation_evidence: %{"bundle_theft_consequence_confirmed" => true}
    }

    assert {:ok, preview} = NodeAdmissionPreauthorizations.preview_issuance(preview_attrs)

    assert {:ok, result} =
             NodeEnrollments.create(
               %{
                 cluster_id: trust.cluster_id,
                 expected_controller_id: trust.controller_id,
                 trust_authority_id: trust.trust_authority_id,
                 creator_type: "operator",
                 creator_id: "test",
                 expires_at: DateTime.add(now, 600, :second),
                 node: %{display_name: "preauthorized-cli-test"}
               },
               now: now,
               preauthorization_preview: preview,
               preauthorization_confirmation_digest: preview.digest
             )

    result.preauthorization
  end

  defp insert_controller!(controller_id, now) do
    compact_id = String.replace(controller_id, "-", "")

    %ControllerInstance{}
    |> ControllerInstance.changeset(%{
      id: controller_id,
      certificate_uri_san: "urn:orchard:controller:#{controller_id}",
      certificate_identifier: "serial:kap-109-cli",
      certificate_fingerprint_sha256: Base.encode16(:crypto.strong_rand_bytes(32), case: :lower),
      canonical_beam_name: "orchard_controller_#{compact_id}@10.0.0.10",
      beam_authorization_root_id: Ecto.UUID.generate(),
      authorization_root_custody_ref: "owner-only-local:kap-109-cli",
      status: :operational,
      first_enrolled_at: now
    })
    |> Repo.insert!()
  end

  defp preview_digest(message) do
    [digest] =
      Regex.run(~r/Preview digest: (sha256-[A-Za-z0-9_-]+)/, message, capture: :all_but_first)

    digest
  end

  defp restore_app_env(application, key, nil), do: Application.delete_env(application, key)
  defp restore_app_env(application, key, value), do: Application.put_env(application, key, value)
end
