defmodule Orchard.Repo.Migrations.CircuitBreakerContributionEvidence do
  use Ecto.Migration

  def change do
    alter table(:circuit_breaker_failures) do
      add(:decision_at, :utc_datetime_usec, null: false)
      add(:disposition, :text, null: false)
      add(:transition, :text, null: false, default: "none")
    end

    create(
      constraint(:circuit_breaker_failures, :circuit_breaker_failures_disposition_valid,
        check: "disposition IN ('contributed', 'fenced')"
      )
    )

    create(
      constraint(:circuit_breaker_failures, :circuit_breaker_failures_transition_valid,
        check: "transition IN ('none', 'opened')"
      )
    )

    create(
      index(:circuit_breaker_failures, [:breaker_id, :generation, :decision_at],
        name: :circuit_breaker_failures_decision_window
      )
    )
  end
end
