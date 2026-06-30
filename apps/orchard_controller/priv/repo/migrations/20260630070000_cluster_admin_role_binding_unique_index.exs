defmodule Orchard.Repo.Migrations.ClusterAdminRoleBindingUniqueIndex do
  use Ecto.Migration

  def change do
    create(
      unique_index(:role_bindings, [:principal_type, :principal_id, :role],
        name: :idx_role_bindings_unique_cluster_assignment,
        where: "tenant_scope_id IS NULL"
      )
    )
  end
end
