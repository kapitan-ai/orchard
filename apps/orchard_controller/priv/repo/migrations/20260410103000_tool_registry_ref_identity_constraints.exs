defmodule Orchard.Repo.Migrations.ToolRegistryRefIdentityConstraints do
  use Ecto.Migration

  def up do
    create(
      constraint(:tools, :tools_name_ref_safe,
        check:
          "name <> '' AND position('@' in name) = 0 AND position(' ' in name) = 0 AND position(E'\\n' in name) = 0 AND position(E'\\t' in name) = 0"
      )
    )

    create(
      constraint(:tools, :tools_version_ref_safe,
        check:
          "version <> '' AND position('@' in version) = 0 AND position(' ' in version) = 0 AND position(E'\\n' in version) = 0 AND position(E'\\t' in version) = 0"
      )
    )
  end

  def down do
    drop_if_exists(constraint(:tools, :tools_version_ref_safe))
    drop_if_exists(constraint(:tools, :tools_name_ref_safe))
  end
end
