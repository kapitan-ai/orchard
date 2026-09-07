defmodule Orchard.Governance.PortalActivationCurlTest do
  use Orchard.DataCase, async: false

  import Orchard.TestSupport.ModelRequestFixtures

  alias Orchard.Governance
  alias Orchard.Governance.PortalActivationCurl
  alias Orchard.Models.Access

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

  test "chooses a deterministic exact identity from active enabled grants" do
    tenant = tenant!("portal-curl-default")
    z_model = create_model!(%{model_id: "zeta/model", version: "v1", state: :active})
    a_v2 = create_model!(%{model_id: "alpha/model", version: "v2", state: :active})
    a_v1 = create_model!(%{model_id: "alpha/model", version: "v1", state: :active})

    grant_model_access!(tenant, z_model)
    grant_model_access!(tenant, a_v2)
    grant_model_access!(tenant, a_v1)

    assert PortalActivationCurl.select_callable_model(tenant.id) == "alpha/model@v1"
  end

  test "keeps an exact requested identity when it is active and enabled" do
    tenant = tenant!("portal-curl-requested")
    default_model = create_model!(%{model_id: "alpha/model", version: "v1", state: :active})
    requested_model = create_model!(%{model_id: "zeta/model", version: "v2", state: :active})
    grant_model_access!(tenant, default_model)
    grant_model_access!(tenant, requested_model)

    assert PortalActivationCurl.select_callable_model(tenant.id, "zeta/model@v2") ==
             "zeta/model@v2"
  end

  test "does not substitute another model for an unavailable exact request" do
    tenant = tenant!("portal-curl-no-substitute")
    authorized_model = create_model!(%{model_id: "authorized/model", state: :active})
    grant_model_access!(tenant, authorized_model)

    assert PortalActivationCurl.select_callable_model(tenant.id, "missing/model@main") == nil
  end

  test "excludes never-granted and cross-Workspace models" do
    tenant = tenant!("portal-curl-empty")
    other_tenant = tenant!("portal-curl-other")
    other_model = create_model!(%{model_id: "other/model", state: :active})
    grant_model_access!(other_tenant, other_model)

    assert PortalActivationCurl.select_callable_model(tenant.id) == nil
    assert PortalActivationCurl.select_callable_model(tenant.id, "other/model@main") == nil
  end

  test "excludes disabled and revoked grants" do
    disabled_tenant = tenant!("portal-curl-disabled")
    disabled_model = create_model!(%{model_id: "disabled/model", state: :active})
    grant_model_access!(disabled_tenant, disabled_model)

    assert {:ok, %{outcome: :disabled}} =
             Access.disable_model_access(disabled_tenant, disabled_model)

    revoked_tenant = tenant!("portal-curl-revoked")
    revoked_model = create_model!(%{model_id: "revoked/model", state: :active})
    grant_model_access!(revoked_tenant, revoked_model)
    assert {:ok, %{outcome: :revoked}} = Access.revoke_model_access(revoked_tenant, revoked_model)

    assert PortalActivationCurl.select_callable_model(disabled_tenant.id) == nil
    assert PortalActivationCurl.select_callable_model(revoked_tenant.id) == nil
  end

  test "excludes inactive models even when a grant remains enabled" do
    tenant = tenant!("portal-curl-inactive")
    model = create_model!(%{model_id: "inactive/model", state: :registered})
    grant_model_access!(tenant, model)

    assert PortalActivationCurl.select_callable_model(tenant.id) == nil
    assert PortalActivationCurl.select_callable_model(tenant.id, "inactive/model@main") == nil
  end

  defp tenant!(slug) do
    {:ok, tenant} = Governance.create_tenant(%{slug: slug, name: slug})
    tenant
  end
end
