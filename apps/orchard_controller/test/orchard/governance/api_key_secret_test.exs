defmodule Orchard.Governance.ApiKeySecretTest do
  use ExUnit.Case, async: true

  alias Orchard.Governance.ApiKeySecret

  test "generate/0 returns a token, prefix, and deterministic secret hash" do
    generated = ApiKeySecret.generate()

    assert %{token: token, token_prefix: token_prefix, secret_hash: secret_hash} = generated
    assert String.starts_with?(token, token_prefix <> ".")
    assert {:ok, ^token_prefix} = ApiKeySecret.token_prefix(token)
    assert secret_hash == ApiKeySecret.hash(token)
    assert ApiKeySecret.verify(token, secret_hash)
  end

  test "verify/2 rejects non-matching tokens" do
    generated = ApiKeySecret.generate()
    other = ApiKeySecret.generate()

    refute ApiKeySecret.verify(other.token, generated.secret_hash)
  end

  test "token_prefix/1 rejects malformed tokens" do
    assert :error = ApiKeySecret.token_prefix("missing-delimiter")
    assert :error = ApiKeySecret.token_prefix("wrongprefix.secret")
    assert :error = ApiKeySecret.token_prefix("orch_prefix")
    assert :error = ApiKeySecret.token_prefix("orch_prefix.")
    assert :error = ApiKeySecret.token_prefix("orch_.secret")
    assert :error = ApiKeySecret.token_prefix("orch_valid.secret.extra")
  end

  test "verify/2 returns false for malformed stored hashes and malformed tokens" do
    token = ApiKeySecret.generate().token

    refute ApiKeySecret.verify(token, "")
    refute ApiKeySecret.verify(token, "sha1$abc")
    refute ApiKeySecret.verify(token, "sha256$not base64!!!")
    refute ApiKeySecret.verify("orch_.secret", ApiKeySecret.hash(token))
  end
end
