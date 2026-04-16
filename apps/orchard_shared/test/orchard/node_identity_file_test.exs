defmodule Orchard.NodeIdentityFileTest do
  use ExUnit.Case, async: true

  alias Orchard.NodeIdentityFile

  @uuid_regex ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
  @valid_uuid "11111111-2222-4333-8444-555555555555"

  setup do
    tmp_dir =
      Path.join([
        System.tmp_dir!(),
        "orchard-node-identity-file-test",
        Integer.to_string(System.unique_integer([:positive]))
      ])

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    %{tmp_dir: tmp_dir, identity_path: Path.join(tmp_dir, "node-id")}
  end

  describe "read/1" do
    test "returns an existing valid UUID", %{identity_path: identity_path} do
      File.write!(identity_path, @valid_uuid <> "\n")

      assert {:ok, @valid_uuid} = NodeIdentityFile.read(identity_path)
    end

    test "returns :enoent when the identity file is missing", %{identity_path: identity_path} do
      assert {:error, :enoent} = NodeIdentityFile.read(identity_path)
      refute File.exists?(identity_path)
    end

    test "returns invalid_uuid for corrupt file contents", %{identity_path: identity_path} do
      File.write!(identity_path, "not-a-uuid\n")

      assert {:error, {:invalid_uuid, "not-a-uuid"}} = NodeIdentityFile.read(identity_path)
    end

    test "returns read_failed for an unreadable identity file", %{identity_path: identity_path} do
      File.write!(identity_path, @valid_uuid <> "\n")
      File.chmod!(identity_path, 0o000)

      on_exit(fn ->
        if File.exists?(identity_path) do
          File.chmod(identity_path, 0o600)
        end
      end)

      assert {:error, {:read_failed, reason}} = NodeIdentityFile.read(identity_path)
      assert reason in [:eacces, :eperm]
    end
  end

  describe "ensure/1" do
    test "returns an existing UUID without rewriting the file", %{identity_path: identity_path} do
      File.write!(identity_path, @valid_uuid <> "\n")

      assert {:ok, @valid_uuid, :existing} = NodeIdentityFile.ensure(identity_path)
      assert File.read!(identity_path) == @valid_uuid <> "\n"
    end

    test "generates and persists a UUIDv4 when the file is missing", %{
      identity_path: identity_path
    } do
      assert {:ok, uuid, :generated} = NodeIdentityFile.ensure(identity_path)
      assert Regex.match?(@uuid_regex, uuid)
      assert File.read!(identity_path) == uuid <> "\n"
      assert ["node-id"] = File.ls!(Path.dirname(identity_path))

      assert {:ok, stat} = File.stat(identity_path)
      assert Bitwise.band(stat.mode, 0o777) == 0o600
    end

    test "creates parent directories before persisting a generated UUID", %{tmp_dir: tmp_dir} do
      nested_identity_path = Path.join([tmp_dir, "nested", "deep", "node-id"])

      assert {:ok, uuid, :generated} = NodeIdentityFile.ensure(nested_identity_path)
      assert Regex.match?(@uuid_regex, uuid)
      assert File.read!(nested_identity_path) == uuid <> "\n"
    end

    test "concurrent first-run callers adopt the same persisted UUID", %{
      identity_path: identity_path
    } do
      caller_count = 8
      parent = self()

      tasks =
        Enum.map(1..caller_count, fn _idx ->
          Task.async(fn ->
            send(parent, {:ready, self()})

            receive do
              :go -> NodeIdentityFile.ensure(identity_path)
            end
          end)
        end)

      ready_pids =
        Enum.map(1..caller_count, fn _idx ->
          assert_receive {:ready, pid}
          pid
        end)

      Enum.each(ready_pids, &send(&1, :go))

      results = Enum.map(tasks, &Task.await(&1, 5_000))
      uuids = results |> Enum.map(fn {:ok, uuid, _source} -> uuid end) |> Enum.uniq()

      assert [uuid] = uuids
      assert Regex.match?(@uuid_regex, uuid)
      assert File.read!(identity_path) == uuid <> "\n"
      assert ["node-id"] = File.ls!(Path.dirname(identity_path))

      generated_count =
        Enum.count(results, fn
          {:ok, ^uuid, :generated} -> true
          _other -> false
        end)

      existing_count =
        Enum.count(results, fn
          {:ok, ^uuid, :existing} -> true
          _other -> false
        end)

      assert generated_count == 1
      assert existing_count == caller_count - 1
    end
  end
end
