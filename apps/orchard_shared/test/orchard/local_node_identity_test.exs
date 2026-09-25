defmodule Orchard.LocalNodeIdentityTest do
  use ExUnit.Case, async: true

  alias Orchard.LocalNodeIdentity

  @generation "11111111-1111-4111-8111-111111111111"
  @node "22222222-2222-4222-8222-222222222222"
  @enrollment "33333333-3333-4333-8333-333333333333"

  setup %{tmp_dir: root} do
    directory = Path.join([root, "generations", @generation])
    File.mkdir_p!(directory)
    Enum.each([root, Path.dirname(directory), directory], &File.chmod!(&1, 0o700))
    current = Path.join(root, "current")
    metadata = Path.join(directory, "metadata.json")
    File.write!(current, @generation <> "\n")

    File.write!(
      metadata,
      Jason.encode!(%{
        generation_id: @generation,
        state: "registered",
        node_id: @node,
        enrollment_id: @enrollment,
        certificate_identifier: "cert-local"
      })
    )

    Enum.each([current, metadata], &File.chmod!(&1, 0o600))
    %{root: root, current: current, metadata: metadata}
  end

  @moduletag :tmp_dir

  test "SPEC 4.5 reads registered identifiers without a private key or second identity", ctx do
    before = File.read!(ctx.metadata)

    assert {:ok,
            %{node_id: @node, enrollment_id: @enrollment, certificate_identifier: "cert-local"}} =
             LocalNodeIdentity.read(ctx.root)

    assert File.read!(ctx.metadata) == before
    refute File.exists?(Path.join(ctx.root, "node-id"))
    assert {:error, :not_configured} = LocalNodeIdentity.read(nil)
    assert {:error, :identity_unavailable} = LocalNodeIdentity.read(Path.join(ctx.root, "absent"))
  end

  test "rejects prepared, malformed, wrong generation and missing certificate metadata", ctx do
    valid = Jason.decode!(File.read!(ctx.metadata))

    for invalid <- [
          Map.put(valid, "state", "prepared"),
          Map.put(valid, "generation_id", @node),
          Map.put(valid, "node_id", "not-a-node"),
          Map.delete(valid, "certificate_identifier")
        ] do
      File.write!(ctx.metadata, Jason.encode!(invalid))
      assert {:error, :identity_unavailable} = LocalNodeIdentity.read(ctx.root)
    end

    File.write!(ctx.metadata, "not json")
    assert {:error, :identity_unavailable} = LocalNodeIdentity.read(ctx.root)
  end

  test "rejects insecure modes, symlinks, oversized metadata and path traversal", ctx do
    File.chmod!(ctx.metadata, 0o644)
    assert {:error, :identity_unavailable} = LocalNodeIdentity.read(ctx.root)
    File.chmod!(ctx.metadata, 0o600)
    File.write!(ctx.metadata, String.duplicate("x", 16_385))
    assert {:error, :identity_unavailable} = LocalNodeIdentity.read(ctx.root)
    File.write!(ctx.current, "../../outside")
    assert {:error, :identity_unavailable} = LocalNodeIdentity.read(ctx.root)
    File.rm!(ctx.current)
    File.ln_s!(ctx.metadata, ctx.current)
    assert {:error, :identity_unavailable} = LocalNodeIdentity.read(ctx.root)
  end
end
