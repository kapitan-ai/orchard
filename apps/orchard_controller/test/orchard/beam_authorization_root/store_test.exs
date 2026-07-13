defmodule Orchard.BeamAuthorizationRoot.StoreTest do
  use ExUnit.Case, async: true

  import Bitwise, only: [band: 2]

  alias Orchard.BeamAuthorizationRoot.Store

  test "SPEC.md §7.5.0 creates one owner-only authorization root idempotently" do
    root =
      Path.join(
        System.tmp_dir!(),
        "orchard-beam-authorization-root-#{System.unique_integer([:positive, :monotonic])}"
      )

    on_exit(fn -> File.rm_rf!(root) end)

    assert {:ok, material} = Store.ensure(root)
    assert {:ok, ^material} = Store.ensure(root)
    assert byte_size(material.key) >= 32
    assert {:ok, _root_id} = Ecto.UUID.cast(material.root_id)

    assert private_mode(root) == 0o700
    assert private_mode(Path.join(root, "authorization-root.bin")) == 0o600
    assert private_mode(Path.join(root, "metadata.json")) == 0o600
  end

  test "SPEC.md §7.5.0 rejects an authorization root not owned by the Controller account" do
    root =
      Path.join(
        System.tmp_dir!(),
        "orchard-beam-authorization-root-owner-#{System.unique_integer([:positive, :monotonic])}"
      )

    on_exit(fn -> File.rm_rf!(root) end)

    assert {:ok, _material} = Store.ensure(root)
    foreign_uid = File.stat!(root).uid + 1

    assert {:error, :beam_authorization_root_storage_invalid} =
             Store.load(root, uid_probe: fn _parent -> {:ok, foreign_uid} end)
  end

  defp private_mode(path) do
    {:ok, stat} = File.stat(path)
    band(stat.mode, 0o777)
  end
end
