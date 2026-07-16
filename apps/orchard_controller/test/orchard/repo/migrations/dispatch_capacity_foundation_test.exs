defmodule Orchard.Repo.Migrations.DispatchCapacityFoundationTest do
  use Orchard.DataCase, async: false

  alias Orchard.DispatchCapacity
  alias Orchard.DispatchCapacity.{Authority, CapacityEvidence, Policy}

  @migration_path Path.expand(
                    "../../../../priv/repo/migrations/20260716010000_dispatch_capacity_foundation.exs",
                    __DIR__
                  )

  Code.require_file(@migration_path)

  alias Orchard.Repo.Migrations.DispatchCapacityFoundation, as: Migration

  test "SPEC.md section 13.2 seeds one pre-cutover authority on an empty cluster" do
    assert %Authority{
             singleton: true,
             enforcement_phase: :pre_cutover,
             required_contract_version: 1,
             cutover_by_actor_type: nil,
             cutover_by_actor_id: nil,
             cutover_at: nil,
             cutover_reason: nil
           } = DispatchCapacity.get_authority()

    assert %{rows: [[1]]} = Repo.query!("SELECT count(*) FROM dispatch_capacity_authority")
  end

  test "SPEC.md section 13.2 backfills only non-removed Nodes with prior admitted decisions" do
    set_admission_fence("DISABLE")

    qualifying_id = insert_node("qualifying", "active")
    missing_proof_id = insert_node("missing-proof", "active")
    removed_id = insert_node("removed", "removed")
    skewed_timestamp_id = insert_node("skewed-timestamp", "active")

    qualifying_decision_id =
      insert_admission_decision(qualifying_id, ~U[2026-07-15 23:59:59.000000Z])

    _removed_decision_id =
      insert_admission_decision(removed_id, ~U[2026-07-15 23:59:59.000000Z])

    _skewed_timestamp_decision_id =
      insert_admission_decision(skewed_timestamp_id, ~U[2099-07-16 01:00:00.000000Z])

    Repo.query!(Migration.backfill_sql())
    set_admission_fence("ENABLE")

    assert %Policy{
             policy_state: :shadow_legacy,
             controller_dispatch_ceiling: nil,
             admission_decision_id: ^qualifying_decision_id,
             legacy_admitted_at: ~U[2026-07-15 23:59:59.000000Z]
           } = DispatchCapacity.get_policy(qualifying_id)

    assert is_nil(DispatchCapacity.get_policy(missing_proof_id))
    assert is_nil(DispatchCapacity.get_policy(removed_id))

    assert %Policy{policy_state: :shadow_legacy} =
             DispatchCapacity.get_policy(skewed_timestamp_id)
  end

  test "policy constraints preserve explicit zero and reject duplicates or invalid provenance" do
    node_id = insert_node("explicit-zero", "admitted")
    decision_id = insert_admission_decision(node_id, ~U[2026-07-15 20:00:00.000000Z])
    approved_at = ~U[2026-07-16 02:00:00.000000Z]

    assert {:ok, %Policy{controller_dispatch_ceiling: 0}} =
             %Policy{}
             |> Policy.approved_explicit_changeset(%{
               node_id: node_id,
               admission_decision_id: decision_id,
               controller_dispatch_ceiling: 0,
               approved_by_actor_type: "operator",
               approved_by_actor_id: "operator-1",
               approved_at: approved_at,
               approval_reason: "hold dispatch"
             })
             |> Repo.insert()

    assert {:error, duplicate_changeset} =
             %Policy{}
             |> Policy.approved_explicit_changeset(%{
               node_id: node_id,
               admission_decision_id: decision_id,
               controller_dispatch_ceiling: 1,
               approved_by_actor_type: "operator",
               approved_by_actor_id: "operator-1",
               approved_at: approved_at,
               approval_reason: "duplicate"
             })
             |> Repo.insert()

    duplicate_errors = errors_on(duplicate_changeset)

    assert "has already been taken" in (Map.get(duplicate_errors, :node_id, []) ++
                                          Map.get(duplicate_errors, :admission_decision_id, []))

    invalid_node_id = insert_node("negative-ceiling", "admitted")

    invalid_decision_id =
      insert_admission_decision(invalid_node_id, ~U[2026-07-15 22:00:00.000000Z])

    invalid_changeset =
      Policy.approved_explicit_changeset(%Policy{}, %{
        node_id: invalid_node_id,
        admission_decision_id: invalid_decision_id,
        controller_dispatch_ceiling: -1,
        approved_by_actor_type: "operator",
        approved_by_actor_id: "operator-1",
        approved_at: approved_at,
        approval_reason: "invalid"
      })

    refute invalid_changeset.valid?

    assert "must be greater than or equal to 0" in errors_on(invalid_changeset).controller_dispatch_ceiling

    assert_constraint_violation(
      :node_dispatch_capacity_policies_state_provenance,
      """
      INSERT INTO node_dispatch_capacity_policies (
        node_id, admission_decision_id, policy_state, controller_dispatch_ceiling,
        legacy_admitted_at, version, inserted_at, updated_at
      )
      VALUES ($1, $2, 'shadow_legacy', 0, $3, 1, NOW(), NOW())
      """,
      [invalid_node_id, invalid_decision_id, approved_at]
    )

    assert_constraint_violation(
      :node_dispatch_capacity_policies_state_provenance,
      """
      INSERT INTO node_dispatch_capacity_policies (
        node_id, admission_decision_id, policy_state, controller_dispatch_ceiling,
        version, inserted_at, updated_at
      )
      VALUES ($1, $2, 'approved_explicit', 1, 1, NOW(), NOW())
      """,
      [invalid_node_id, invalid_decision_id]
    )

    assert {:ok, %Policy{}} =
             %Policy{}
             |> Policy.approved_explicit_changeset(%{
               node_id: invalid_node_id,
               admission_decision_id: invalid_decision_id,
               controller_dispatch_ceiling: 1,
               approved_by_actor_type: "operator",
               approved_by_actor_id: "operator-1",
               approved_at: approved_at,
               approval_reason: "valid follow-up"
             })
             |> Repo.insert()
  end

  test "authority and evidence reject invalid state-value combinations" do
    assert_constraint_violation(
      :dispatch_capacity_authority_phase_provenance,
      """
      UPDATE dispatch_capacity_authority
      SET enforcement_phase = 'enforcing', updated_at = NOW()
      WHERE singleton = true
      """,
      []
    )

    node_id = insert_node("invalid-evidence", "admitted")

    invalid_evidence =
      CapacityEvidence.changeset(%CapacityEvidence{}, %{
        node_id: node_id,
        runtime_concurrency_limit: 0,
        active_request_count: 0,
        validity: :valid,
        observed_at: ~U[2026-07-16 02:00:00.000000Z]
      })

    refute invalid_evidence.valid?

    assert_constraint_violation(
      :node_runtime_capacity_evidence_value_validity,
      """
      INSERT INTO node_runtime_capacity_evidence (
        node_id, runtime_concurrency_limit, active_request_count, validity,
        observed_at, inserted_at, updated_at
      )
      VALUES ($1, 0, 0, 'valid', NOW(), NOW(), NOW())
      """,
      [node_id]
    )

    missing_with_malformed_value =
      CapacityEvidence.changeset(%CapacityEvidence{}, %{
        node_id: node_id,
        runtime_concurrency_limit: -1,
        active_request_count: nil,
        validity: :missing,
        observed_at: ~U[2026-07-16 02:00:00.000000Z]
      })

    refute missing_with_malformed_value.valid?
  end

  test "policy admission provenance rejects another Node and non-admitted decisions" do
    node_id = insert_node("policy-node", "admitted")
    other_node_id = insert_node("other-policy-node", "admitted")
    admitted_id = insert_admission_decision(other_node_id, ~U[2026-07-15 20:00:00.000000Z])

    assert_constraint_violation(
      :node_dispatch_capacity_policies_admitted_decision,
      explicit_policy_insert_sql(),
      [node_id, admitted_id]
    )

    assert {:ok, %Policy{}} =
             %Policy{}
             |> Policy.approved_explicit_changeset(%{
               node_id: other_node_id,
               admission_decision_id: admitted_id,
               controller_dispatch_ceiling: 1,
               approved_by_actor_type: "operator",
               approved_by_actor_id: "operator-1",
               approved_at: ~U[2026-07-16 02:00:00.000000Z],
               approval_reason: "valid provenance"
             })
             |> Repo.insert()

    rejected_id =
      insert_admission_decision(
        node_id,
        ~U[2026-07-15 21:00:00.000000Z],
        "rejected"
      )

    assert_constraint_violation(
      :node_dispatch_capacity_policies_admitted_decision,
      explicit_policy_insert_sql(),
      [node_id, rejected_id]
    )
  end

  test "post-migration admission fails closed unless its explicit policy commits with it" do
    node_id = insert_node("admission-fence", "registered")

    assert_raise Postgrex.Error, ~r/node_admission_decisions_dispatch_capacity_policy/, fn ->
      Repo.transaction(
        fn ->
          insert_admission_decision(node_id, ~U[2026-07-16 02:00:00.000000Z])

          Repo.query!(
            "SET CONSTRAINTS node_admission_decisions_require_dispatch_capacity_policy IMMEDIATE"
          )
        end,
        mode: :savepoint
      )
    end

    assert {:ok, _result} =
             Repo.transaction(fn ->
               decision_id =
                 insert_admission_decision(node_id, ~U[2026-07-16 02:00:01.000000Z])

               Repo.query!(explicit_policy_insert_sql(), dump_uuids([node_id, decision_id]))

               Repo.query!(
                 "SET CONSTRAINTS node_admission_decisions_require_dispatch_capacity_policy IMMEDIATE"
               )
             end)

    assert %Policy{policy_state: :approved_explicit} = DispatchCapacity.get_policy(node_id)
  end

  defp insert_node(label, state) do
    id = Ecto.UUID.generate()

    Repo.query!(
      """
      INSERT INTO nodes (
        id, hostname, display_name, advertise_addr, rpc_port, state, health,
        capabilities, tool_readiness, inserted_at, updated_at
      )
      VALUES ($1, $2, $3, $4, 9444, $5::node_state, 'healthy', '{}'::jsonb,
        '{}'::jsonb, NOW(), NOW())
      """,
      [Ecto.UUID.dump!(id), "#{label}.local", "#{label}-#{id}", unique_address(id), state]
    )

    id
  end

  defp insert_admission_decision(node_id, committed_at, decision \\ "admitted") do
    id = Ecto.UUID.generate()

    Repo.query!(
      """
      INSERT INTO node_admission_decisions (
        id, node_id, decision, actor_type, observed_identity, metadata,
        decided_at, inserted_at
      )
      VALUES ($1, $2, $3::node_admission_decision_kind, 'operator', '{}'::jsonb,
        '{}'::jsonb, $4, $4)
      """,
      [Ecto.UUID.dump!(id), Ecto.UUID.dump!(node_id), decision, committed_at]
    )

    id
  end

  defp unique_address(id) do
    <<a, b, c, _rest::binary>> = Ecto.UUID.dump!(id)
    "10.#{rem(a, 250) + 1}.#{rem(b, 250) + 1}.#{rem(c, 250) + 1}"
  end

  defp assert_constraint_violation(constraint, sql, params) do
    assert_raise Postgrex.Error, ~r/#{constraint}/, fn ->
      Repo.transaction(fn -> Repo.query!(sql, dump_uuids(params)) end, mode: :savepoint)
    end
  end

  defp dump_uuids(params) do
    Enum.map(params, fn value ->
      case Ecto.UUID.cast(value) do
        {:ok, uuid} -> Ecto.UUID.dump!(uuid)
        :error -> value
      end
    end)
  end

  defp explicit_policy_insert_sql do
    """
    INSERT INTO node_dispatch_capacity_policies (
      node_id, admission_decision_id, policy_state, controller_dispatch_ceiling,
      approved_by_actor_type, approved_by_actor_id, approved_at, approval_reason,
      version, inserted_at, updated_at
    )
    VALUES ($1, $2, 'approved_explicit', 1, 'operator', 'operator-1', NOW(),
      'capacity approval', 1, NOW(), NOW())
    """
  end

  defp set_admission_fence(action) when action in ["DISABLE", "ENABLE"] do
    Repo.query!(
      "ALTER TABLE node_admission_decisions #{action} TRIGGER " <>
        "node_admission_decisions_require_dispatch_capacity_policy"
    )
  end
end
