defmodule Orchard.Scripts.PrepareQwen3MediumBundle do
  @moduledoc """
  Offline preparation of the exact registered Qwen3.8 parser-declared bundle.

  Requires a materialized pinned publisher snapshot. Downloads, service startup,
  import, activation and verification-receipt creation are outside this helper.
  """

  alias Orchard.ArtifactBundle
  alias Orchard.Models.BundleBuilder

  @repo_root Path.expand("../..", __DIR__)
  @inventory Path.join(__DIR__, "qwen3-medium/upstream-files.json")
  @model_id "orchard-local/Qwen3.8-27B-8bit-qwen3-coder-tools"
  @version "b4e71565ae0f4b842188640b0d479ba0da1635a96297934e8bb6a57a0e1b8573"
  @artifact "48ba838e9c9c86b10ab68630ec0d8e1b6dfd760c98c2111432c56f94804d5af9"
  @original_config "792fa3f0cb88b111e54ef3134c873531008c4df471d108da17903426e308aa7b"
  @derived_config "9326181d9b773d6c64a28c5f003ca981f32ecce53e4f558db4c90c4bc8d752f3"

  @doc "Prepare into a new sibling directory outside the repository and snapshot."
  @spec prepare!(String.t(), String.t()) :: String.t()
  def prepare!(snapshot, destination) do
    source = physical_directory!(snapshot)
    target = destination!(source, destination)
    inventory = @inventory |> File.read!() |> Jason.decode!()
    verify_snapshot!(source, inventory["files"])

    File.mkdir!(target)
    :ok = ArtifactBundle.copy_directory(source, target)
    derive_config!(Path.join(target, "tokenizer_config.json"))

    metadata = %{
      revision_sha: @version,
      metadata_summary: %{base_models: [inventory["repository"] <> "@" <> inventory["revision"]]}
    }

    {:ok, ^target} = BundleBuilder.prepare_bundle(target, @model_id, metadata)
    {:ok, digest} = ArtifactBundle.tree_sha256(target)

    if digest != @artifact do
      raise "prepared bundle identity mismatch; preserve destination for inspection, do not import"
    end

    target
  end

  @doc "Verify the complete materialized snapshot before any destination is created."
  @spec verify_snapshot!(String.t(), [map()]) :: :ok
  def verify_snapshot!(source, files) do
    names = Enum.map(files, &Map.fetch!(&1, "path"))

    unless Enum.all?(names, &(Path.basename(&1) == &1)) and
             Enum.sort(File.ls!(source)) == Enum.sort(names) do
      raise "snapshot file inventory mismatch"
    end

    Enum.each(files, fn file ->
      path = Path.join(source, file["path"])

      unless File.lstat!(path).type == :regular and File.stat!(path).size == file["bytes"] and
               file_sha256(path) == file["sha256"] do
        raise "publisher file identity mismatch: #{file["path"]}"
      end
    end)

    :ok
  end

  @doc "Add only the reviewed parser declaration to the exact publisher config."
  @spec derive_config!(String.t()) :: :ok
  def derive_config!(path) do
    original = File.read!(path)

    unless sha256(original) == @original_config do
      raise "publisher tokenizer config identity mismatch"
    end

    derived =
      String.replace_prefix(original, "{\n", "{\n  \"tool_parser_type\": \"qwen3_coder\",\n")

    unless sha256(derived) == @derived_config do
      raise "derived tokenizer config identity mismatch"
    end

    File.write!(path, derived)
  end

  defp destination!(source, destination) do
    expanded = Path.expand(destination)
    parent = physical_directory!(Path.dirname(expanded))
    target = Path.join(parent, Path.basename(expanded))
    repository = physical_directory!(@repo_root)

    if inside?(target, repository) or inside?(target, source) or inside?(source, target) do
      raise "bundle destination must be outside the repository and snapshot"
    end

    case File.lstat(target) do
      {:error, :enoent} -> target
      _other -> raise "bundle destination must not already exist"
    end
  end

  defp physical_directory!(path) do
    case System.cmd("pwd", ["-P"], cd: Path.expand(path)) do
      {physical, 0} -> String.trim_trailing(physical, "\n")
      _other -> raise "directory resolution failed"
    end
  end

  defp inside?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  defp file_sha256(path) do
    path
    |> File.stream!(64 * 1024, [])
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
