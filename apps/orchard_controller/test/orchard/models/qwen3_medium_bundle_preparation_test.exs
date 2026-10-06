Code.require_file("../../../../../scripts/support/prepare_qwen3_medium_bundle.exs", __DIR__)

defmodule Orchard.Scripts.Qwen3MediumBundlePreparationTest do
  use ExUnit.Case, async: true

  alias Orchard.Scripts.PrepareQwen3MediumBundle, as: Preparation

  @publisher_config Path.expand(
                      "../../../../../scripts/support/qwen3-medium/publisher-tokenizer-config.json",
                      __DIR__
                    )

  setup do
    root = Path.join(System.tmp_dir!(), "qwen-pilot-prep-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "derivation preserves every publisher field except explicit parser declaration", %{
    root: root
  } do
    path = Path.join(root, "tokenizer_config.json")
    File.cp!(@publisher_config, path)
    original = path |> File.read!() |> Jason.decode!()

    assert :ok = Preparation.derive_config!(path)
    bytes = File.read!(path)
    assert Jason.decode!(bytes) == Map.put(original, "tool_parser_type", "qwen3_coder")
    assert byte_size(bytes) == 1202

    assert Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) ==
             "9326181d9b773d6c64a28c5f003ca981f32ecce53e4f558db4c90c4bc8d752f3"

    assert_raise RuntimeError, ~r/publisher tokenizer config identity mismatch/, fn ->
      Preparation.derive_config!(path)
    end

    assert File.read!(path) == bytes
  end

  test "unexpected publisher bytes are rejected before config mutation", %{root: root} do
    path = Path.join(root, "tokenizer_config.json")
    File.write!(path, "{}\n")

    assert_raise RuntimeError, ~r/identity mismatch/, fn -> Preparation.derive_config!(path) end
    assert File.read!(path) == "{}\n"
  end

  test "snapshot verification checks bytes, extra files and symlinks", %{root: root} do
    path = Path.join(root, "weights")
    File.write!(path, "data")
    files = [%{"path" => "weights", "bytes" => 4, "sha256" => hash("data")}]
    assert :ok = Preparation.verify_snapshot!(root, files)

    File.write!(path, "evil")

    assert_raise RuntimeError, ~r/file identity mismatch/, fn ->
      Preparation.verify_snapshot!(root, files)
    end

    File.rm!(path)
    File.ln_s!(@publisher_config, path)

    assert_raise RuntimeError, ~r/file identity mismatch/, fn ->
      Preparation.verify_snapshot!(root, files)
    end

    File.rm!(path)
    File.write!(path, "data")
    File.write!(Path.join(root, "unexpected"), "extra")

    assert_raise RuntimeError, ~r/inventory mismatch/, fn ->
      Preparation.verify_snapshot!(root, files)
    end
  end

  test "preparation refuses existing, nested and repository destinations before mutation", %{
    root: root
  } do
    for target <- [root, Path.join(root, "nested"), Path.expand("../../../../..", __DIR__)] do
      assert_raise RuntimeError, ~r/destination/, fn -> Preparation.prepare!(root, target) end
    end

    assert File.ls!(root) == []
  end

  test "an incomplete snapshot cannot create a destination", %{root: root} do
    destination = root <> "-bundle"

    assert_raise RuntimeError, ~r/inventory mismatch/, fn ->
      Preparation.prepare!(root, destination)
    end

    refute File.exists?(destination)
  end

  defp hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
