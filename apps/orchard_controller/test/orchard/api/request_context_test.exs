defmodule Orchard.API.RequestContextTest do
  use Orchard.ConnCase, async: false

  import Ecto.Query
  import Orchard.TestSupport.SentryContextHelpers

  alias Orchard.API.RequestContext
  alias Orchard.API.Router
  alias Orchard.Governance
  alias Orchard.Governance.{ApiKey, AuditLog}
  alias Orchard.Inference.ChatRequestNormalizer
  alias Orchard.Repo
  alias Orchard.SentryContext

  setup :setup_sentry_context

  describe "RequestContext plug" do
    @describetag :db

    test "SPEC.md §7.2.2 authenticates a valid bearer key and assigns request provenance" do
      %{api_key: api_key, token: token, tenant: tenant} =
        create_api_key_with_token!("request-context")

      conn =
        build_conn(:get, "/v1/models")
        |> put_req_header("authorization", "Bearer #{token}")
        |> RequestContext.call([])

      assert conn.halted == false
      assert conn.assigns[:tenant_id] == tenant.id
      assert conn.assigns[:principal_id] == tenant.id
      assert conn.assigns[:api_key_id] == api_key.id
    end

    test "SPEC.md §7.2.7 rejects a missing bearer header before controller work" do
      conn =
        build_conn(:get, "/v1/models")
        |> RequestContext.call([])

      assert conn.halted
      assert conn.status == 401

      assert Jason.decode!(conn.resp_body) == %{
               "error" => %{
                 "message" => "Invalid API key provided.",
                 "type" => "authentication_error",
                 "param" => nil,
                 "code" => "invalid_api_key"
               }
             }
    end

    test "rejects malformed bearer headers" do
      conn =
        build_conn(:get, "/v1/models")
        |> put_req_header("authorization", "Token nope")
        |> RequestContext.call([])

      assert conn.halted
      assert conn.status == 401
      assert Jason.decode!(conn.resp_body)["error"]["type"] == "authentication_error"
    end

    test "rejects revoked bearer keys" do
      %{api_key: api_key, token: token} = create_api_key_with_token!("request-context-revoked")
      assert {:ok, _revoked} = Governance.revoke_api_key(api_key.id)

      conn =
        build_conn(:get, "/v1/models")
        |> put_req_header("authorization", "Bearer #{token}")
        |> RequestContext.call([])

      assert conn.halted
      assert conn.status == 401
      assert Jason.decode!(conn.resp_body)["error"]["code"] == "invalid_api_key"
    end

    test "Sentry controller enrichment records auth success with hashed caller IDs only" do
      enable_controller_sentry()

      %{api_key: api_key, token: token, tenant: tenant} =
        create_api_key_with_token!("request-context-sentry")

      conn =
        build_conn(:get, "/v1/models")
        |> put_req_header("authorization", "Bearer #{token}")
        |> RequestContext.call([])

      refute conn.halted
      context = sentry_context()

      assert context.tags == %{orchard_app: "controller", orchard_surface: "api"}

      assert context.extra == %{
               orchard_api_key_hash: SentryContext.hash_id(api_key.id),
               orchard_principal_hash: SentryContext.hash_id(tenant.id),
               orchard_tenant_hash: SentryContext.hash_id(tenant.id)
             }

      assert [%{message: "auth.success", level: :info, data: %{auth_mechanism: "bearer"}}] =
               context.breadcrumbs

      refute inspect(context) =~ token
      refute inspect(context) =~ api_key.token_prefix
    end

    test "Sentry controller enrichment records auth failure without bearer material" do
      enable_controller_sentry()

      %{api_key: api_key, token: token} =
        create_api_key_with_token!("request-context-sentry-failure")

      bad_token = swap_token_secret(token)

      conn =
        build_conn(:get, "/v1/models")
        |> put_req_header("authorization", "Bearer #{bad_token}")
        |> RequestContext.call([])

      assert conn.halted
      assert conn.status == 401

      context = sentry_context()
      assert context.tags == %{orchard_app: "controller", orchard_surface: "api"}

      assert [
               %{message: "auth.failure", level: :warning, data: %{reason: :invalid_api_key}}
             ] = context.breadcrumbs

      refute inspect(context) =~ bad_token
      refute inspect(context) =~ api_key.token_prefix
    end

    test "successful auth best-effort updates api_keys.last_used_at" do
      %{api_key: api_key, token: token} = create_api_key_with_token!("request-context-last-used")
      assert Repo.get!(ApiKey, api_key.id).last_used_at == nil

      _conn =
        build_conn(:get, "/v1/models")
        |> put_req_header("authorization", "Bearer #{token}")
        |> RequestContext.call([])

      assert %DateTime{} = Repo.get!(ApiKey, api_key.id).last_used_at
    end

    test "tenant-resolved auth failures write an audit row" do
      %{api_key: api_key, token: token} = create_api_key_with_token!("request-context-audit")
      bad_token = swap_token_secret(token)

      conn =
        build_conn(:get, "/v1/models")
        |> put_req_header("authorization", "Bearer #{bad_token}")
        |> RequestContext.call([])

      assert conn.halted
      assert conn.status == 401

      audit_log =
        Repo.one!(
          from(audit_log in AuditLog,
            where:
              audit_log.api_key_id == ^api_key.id and audit_log.action == "api_key.auth_failed"
          )
        )

      assert audit_log.payload == %{
               "reason" => "invalid_api_key",
               "token_prefix" => api_key.token_prefix
             }
    end

    test "/v1 routes are protected by the bearer-auth pipeline" do
      conn =
        build_conn(:get, "/v1/models")
        |> put_req_header("accept", "application/json")
        |> Router.call(Router.init([]))

      assert conn.halted
      assert conn.status == 401
      assert Jason.decode!(conn.resp_body)["error"]["type"] == "authentication_error"
    end

    test "/health routes bypass the request context auth boundary" do
      conn =
        build_conn(:get, "/health/live")
        |> Router.call(Router.init([]))

      assert conn.status == 200
      refute Map.has_key?(conn.assigns, :tenant_id)
    end
  end

  describe "caller context flows through to orchestrator" do
    test "normalizer receives tenant_id from caller context" do
      {:ok, canonical} =
        ChatRequestNormalizer.normalize(
          %{
            "model" => "test@v1",
            "messages" => [%{"role" => "user", "content" => "hi"}]
          },
          tenant_id: "custom-tenant",
          principal_id: "principal-123",
          api_key_id: "key-456"
        )

      assert canonical.tenant_id == "custom-tenant"
      assert canonical.principal_id == "principal-123"
      assert canonical.api_key_id == "key-456"
    end

    test "normalizer uses defaults when caller context is empty" do
      {:ok, canonical} =
        ChatRequestNormalizer.normalize(%{
          "model" => "test@v1",
          "messages" => [%{"role" => "user", "content" => "hi"}]
        })

      assert canonical.tenant_id == Governance.legacy_tenant_id()
      assert canonical.principal_id == nil
      assert canonical.api_key_id == nil
    end
  end

  defp create_api_key_with_token!(slug) do
    {:ok, tenant} = Governance.create_tenant(%{slug: slug, name: String.capitalize(slug)})

    {:ok, %{api_key: api_key, token: token}} =
      Governance.create_api_key(tenant.id, %{name: "Primary"})

    %{tenant: tenant, api_key: api_key, token: token}
  end

  defp swap_token_secret(token) do
    [prefix, _secret] = String.split(token, ".", parts: 2)
    prefix <> ".tamperedsecret"
  end
end
