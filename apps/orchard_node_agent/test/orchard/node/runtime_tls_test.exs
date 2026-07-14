defmodule Orchard.Node.RuntimeTLSTest do
  use ExUnit.Case, async: true

  alias Orchard.Node.RuntimeTLS

  test "SPEC.md §7.5.0 production grant bootstrap rejects a legacy identity generation" do
    root =
      Path.join(
        System.tmp_dir!(),
        "orchard-node-runtime-tls-#{System.unique_integer([:positive, :monotonic])}"
      )

    generation_id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    generation_root = Path.join([root, "generations", generation_id])

    File.mkdir_p!(generation_root)
    File.chmod!(root, 0o700)
    File.chmod!(Path.join(root, "generations"), 0o700)
    File.chmod!(generation_root, 0o700)

    write_private!(Path.join(root, "current"), generation_id <> "\n")

    write_private!(
      Path.join(generation_root, "metadata.json"),
      Jason.encode!(%{
        "state" => "registered",
        "generation_id" => generation_id,
        "controller_uri_san" => "urn:orchard:legacy-controller"
      })
    )

    Enum.each(
      ["node-certificate.pem", "node-private-key.pem", "runtime-ca-certificate.pem"],
      &write_private!(Path.join(generation_root, &1), "legacy material")
    )

    on_exit(fn -> File.rm_rf!(root) end)

    assert {:error, :node_runtime_tls_identity_upgrade_required} =
             RuntimeTLS.load_registered_identity(root, require_controller_certificate: true)
  end

  defp write_private!(path, contents) do
    File.write!(path, contents)
    File.chmod!(path, 0o600)
  end
end
