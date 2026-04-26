defmodule Orchard.Repo.Migrations.AddConnectTargetToNodes do
  use Ecto.Migration

  def up do
    alter table(:nodes) do
      add(:connect_host, :text)
      add(:connect_port, :integer)
    end

    execute("""
    UPDATE nodes
    SET connect_host = advertise_addr,
        connect_port = rpc_port
    WHERE connect_host IS NULL
      AND connect_port IS NULL
      AND advertise_addr NOT IN ('0.0.0.0', '::')
    """)

    drop_if_exists(index(:nodes, [:advertise_addr, :rpc_port]))

    create(
      unique_index(:nodes, [:advertise_addr, :rpc_port],
        where: "advertise_addr NOT IN ('0.0.0.0', '::')"
      )
    )

    create(
      unique_index(:nodes, [:connect_host, :connect_port],
        where: "connect_host IS NOT NULL AND connect_port IS NOT NULL"
      )
    )

    create(
      constraint(:nodes, :nodes_connect_port_range,
        check: "connect_port IS NULL OR (connect_port > 0 AND connect_port <= 65535)"
      )
    )

    create(
      constraint(:nodes, :nodes_connect_target_pair,
        check:
          "(connect_host IS NULL AND connect_port IS NULL) OR " <>
            "(connect_host IS NOT NULL AND connect_host <> '' AND connect_port IS NOT NULL)"
      )
    )
  end

  def down do
    drop_if_exists(constraint(:nodes, :nodes_connect_target_pair))
    drop_if_exists(constraint(:nodes, :nodes_connect_port_range))
    drop_if_exists(index(:nodes, [:connect_host, :connect_port]))
    drop_if_exists(index(:nodes, [:advertise_addr, :rpc_port]))

    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM nodes
        WHERE advertise_addr IN ('0.0.0.0', '::')
        GROUP BY advertise_addr, rpc_port
        HAVING count(*) > 1
      ) THEN
        RAISE EXCEPTION
          'Cannot roll back AddConnectTargetToNodes: duplicate bind-all advertised targets exist. Remove or merge duplicate 0.0.0.0/:: node rows before recreating the legacy nodes_advertise_addr_rpc_port_index.';
      END IF;
    END $$;
    """)

    create(unique_index(:nodes, [:advertise_addr, :rpc_port]))

    alter table(:nodes) do
      remove(:connect_port)
      remove(:connect_host)
    end
  end
end
