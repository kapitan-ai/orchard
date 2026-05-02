defmodule Orchard.Inference.CacheAffinityTest do
  use ExUnit.Case, async: false

  alias Orchard.CanonicalRequest
  alias Orchard.CanonicalRequest.ModelRef
  alias Orchard.Inference.CacheAffinity

  setup do
    previous_endpoint_config = Application.get_env(:orchard_controller, Orchard.API.Endpoint, [])

    on_exit(fn ->
      Application.put_env(:orchard_controller, Orchard.API.Endpoint, previous_endpoint_config)
    end)

    :ok
  end

  test "regression: derive_key/2 normalizes sparse config before deriving" do
    request = canonical_request("prefix")

    assert {:ok, "hmac-sha256:" <> digest} =
             CacheAffinity.derive_key(request, hmac_secret: "independent-secret")

    assert byte_size(digest) == 64
  end

  test "derive_key/2 is idempotent and keeps the hmac-sha256 fingerprint format" do
    request = canonical_request("stable prompt")
    config = [hmac_secret: "independent-secret", max_prefix_bytes: 8_192]

    assert {:ok, fingerprint_one} = CacheAffinity.derive_key(request, config)
    assert {:ok, fingerprint_two} = CacheAffinity.derive_key(request, config)

    assert fingerprint_one == fingerprint_two
    assert String.match?(fingerprint_one, ~r/^hmac-sha256:[a-f0-9]{64}$/)
  end

  test "derive_key/2 returns unavailable instead of raising for malformed config" do
    put_endpoint_secret_key_base(nil)
    request = canonical_request("prefix")

    assert :unavailable = CacheAffinity.derive_key(request, %{max_prefix_bytes: 1})
  end

  test "prompt_token_ids do not affect cache affinity key" do
    request = canonical_request("hello")
    with_ids = %{request | prompt_token_ids: [1, 2, 3]}
    without_ids = %{request | prompt_token_ids: []}
    config = [hmac_secret: "independent-secret"]

    assert CacheAffinity.derive_key(with_ids, config) ==
             CacheAffinity.derive_key(without_ids, config)
  end

  test "normalize_config/1 parent-gates live fingerprint matching" do
    assert CacheAffinity.normalize_config(
             enabled: false,
             live_fingerprint_match_enabled: true
           )[:live_fingerprint_match_enabled] == false

    assert CacheAffinity.normalize_config(
             enabled: true,
             live_fingerprint_match_enabled: true
           )[:live_fingerprint_match_enabled] == true
  end

  test "derive_key/2 falls back to endpoint secret when cache-affinity secret is not configured" do
    put_endpoint_secret_key_base("endpoint-secret")

    request = canonical_request("prefix")

    assert {:ok, "hmac-sha256:" <> digest} = CacheAffinity.derive_key(request, [])
    assert byte_size(digest) == 64
  end

  test "derive_key/2 prefers explicit cache-affinity secret over endpoint secret fallback" do
    put_endpoint_secret_key_base("endpoint-secret")

    request = canonical_request("prefix")

    assert {:ok, endpoint_key} = CacheAffinity.derive_key(request, [])

    assert {:ok, explicit_key} =
             CacheAffinity.derive_key(request, hmac_secret: "independent-secret")

    refute explicit_key == endpoint_key
  end

  defp put_endpoint_secret_key_base(secret_key_base) do
    endpoint_config = Application.get_env(:orchard_controller, Orchard.API.Endpoint, [])

    updated_config =
      if is_nil(secret_key_base) do
        Keyword.delete(endpoint_config, :secret_key_base)
      else
        Keyword.put(endpoint_config, :secret_key_base, secret_key_base)
      end

    Application.put_env(:orchard_controller, Orchard.API.Endpoint, updated_config)
  end

  defp canonical_request(rendered_prompt) do
    CanonicalRequest.new(%{
      internal_id: "req_cache_affinity_internal",
      public_id: "req_cache_affinity_public",
      endpoint: :chat_completions,
      tenant_id: "tenant_cache_affinity",
      model_ref: %ModelRef{model_id: "mlx-community/phi-3", version: "main"},
      rendered_prompt: rendered_prompt
    })
  end
end
