defmodule Orchard.Repo.Migrations.CircuitBreakerFoundation do
  use Ecto.Migration

  def change do
    create table(:circuit_breakers, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:kind, :text, null: false)
      add(:node_id, references(:nodes, type: :binary_id, on_delete: :nothing), null: false)
      add(:model_id, :binary_id)
      add(:state, :text, null: false, default: "closed")
      add(:generation, :bigint, null: false, default: 0)
      add(:opened_at, :utc_datetime_usec)
      add(:suppressed_until, :utc_datetime_usec)
      add(:last_cleared_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(:circuit_breakers, [:node_id],
        where: "kind = 'node'",
        name: :circuit_breakers_node_identity
      )
    )

    create(
      unique_index(:circuit_breakers, [:node_id, :model_id],
        where: "kind = 'placement'",
        name: :circuit_breakers_placement_identity
      )
    )

    create(
      constraint(:circuit_breakers, :circuit_breakers_identity_valid,
        check:
          "(kind = 'node' AND model_id IS NULL) OR " <>
            "(kind = 'placement' AND model_id IS NOT NULL)"
      )
    )

    create(
      constraint(:circuit_breakers, :circuit_breakers_state_valid,
        check:
          "(state = 'closed' AND suppressed_until IS NULL) OR " <>
            "(state = 'open' AND opened_at IS NOT NULL AND suppressed_until IS NOT NULL)"
      )
    )

    create(
      constraint(:circuit_breakers, :circuit_breakers_generation_non_negative,
        check: "generation >= 0"
      )
    )

    create table(:circuit_breaker_failures, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(
        :breaker_id,
        references(:circuit_breakers, type: :binary_id, on_delete: :nothing),
        null: false
      )

      add(:node_id, :binary_id, null: false)
      add(:model_id, :binary_id)
      add(:failure_class, :text, null: false)
      add(:occurred_at, :utc_datetime_usec, null: false)
      add(:generation, :bigint, null: false)
      add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("NOW()"))
    end

    create(index(:circuit_breaker_failures, [:breaker_id, :generation, :occurred_at]))

    create(
      constraint(:circuit_breaker_failures, :circuit_breaker_failures_target_valid,
        check:
          "(failure_class IN ('pre_acceptance_unavailable', 'worker_or_node_loss') AND " <>
            "model_id IS NULL) OR " <>
            "(failure_class = 'model_load_failure' AND model_id IS NOT NULL)"
      )
    )

    create(
      constraint(:circuit_breaker_failures, :circuit_breaker_failures_generation_non_negative,
        check: "generation >= 0"
      )
    )
  end
end
