defmodule Orchard.ArtifactBundleTest do
  use ExUnit.Case, async: true

  alias Orchard.ArtifactBundle

  # Pre-computed hash of the controller test fixture bundle.
  # This value was captured from the original importer hash logic and serves
  # as a regression lock ensuring extracted shared logic is identical.
  @fixture_bundle Path.expand(
                    "../../../../apps/orchard_controller/test/fixtures/bundles/test-model-bundle",
                    __DIR__
                  )
  @fixture_hash "b001bcbf58ca977328bfc27db38b91a9732ae28f6c562fa1005df5fece13ba17"

  setup do
    tmp_dir =
      System.tmp_dir!()
      |> Path.join("artifact_bundle_test_#{:rand.uniform(1_000_000)}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    %{tmp_dir: tmp_dir}
  end

  describe "tree_sha256/1" do
    test "matches pre-refactor importer hash for the fixture bundle" do
      assert {:ok, @fixture_hash} = ArtifactBundle.tree_sha256(@fixture_bundle)
    end

    test "is deterministic across different root paths", %{tmp_dir: tmp_dir} do
      copy_a = Path.join(tmp_dir, "copy_a")
      copy_b = Path.join(tmp_dir, "copy_b")
      File.mkdir_p!(copy_a)
      File.mkdir_p!(copy_b)

      :ok = ArtifactBundle.copy_directory(@fixture_bundle, copy_a)
      :ok = ArtifactBundle.copy_directory(@fixture_bundle, copy_b)

      assert {:ok, hash_a} = ArtifactBundle.tree_sha256(copy_a)
      assert {:ok, hash_b} = ArtifactBundle.tree_sha256(copy_b)
      assert hash_a == hash_b
      assert hash_a == @fixture_hash
    end

    test "returns error for nonexistent directory" do
      assert {:error, {:hash_failed, _}} = ArtifactBundle.tree_sha256("/nonexistent/path")
    end

    test "rejects symlinks in tree", %{tmp_dir: tmp_dir} do
      bundle = Path.join(tmp_dir, "symlink_bundle")
      File.mkdir_p!(bundle)
      File.write!(Path.join(bundle, "real.txt"), "content")

      outside = Path.join(tmp_dir, "outside.txt")
      File.write!(outside, "secret")
      File.ln_s!(outside, Path.join(bundle, "linked.txt"))

      assert {:error, {:hash_failed, message}} = ArtifactBundle.tree_sha256(bundle)
      assert message =~ "symlinks not allowed"
    end

    test "handles empty directory", %{tmp_dir: tmp_dir} do
      empty = Path.join(tmp_dir, "empty")
      File.mkdir_p!(empty)

      assert {:ok, hash} = ArtifactBundle.tree_sha256(empty)
      # SHA-256 of empty input
      assert hash == Base.encode16(:crypto.hash(:sha256, ""), case: :lower)
    end
  end

  describe "copy_directory/2" do
    test "copies nested directories and regular files", %{tmp_dir: tmp_dir} do
      dest = Path.join(tmp_dir, "copied")
      File.mkdir_p!(dest)

      :ok = ArtifactBundle.copy_directory(@fixture_bundle, dest)

      assert File.exists?(Path.join(dest, "manifest.json"))
      assert File.exists?(Path.join(dest, "tokenizer.json"))
      assert File.exists?(Path.join(dest, "weights/model.safetensors"))

      # Content matches
      original = File.read!(Path.join(@fixture_bundle, "manifest.json"))
      copied = File.read!(Path.join(dest, "manifest.json"))
      assert original == copied
    end

    test "rejects symlinks in source", %{tmp_dir: tmp_dir} do
      source = Path.join(tmp_dir, "evil_source")
      File.mkdir_p!(source)
      File.write!(Path.join(source, "real.txt"), "data")

      outside = Path.join(tmp_dir, "secret.txt")
      File.write!(outside, "secret")
      File.ln_s!(outside, Path.join(source, "linked.txt"))

      dest = Path.join(tmp_dir, "dest")
      File.mkdir_p!(dest)

      assert {:error, {:symlink_rejected, message}} = ArtifactBundle.copy_directory(source, dest)
      assert message =~ "symlinks not allowed"
    end

    test "returns error for nonexistent source", %{tmp_dir: tmp_dir} do
      dest = Path.join(tmp_dir, "dest")
      File.mkdir_p!(dest)

      assert {:error, {:copy_failed, _}} =
               ArtifactBundle.copy_directory("/nonexistent/source", dest)
    end
  end
end
