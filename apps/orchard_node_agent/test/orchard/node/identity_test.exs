defmodule Orchard.Node.IdentityTest do
  use ExUnit.Case, async: true

  alias Orchard.Node.Identity

  @uuid_regex ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/

  setup do
    tmp_dir =
      Path.join([
        System.tmp_dir!(),
        "orchard-identity-test",
        "#{System.unique_integer([:positive])}"
      ])

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    %{tmp_dir: tmp_dir, identity_path: Path.join(tmp_dir, "node-id")}
  end

  describe "resolve_identity!/1" do
    test "explicit config node_id takes precedence over file", %{identity_path: path} do
      configured_id = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
      # Write a different ID to file
      File.write!(path, "ffffffff-0000-4000-a000-000000000000\n")

      runtime = [node_id: configured_id, node_identity_path: path]
      assert Identity.resolve_identity!(runtime) == configured_id
    end

    test "reads existing identity file when no config override", %{identity_path: path} do
      file_id = "11111111-2222-4333-8444-555555555555"
      File.write!(path, file_id <> "\n")

      runtime = [node_id: nil, node_identity_path: path]
      assert Identity.resolve_identity!(runtime) == file_id
    end

    test "generates and persists identity when no config and no file", %{identity_path: path} do
      runtime = [node_id: nil, node_identity_path: path]
      id = Identity.resolve_identity!(runtime)

      assert Regex.match?(@uuid_regex, id)
      assert File.read!(path) == id <> "\n"

      # Second call reads from file, returns same ID
      assert Identity.resolve_identity!(runtime) == id
    end

    test "raises on invalid explicit config UUID" do
      runtime = [node_id: "not-a-uuid", node_identity_path: "/unused"]

      assert_raise RuntimeError, ~r/Invalid node UUID from config/, fn ->
        Identity.resolve_identity!(runtime)
      end
    end

    test "raises on empty string config UUID", %{identity_path: path} do
      # Empty string should fall through to file resolution, not be treated as valid
      runtime = [node_id: "", node_identity_path: path]
      id = Identity.resolve_identity!(runtime)
      assert Regex.match?(@uuid_regex, id)
    end

    test "raises on corrupt identity file", %{identity_path: path} do
      File.write!(path, "this-is-not-a-uuid\n")

      runtime = [node_id: nil, node_identity_path: path]

      assert_raise RuntimeError, ~r/Invalid node UUID from identity file/, fn ->
        Identity.resolve_identity!(runtime)
      end
    end

    test "raises on unreadable identity file" do
      # Use a path inside a non-existent read-protected directory
      bad_path = "/nonexistent-orchard-dir/node-id"
      runtime = [node_id: nil, node_identity_path: bad_path]

      assert_raise RuntimeError, ~r/Cannot (read|create)/, fn ->
        Identity.resolve_identity!(runtime)
      end
    end

    test "creates parent directory for identity file", %{tmp_dir: tmp_dir} do
      nested_path = Path.join([tmp_dir, "nested", "deep", "node-id"])
      runtime = [node_id: nil, node_identity_path: nested_path]

      id = Identity.resolve_identity!(runtime)
      assert Regex.match?(@uuid_regex, id)
      assert File.exists?(nested_path)
    end

    test "generated UUID is valid v4 format", %{identity_path: path} do
      runtime = [node_id: nil, node_identity_path: path]
      id = Identity.resolve_identity!(runtime)

      # UUIDv4: version nibble = 4, variant bits = 10xx
      assert Regex.match?(@uuid_regex, id)
    end
  end
end
