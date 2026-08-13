defmodule Orchard.Governance.PortalActivationCurlTest do
  use ExUnit.Case, async: true

  alias Orchard.Governance.PortalActivationCurl

  @token "orchard_sk_aaaaaaaaaaaaaaaa_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  test "quotes model identifiers that contain shell metacharacters" do
    curl =
      PortalActivationCurl.build(
        @token,
        "evil'; rm -rf /; echo '$(whoami) model",
        "https://orchard.example"
      )

    assert is_binary(curl)
    assert curl =~ "curl -sS -X POST 'https://orchard.example/v1/chat/completions'"
    assert curl =~ "'Authorization: Bearer #{@token}'"
    assert curl =~ " -d '"
    assert curl =~ "'\"'\"'"
    refute curl =~ ~r/(^|[^'])\$\(whoami\)/
  end

  test "returns nil when the URL is not HTTPS" do
    assert PortalActivationCurl.build(@token, "phi@main", "http://127.0.0.1:4000") == nil
  end

  test "returns nil when no model is selected" do
    assert PortalActivationCurl.build(@token, nil, "https://orchard.example") == nil
  end

  test "select_callable_model is fail-closed until tenant authorization exists" do
    assert PortalActivationCurl.select_callable_model(Ecto.UUID.generate()) == nil
  end
end
