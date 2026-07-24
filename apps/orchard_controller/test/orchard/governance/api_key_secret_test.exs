defmodule Orchard.Governance.ApiKeySecretTest do
  use ExUnit.Case, async: true

  alias Orchard.Governance.ApiKeySecret

  test "SPEC.md §10.2 generate/0 emits the canonical API Token contract" do
    generated = ApiKeySecret.generate()

    assert %{token: token, token_prefix: token_prefix, secret_hash: secret_hash} = generated

    assert [_, public_part, secret_part] =
             Regex.run(~r/^orchard_sk_([A-Za-z0-9_-]{16})_([A-Za-z0-9_-]{43})$/, token)

    assert {:ok, public_bytes} = Base.url_decode64(public_part, padding: false)
    assert {:ok, secret_bytes} = Base.url_decode64(secret_part, padding: false)
    assert byte_size(public_bytes) == 12
    assert byte_size(secret_bytes) == 32
    assert token_prefix == "orchard_kp_" <> public_part
    assert {:ok, ^token_prefix} = ApiKeySecret.canonical_token_prefix(token)
    assert {:ok, ^token_prefix} = ApiKeySecret.token_prefix(token)

    expected_hash =
      "sha256$" <>
        Base.url_encode64(:crypto.hash(:sha256, secret_part), padding: false)

    assert secret_hash == expected_hash
    assert secret_hash == ApiKeySecret.hash(token)
    assert ApiKeySecret.verify(token, secret_hash)
  end

  test "verify/2 rejects non-matching tokens" do
    generated = ApiKeySecret.generate()
    other = ApiKeySecret.generate()

    refute ApiKeySecret.verify(other.token, generated.secret_hash)
  end

  test "legacy credentials retain their original full-token hash semantics" do
    token = "orch_existingPublic.existingSecret"

    expected_hash =
      "sha256$" <>
        Base.url_encode64(:crypto.hash(:sha256, token), padding: false)

    assert {:ok, "orch_existingPublic"} = ApiKeySecret.token_prefix(token)
    assert :error = ApiKeySecret.canonical_token_prefix(token)
    assert expected_hash == ApiKeySecret.hash(token)
    assert ApiKeySecret.verify(token, expected_hash)
  end

  test "token_prefix/1 rejects malformed tokens" do
    assert :error = ApiKeySecret.token_prefix("missing-delimiter")
    assert :error = ApiKeySecret.token_prefix("wrongprefix.secret")
    assert :error = ApiKeySecret.token_prefix("orch_prefix")
    assert :error = ApiKeySecret.token_prefix("orch_prefix.")
    assert :error = ApiKeySecret.token_prefix("orch_.secret")
    assert :error = ApiKeySecret.token_prefix("orch_valid.secret.extra")
    assert :error = ApiKeySecret.token_prefix("orchard_sk_short_short")
    non_canonical_secret = String.duplicate("A", 42) <> "B"

    newline_suffixed_token =
      "orchard_sk_#{String.duplicate("A", 16)}_#{String.duplicate("A", 43)}\n"

    assert :error =
             ApiKeySecret.token_prefix("orchard_sk_AAAAAAAAAAAAAAAA_#{non_canonical_secret}")

    assert :error = ApiKeySecret.canonical_token_prefix(newline_suffixed_token)
    assert :error = ApiKeySecret.token_prefix(newline_suffixed_token)
    refute ApiKeySecret.verify(newline_suffixed_token, ApiKeySecret.hash(newline_suffixed_token))
  end

  test "verify/2 returns false for malformed stored hashes and malformed tokens" do
    token = ApiKeySecret.generate().token

    refute ApiKeySecret.verify(token, "")
    refute ApiKeySecret.verify(token, "sha1$abc")
    refute ApiKeySecret.verify(token, "sha256$not base64!!!")
    refute ApiKeySecret.verify("orch_.secret", ApiKeySecret.hash(token))
  end
end
