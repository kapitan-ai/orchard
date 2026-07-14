defmodule Orchard.BeamPeerGrants.SecretTest do
  use ExUnit.Case, async: true

  alias Orchard.BeamPeerGrants.Secret

  test "SPEC.md §7.5.0 derives one deterministic encoded secret and hash from complete scope" do
    root = :binary.copy(<<7>>, 32)
    scope = complete_scope()

    assert {:ok, derived} = Secret.derive(scope, root)
    assert {:ok, ^derived} = Secret.derive(scope, root)
    assert derived.encoded_secret =~ ~r/\A[A-Za-z0-9_-]{43}\z/
    assert byte_size(derived.secret_hash) == 32
    assert derived.secret_hash == :crypto.hash(:sha256, derived.encoded_secret)
  end

  test "SPEC.md §7.5.0 exact-pair secret changes across every authorization dimension" do
    root = :binary.copy(<<7>>, 32)
    scope = complete_scope()
    assert {:ok, original} = Secret.derive(scope, root)

    mutations = [
      cluster_id: "ffffffff-ffff-4fff-8fff-ffffffffffff",
      controller_id: "ffffffff-ffff-4fff-8fff-ffffffffffff",
      controller_beam_name: "orchard_controller_forged@10.0.0.10",
      node_id: "ffffffff-ffff-4fff-8fff-ffffffffffff",
      node_beam_name: "orchard_node_agent_forged@10.0.0.20",
      purpose: "control_plane",
      generation: 2
    ]

    Enum.each(mutations, fn {field, value} ->
      assert {:ok, changed} = Secret.derive(Map.put(scope, field, value), root)
      refute changed.encoded_secret == original.encoded_secret
      refute changed.secret_hash == original.secret_hash
    end)
  end

  test "SPEC.md §7.5.0 rejects non-DateTime grant timestamps" do
    root = :binary.copy(<<7>>, 32)
    scope = complete_scope()

    for field <- [:issued_at, :not_before_at, :cutover_at, :expires_at] do
      assert {:error, :beam_peer_grant_scope_invalid} =
               Secret.derive(Map.put(scope, field, "2026-07-13T08:00:00Z"), root)
    end
  end

  defp complete_scope do
    %{
      contract_version: 1,
      purpose: "runtime_endpoint",
      cluster_id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
      controller_id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
      controller_beam_name: "orchard_controller_bbbbbbbbbbbb4bbb8bbbbbbbbbbbbbbb@10.0.0.10",
      controller_certificate_identifier: "controller-cert-1",
      controller_certificate_fingerprint_sha256: String.duplicate("1", 64),
      beam_authorization_root_id: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
      node_id: "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
      node_beam_name: "orchard_node_agent_dddddddddddd4ddd8ddddddddddddddd@10.0.0.20",
      node_certificate_identifier: "node-cert-1",
      node_certificate_fingerprint_sha256: String.duplicate("2", 64),
      id: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
      generation: 1,
      issued_at: ~U[2026-07-13 08:00:00.000000Z],
      not_before_at: ~U[2026-07-13 08:00:00.000000Z],
      cutover_at: nil,
      expires_at: ~U[2026-08-12 08:00:00.000000Z]
    }
  end
end
