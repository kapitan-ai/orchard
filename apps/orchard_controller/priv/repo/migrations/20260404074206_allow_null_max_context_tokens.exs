defmodule Orchard.Repo.Migrations.AllowNullMaxContextTokens do
  use Ecto.Migration

  def up do
    alter table(:models) do
      modify :max_context_tokens, :integer, null: true, from: {:integer, null: false}
    end

    drop_if_exists constraint(:models, :models_max_context_tokens_positive)

    create constraint(:models, :models_max_context_tokens_positive,
      check: "max_context_tokens IS NULL OR max_context_tokens > 0"
    )
  end

  def down do
    # Backfill any NULL rows before restoring the NOT NULL constraint.
    # Uses a conservative default; operators should update affected models.
    execute "UPDATE models SET max_context_tokens = 4096 WHERE max_context_tokens IS NULL"

    drop_if_exists constraint(:models, :models_max_context_tokens_positive)

    create constraint(:models, :models_max_context_tokens_positive,
      check: "max_context_tokens > 0"
    )

    alter table(:models) do
      modify :max_context_tokens, :integer, null: false, from: {:integer, null: true}
    end
  end
end
