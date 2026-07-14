defmodule Orchard.RuntimeEndpoint.DistributionTLSTest do
  use ExUnit.Case, async: true

  import Bitwise, only: [band: 2]

  alias Orchard.RuntimeEndpoint.DistributionTLS
  alias Orchard.TransportTLS.PeerVerifier

  test "SPEC.md §7.5.0 writes owner-only exact-peer TLS Distribution options" do
    root =
      Path.join(
        System.tmp_dir!(),
        "orchard-distribution-tls-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)

    path = Path.join(root, "ssl-dist.conf")

    local_identity = %{
      certfile: Path.join(root, "certificate.pem"),
      keyfile: Path.join(root, "private-key.pem"),
      cacertfile: Path.join(root, "ca-certificate.pem")
    }

    Enum.each(Map.values(local_identity), fn identity_path ->
      File.write!(identity_path, "protected test material")
      File.chmod!(identity_path, 0o600)
    end)

    peer_identity = %{
      uri_san:
        "urn:orchard:cluster:aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa:node:bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
      certificate_serial: "100",
      certificate_fingerprint: "sha256-peer"
    }

    assert :ok = DistributionTLS.write_options(path, local_identity, peer_identity)
    assert {:ok, [options]} = :file.consult(String.to_charlist(path))
    assert band(File.stat!(path).mode, 0o777) == 0o600

    assert {:server, server} = List.keyfind(options, :server, 0)
    assert server[:verify] == :verify_peer
    assert server[:fail_if_no_peer_cert] == true
    assert server[:versions] == [:"tlsv1.3"]

    assert {verify_fun, state} = server[:verify_fun]
    assert verify_fun == (&PeerVerifier.verify_fun/3)
    assert state.expected_uri == peer_identity.uri_san
    assert state.expected_serial == peer_identity.certificate_serial
    assert state.expected_fingerprint == peer_identity.certificate_fingerprint

    assert {:client, client} = List.keyfind(options, :client, 0)
    assert client[:verify] == :verify_peer
    assert client[:server_name_indication] == :disable
    assert client[:verify_fun] == server[:verify_fun]
  end

  test "SPEC.md §7.5.0 verifies exact TLS Distribution options against both identities" do
    {root, path, local_identity, peer_identity} = exact_peer_fixture()
    on_exit(fn -> File.rm_rf!(root) end)

    assert :ok = DistributionTLS.write_options(path, local_identity, peer_identity)
    assert :ok = DistributionTLS.verify_options(path, local_identity, peer_identity)
  end

  test "SPEC.md §7.5.0 syncs the TLS Distribution option directory after publication" do
    {root, path, local_identity, peer_identity} = exact_peer_fixture()
    on_exit(fn -> File.rm_rf!(root) end)
    caller = self()

    assert :ok =
             DistributionTLS.write_options(path, local_identity, peer_identity,
               sync_directory: fn directory ->
                 send(caller, {:synced, directory})
                 :ok
               end
             )

    assert_received {:synced, ^root}
  end

  defp exact_peer_fixture do
    root =
      Path.join(
        System.tmp_dir!(),
        "orchard-distribution-tls-verify-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    path = Path.join(root, "ssl-dist.conf")

    local_identity = %{
      certfile: Path.join(root, "certificate.pem"),
      keyfile: Path.join(root, "private-key.pem"),
      cacertfile: Path.join(root, "ca-certificate.pem")
    }

    Enum.each(Map.values(local_identity), fn identity_path ->
      File.write!(identity_path, "protected test material")
      File.chmod!(identity_path, 0o600)
    end)

    peer_identity = %{
      uri_san:
        "urn:orchard:cluster:aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa:node:bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
      certificate_serial: "100",
      certificate_fingerprint: "sha256-peer"
    }

    {root, path, local_identity, peer_identity}
  end
end
