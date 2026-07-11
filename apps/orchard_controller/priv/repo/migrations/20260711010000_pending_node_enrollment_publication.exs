defmodule Orchard.Repo.Migrations.PendingNodeEnrollmentPublication do
  use Ecto.Migration

  def up do
    alter table(:node_enrollments) do
      add(:published_at, :utc_datetime_usec)
      modify(:state, :text, null: false, default: "pending_publication")
    end

    execute("""
    UPDATE node_enrollments
    SET published_at = issued_at
    WHERE state IN ('issued', 'consumed', 'revoked', 'expired')
    """)

    drop(constraint(:node_enrollments, :node_enrollments_state))
    drop(constraint(:node_enrollments, :node_enrollments_lifecycle_timestamps))

    create(
      constraint(:node_enrollments, :node_enrollments_state,
        check:
          "state IN ('pending_publication', 'issued', 'consumed', 'revoked', 'expired', 'output_failed')"
      )
    )

    create(
      constraint(:node_enrollments, :node_enrollments_lifecycle_timestamps,
        check: """
        (state = 'pending_publication'
          AND published_at IS NULL
          AND consumed_at IS NULL
          AND revoked_at IS NULL
          AND output_failed_at IS NULL)
        OR
        (state = 'issued'
          AND published_at IS NOT NULL
          AND consumed_at IS NULL
          AND revoked_at IS NULL
          AND output_failed_at IS NULL)
        OR
        (state = 'consumed'
          AND published_at IS NOT NULL
          AND consumed_at IS NOT NULL
          AND revoked_at IS NULL
          AND output_failed_at IS NULL)
        OR
        (state = 'revoked'
          AND published_at IS NOT NULL
          AND revoked_at IS NOT NULL
          AND output_failed_at IS NULL)
        OR
        (state = 'expired'
          AND published_at IS NOT NULL
          AND revoked_at IS NULL
          AND output_failed_at IS NULL)
        OR
        (state = 'output_failed'
          AND published_at IS NULL
          AND consumed_at IS NULL
          AND revoked_at IS NULL
          AND output_failed_at IS NOT NULL)
        """
      )
    )
  end

  def down do
    execute("""
    UPDATE node_enrollments
    SET state = 'output_failed', output_failed_at = COALESCE(output_failed_at, NOW())
    WHERE state = 'pending_publication'
    """)

    drop(constraint(:node_enrollments, :node_enrollments_lifecycle_timestamps))
    drop(constraint(:node_enrollments, :node_enrollments_state))

    alter table(:node_enrollments) do
      remove(:published_at)
      modify(:state, :text, null: false, default: "issued")
    end

    create(
      constraint(:node_enrollments, :node_enrollments_state,
        check: "state IN ('issued', 'consumed', 'revoked', 'expired', 'output_failed')"
      )
    )

    create(
      constraint(:node_enrollments, :node_enrollments_lifecycle_timestamps,
        check: """
        (state = 'issued' AND consumed_at IS NULL AND revoked_at IS NULL AND output_failed_at IS NULL)
        OR (state = 'consumed' AND consumed_at IS NOT NULL AND revoked_at IS NULL AND output_failed_at IS NULL)
        OR (state = 'revoked' AND revoked_at IS NOT NULL AND output_failed_at IS NULL)
        OR (state = 'expired' AND revoked_at IS NULL AND output_failed_at IS NULL)
        OR (state = 'output_failed' AND consumed_at IS NULL AND revoked_at IS NULL AND output_failed_at IS NOT NULL)
        """
      )
    )
  end
end
