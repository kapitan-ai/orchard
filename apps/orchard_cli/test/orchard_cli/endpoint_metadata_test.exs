defmodule OrchardCLI.EndpointMetadataTest do
  use ExUnit.Case, async: true

  alias OrchardCLI.EndpointMetadata

  @schema_keys ~w(
    api_bind_ip
    api_https_port
    ca_certfile
    generated_by
    plain_http_port
    public_host
    schema_version
    transport_mode
    updated_at
  )

  defp temp_path do
    root =
      System.tmp_dir!()
      |> Path.join("orchard-endpoint-metadata-#{System.unique_integer([:positive])}")

    {root, Path.join([root, "public", "endpoint.json"])}
  end

  defp metadata(overrides \\ %{}) do
    Map.merge(
      %{
        transport_mode: "direct_https",
        public_host: "mawarduri.local",
        api_https_port: 8443,
        plain_http_port: nil,
        api_bind_ip: "0.0.0.0",
        ca_certfile: "/Library/Application Support/Orchard/public/ca.crt",
        generated_by: "orchardctl transport"
      },
      overrides
    )
  end

  test "writes schema v1 with only non-secret endpoint fields and reads it back" do
    {root, path} = temp_path()

    try do
      now = fn -> ~U[2026-05-18 01:02:03Z] end

      assert :ok = EndpointMetadata.write(metadata(), path: path, now: now)

      decoded = Jason.decode!(File.read!(path))
      assert Map.keys(decoded) |> Enum.sort() == @schema_keys
      refute inspect(decoded) =~ "password"
      refute inspect(decoded) =~ "SECRET_KEY_BASE"
      refute inspect(decoded) =~ "ORCHARD_TLS_KEYFILE"

      assert {:ok, loaded} = EndpointMetadata.read(path: path)

      assert loaded == %{
               schema_version: 1,
               transport_mode: "direct_https",
               public_host: "mawarduri.local",
               api_https_port: 8443,
               plain_http_port: nil,
               api_bind_ip: "0.0.0.0",
               ca_certfile: "/Library/Application Support/Orchard/public/ca.crt",
               updated_at: "2026-05-18T01:02:03Z",
               generated_by: "orchardctl transport"
             }
    after
      File.rm_rf(root)
    end
  end

  test "writer creates traversable support/public directories and chmods endpoint json to 0644" do
    {root, path} = temp_path()

    try do
      File.mkdir_p!(root)
      File.chmod!(root, 0o700)

      assert :ok = EndpointMetadata.write(metadata(), path: path)

      public_dir = Path.dirname(path)
      assert Bitwise.band(File.stat!(root).mode, 0o777) == 0o711
      assert Bitwise.band(File.stat!(public_dir).mode, 0o777) == 0o755
      assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o644
    after
      File.rm_rf(root)
    end
  end

  test "writer rejects unknown or secret-bearing fields without creating the sidecar" do
    {root, path} = temp_path()

    try do
      bad = Map.put(metadata(), :database_url, "ecto://secret@localhost/orchard")

      assert {:error, {:invalid, message}} = EndpointMetadata.write(bad, path: path)
      assert message =~ "unknown endpoint metadata field"
      refute File.exists?(path)
    after
      File.rm_rf(root)
    end
  end

  test "writer rejects invalid public_host values" do
    for public_host <- ["bad host", "https://bad.example"] do
      {root, path} = temp_path()

      try do
        assert {:error, {:invalid, message}} =
                 EndpointMetadata.write(metadata(%{public_host: public_host}), path: path)

        assert message =~ "public_host"
        refute File.exists?(path)
      after
        File.rm_rf(root)
      end
    end
  end

  test "writer rejects invalid updated_at string clocks" do
    {root, path} = temp_path()

    try do
      assert {:error, {:invalid, message}} =
               EndpointMetadata.write(metadata(), path: path, now: fn -> "not-a-timestamp" end)

      assert message =~ "updated_at"
      refute File.exists?(path)
    after
      File.rm_rf(root)
    end
  end

  test "writer rejects protected or private-key CA paths" do
    for ca_path <- [
          "/Library/Application Support/Orchard/config/tls/ca.crt",
          "/Library/Application Support/Orchard/public/controller.key",
          "/operator/private/ca.crt"
        ] do
      {root, path} = temp_path()

      try do
        assert {:error, {:invalid, message}} =
                 EndpointMetadata.write(metadata(%{ca_certfile: ca_path}), path: path)

        assert message =~ "ca_certfile"
        refute File.exists?(path)
      after
        File.rm_rf(root)
      end
    end
  end

  test "reader rejects malformed, wrong-schema, and secret-bearing sidecars" do
    {root, path} = temp_path()

    try do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "not json")
      assert {:error, {:malformed, message}} = EndpointMetadata.read(path: path)
      assert message =~ "malformed JSON"

      wrong_schema =
        metadata()
        |> Map.put(:schema_version, 2)
        |> Map.put(:updated_at, "2026-05-18T01:02:03Z")
        |> stringify_keys()

      File.write!(path, Jason.encode!(wrong_schema))
      assert {:error, {:malformed, message}} = EndpointMetadata.read(path: path)
      assert message =~ "schema_version"

      invalid_timestamp =
        metadata()
        |> Map.put(:schema_version, 1)
        |> Map.put(:updated_at, "not-a-timestamp")
        |> stringify_keys()

      File.write!(path, Jason.encode!(invalid_timestamp))
      assert {:error, {:malformed, message}} = EndpointMetadata.read(path: path)
      assert message =~ "updated_at"

      null_timestamp =
        metadata()
        |> Map.put(:schema_version, 1)
        |> Map.put(:updated_at, nil)
        |> stringify_keys()

      File.write!(path, Jason.encode!(null_timestamp))
      assert {:error, {:malformed, message}} = EndpointMetadata.read(path: path)
      assert message =~ "updated_at"

      invalid_host =
        metadata(%{public_host: "https://bad.example"})
        |> Map.put(:schema_version, 1)
        |> Map.put(:updated_at, "2026-05-18T01:02:03Z")
        |> stringify_keys()

      File.write!(path, Jason.encode!(invalid_host))
      assert {:error, {:malformed, message}} = EndpointMetadata.read(path: path)
      assert message =~ "public_host"

      secret_bearing =
        metadata()
        |> Map.put(:schema_version, 1)
        |> stringify_keys()
        |> Map.put("api_key", "sk-secret")

      File.write!(path, Jason.encode!(secret_bearing))
      assert {:error, {:malformed, message}} = EndpointMetadata.read(path: path)
      assert message =~ "unknown endpoint metadata field"

      protected_ca =
        metadata(%{ca_certfile: "/Library/Application Support/Orchard/config/tls/ca.crt"})
        |> Map.put(:schema_version, 1)
        |> Map.put(:updated_at, "2026-05-18T01:02:03Z")
        |> stringify_keys()

      File.write!(path, Jason.encode!(protected_ca))
      assert {:error, {:malformed, message}} = EndpointMetadata.read(path: path)
      assert message =~ "ca_certfile"
    after
      File.rm_rf(root)
    end
  end

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end
end
