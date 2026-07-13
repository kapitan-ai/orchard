defmodule Orchard.RuntimeEndpoint.DistributionLaunchTest do
  use ExUnit.Case, async: true

  import Bitwise, only: [band: 2]

  alias Orchard.RuntimeEndpoint.DistributionLaunch

  test "SPEC.md §7.5.0 publishes and loads an owner-only nonsecret launch contract" do
    {root, manifest_path, attrs} = launch_fixture()
    on_exit(fn -> File.rm_rf!(root) end)

    assert :ok = DistributionLaunch.write(manifest_path, attrs)
    assert {:ok, manifest} = DistributionLaunch.load(manifest_path)

    assert manifest.role == :controller
    assert manifest.grant_id == attrs.grant_id
    assert manifest.controller_beam_name == attrs.controller_beam_name
    assert manifest.node_beam_name == attrs.node_beam_name
    assert manifest.optfile_path == Path.expand(attrs.optfile_path)
    assert manifest.schema_version == 1
    assert band(File.stat!(manifest_path).mode, 0o777) == 0o600
    refute File.read!(manifest_path) =~ "encoded_secret"
    refute File.read!(manifest_path) =~ "authorization_root_bytes"
  end

  test "SPEC.md §7.5.0 verifies the running VM against the exact launch contract" do
    {root, manifest_path, attrs} = launch_fixture()
    on_exit(fn -> File.rm_rf!(root) end)

    assert :ok = DistributionLaunch.write(manifest_path, attrs)
    assert {:ok, manifest} = DistributionLaunch.load(manifest_path)

    argument_reader = fn
      :proto_dist -> {:ok, [[~c"inet_tls"]]}
      :ssl_dist_optfile -> {:ok, [[String.to_charlist(manifest.optfile_path)]]}
      :setcookie -> :error
    end

    assert :ok =
             DistributionLaunch.verify_vm(manifest,
               current_node: manifest.controller_beam_name,
               argument_reader: argument_reader,
               tls_versions: [:"tlsv1.3"],
               static_targets: [],
               cookie_file: nil,
               now: ~U[2026-07-14 00:00:00Z]
             )
  end

  test "SPEC.md §7.5.0 rejects an emulator-level shared cookie" do
    {root, manifest_path, attrs} = launch_fixture()
    on_exit(fn -> File.rm_rf!(root) end)

    assert :ok = DistributionLaunch.write(manifest_path, attrs)
    assert {:ok, manifest} = DistributionLaunch.load(manifest_path)

    argument_reader = fn
      :proto_dist -> {:ok, [[~c"inet_tls"]]}
      :ssl_dist_optfile -> {:ok, [[String.to_charlist(manifest.optfile_path)]]}
      :setcookie -> {:ok, [[~c"shared-production-cookie"]]}
    end

    assert {:error, :beam_distribution_startup_mismatch} =
             DistributionLaunch.verify_vm(manifest,
               current_node: manifest.controller_beam_name,
               argument_reader: argument_reader,
               tls_versions: [:"tlsv1.3"],
               static_targets: [],
               cookie_file: nil,
               now: ~U[2026-07-14 00:00:00Z]
             )
  end

  defp launch_fixture do
    root =
      Path.join(
        System.tmp_dir!(),
        "orchard-distribution-launch-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    optfile_path = Path.join(root, "ssl-dist.conf")
    File.write!(optfile_path, "[{server, []}, {client, []}].\n")
    File.chmod!(optfile_path, 0o600)

    attrs = %{
      role: :controller,
      grant_id: "7caf0b96-8fe3-467a-b072-f36906f5a670",
      generation: 1,
      contract_version: 1,
      purpose: "runtime_endpoint",
      cluster_id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
      controller_id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
      node_id: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
      controller_beam_name: "orchard_controller_bbbbbbbbbbbb4bbb8bbbbbbbbbbbbbbb@10.0.0.10",
      node_beam_name: "orchard_node_agent_cccccccccccc4ccc8ccccccccccccccc@10.0.0.20",
      controller_certificate_identifier: "serial:100",
      controller_certificate_fingerprint_sha256: "sha256-controller",
      node_certificate_identifier: "serial:200",
      node_certificate_fingerprint_sha256: "sha256-node",
      beam_authorization_root_id: "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
      not_before_at: ~U[2026-07-13 00:00:00Z],
      expires_at: ~U[2026-08-12 00:00:00Z],
      optfile_path: optfile_path,
      local_identity_generation_id: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"
    }

    {root, Path.join(root, "launch.json"), attrs}
  end
end
