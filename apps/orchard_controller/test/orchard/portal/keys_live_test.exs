defmodule Orchard.Portal.KeysLiveTest do
  use Orchard.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Orchard.TestSupport.ModelRequestFixtures
  import Orchard.TestSupport.PortalConn

  alias Ecto.Adapters.SQL.Sandbox
  alias Orchard.API.Endpoint
  alias Orchard.Governance
  alias Orchard.Governance.PortalPasswordVerifier
  alias Orchard.Portal.Auth
  alias Orchard.Repo

  @moduletag :live
  @moduletag :db
  @password "sixteen-chars-ok"

  setup do
    enable_https_proxy!()
    Sandbox.mode(Repo, {:shared, self()})
    start_verifier!()

    {:ok, tenant} = Governance.create_tenant(%{slug: "portal-keys", name: "Portal Keys"})
    {:ok, user} = Governance.create_portal_invite(tenant, %{email: "dev@example.com"})
    {:ok, invite} = Governance.copy_portal_invite(tenant, user)
    {:ok, user} = Governance.redeem_portal_invite(tenant.slug, invite.token, @password)

    {:ok, session} =
      Governance.create_portal_session(
        "portal-keys",
        user.email,
        @password,
        "203.0.113.50"
      )

    %{tenant: tenant, user: user, token: session.token}
  end

  test "empty Workspace shows a create action, not only a table", %{
    conn: conn,
    token: token,
    tenant: tenant
  } do
    {:ok, view, html} = live(authed(conn, token), "/portal/portal-keys/keys")

    assert html =~ "Workspace"
    assert html =~ tenant.name
    assert html =~ "No API keys yet"
    assert html =~ "Mint your first key"
    assert html =~ "0 / 10"
    refute html =~ "console-sidebar"
    refute html =~ "theme-toggle"
    refute html =~ "href=\"/console"
    assert has_element?(view, "#portal-mint-button")
  end

  test "mint shows the secret once and list then shows prefix only", %{conn: conn, token: token} do
    {:ok, view, _html} = live(authed(conn, token), "/portal/portal-keys/keys")

    view |> element("#portal-mint-button") |> render_click()

    html =
      view
      |> form("#portal-mint-modal form", key: %{name: "laptop"})
      |> render_submit()

    assert html =~ "Copy your key now"
    assert html =~ "orchard_sk_"
    assert html =~ "portal-secret-value"
    refute html =~ "data-secret="
    assert html =~ "this Workspace has no active authorized Model"

    view
    |> element("#portal-secret-modal form")
    |> render_change(%{"ack" => "true"})

    html = view |> element("#portal-secret-done") |> render_click()
    refute html =~ "orchard_sk_"
    assert html =~ "laptop"
    assert html =~ "orchard_kp_"
  end

  test "mint shows an inert exact-model curl from the new key without claiming runtime success",
       %{
         conn: conn,
         token: token,
         tenant: tenant
       } do
    default_model = create_model!(%{model_id: "alpha/model", version: "v1", state: :active})
    requested_model = create_model!(%{model_id: "zeta/model", version: "v2", state: :active})
    grant_model_access!(tenant, default_model)
    grant_model_access!(tenant, requested_model)

    with_public_https(fn ->
      {:ok, view, html} =
        live(authed(conn, token), "/portal/portal-keys/keys?model=zeta%2Fmodel%40v2")

      assert html =~ "Requested Model"
      assert html =~ "zeta/model@v2"
      view |> element("#portal-mint-button") |> render_click()

      html =
        view
        |> form("#portal-mint-modal form", key: %{name: "first-request"})
        |> render_submit()

      assert has_element?(view, "#portal-curl-value", "zeta/model@v2")
      assert html =~ "Authorization: Bearer orchard_sk_"
      assert html =~ "/v1/chat/completions"
      assert html =~ "This example has not run"
      assert html =~ "Runtime availability and readiness are checked when you send the request"
      refute html =~ "Request completed"
    end)
  end

  test "mint does not substitute another authorized model for an unavailable exact request", %{
    conn: conn,
    token: token,
    tenant: tenant
  } do
    model = create_model!(%{model_id: "available/model", state: :active})
    grant_model_access!(tenant, model)

    with_public_https(fn ->
      {:ok, view, _html} =
        live(authed(conn, token), "/portal/portal-keys/keys?model=missing%2Fmodel%40main")

      view |> element("#portal-mint-button") |> render_click()

      html =
        view
        |> form("#portal-mint-modal form", key: %{name: "unavailable-model"})
        |> render_submit()

      refute has_element?(view, "#portal-curl-value")
      assert html =~ "requested Model is not active and authorized for this Workspace"
      assert html =~ "Your key was still minted"
    end)
  end

  test "mint validation stays inside the dialog and describes the key-name input", %{
    conn: conn,
    token: token
  } do
    {:ok, view, _html} = live(authed(conn, token), "/portal/portal-keys/keys")
    view |> element("#portal-mint-button") |> render_click()

    view
    |> form("#portal-mint-modal form", key: %{name: "   "})
    |> render_submit()

    assert has_element?(view, "#portal-mint-modal #portal-mint-error", "can't be blank")

    assert has_element?(
             view,
             ~s|#portal-key-name[aria-invalid="true"][aria-describedby="portal-mint-error"]|
           )

    refute has_element?(view, "#portal-keys #portal-mint-error")

    view |> element("#portal-mint-modal button", "Cancel") |> render_click()
    view |> element("#portal-mint-button") |> render_click()

    refute has_element?(view, "#portal-mint-error")
    assert has_element?(view, ~s|#portal-key-name[value=""]:not([aria-invalid])|)

    view
    |> form("#portal-mint-modal form", key: %{name: "corrected-key"})
    |> render_submit()

    assert has_element?(view, "#portal-secret-modal")
    refute has_element?(view, "#portal-mint-error")
  end

  test "revoke failure stays inside its dialog and clears when the dialog closes", %{
    conn: conn,
    token: token
  } do
    {:ok, minted} =
      Governance.create_portal_api_key(token, "portal-keys", %{name: "stale-revoke"})

    {:ok, view, _html} = live(authed(conn, token), "/portal/portal-keys/keys")
    view |> element("#portal-revoke-#{minted.api_key.id}") |> render_click()

    minted.api_key
    |> Ecto.Changeset.change(portal_user_id: nil)
    |> Repo.update!()

    view
    |> form("#portal-revoke-modal form", confirmation: "stale-revoke")
    |> render_change()

    view |> form("#portal-revoke-modal form") |> render_submit()

    assert has_element?(view, "#portal-revoke-modal #portal-revoke-error[role=alert]")
    refute has_element?(view, "#portal-keys #portal-revoke-error")

    view |> element("#portal-revoke-modal button", "Cancel") |> render_click()
    refute has_element?(view, "#portal-revoke-error")
  end

  test "stale cap rejection renders once and successful revoke clears it", %{
    conn: conn,
    token: token
  } do
    Enum.each(1..9, fn index ->
      assert {:ok, _key} =
               Governance.create_portal_api_key(token, "portal-keys", %{
                 name: "seed-#{index}"
               })
    end)

    {:ok, view, _html} = live(authed(conn, token), "/portal/portal-keys/keys")

    assert has_element?(
             view,
             "#portal-key-cap-message[role=status][aria-atomic=true][tabindex='-1']",
             ""
           )

    refute has_element?(view, "#portal-key-cap-message", "Portal cap reached")
    view |> element("#portal-mint-button") |> render_click()

    assert {:ok, tenth} =
             Governance.create_portal_api_key(token, "portal-keys", %{name: "concurrent-tenth"})

    cap_html =
      view
      |> form("#portal-mint-modal form", key: %{name: "stale-eleventh"})
      |> render_submit()

    assert cap_html =~ "10 / 10"
    assert cap_occurrences(cap_html) == 1
    assert cap_html =~ "phx-mounted"
    refute has_element?(view, "#portal-mint-modal")

    view
    |> element("#portal-revoke-#{tenth.api_key.id}")
    |> render_click()

    view
    |> form("#portal-revoke-modal form", confirmation: "concurrent-tenth")
    |> render_change()

    revoked_html = view |> form("#portal-revoke-modal form") |> render_submit()

    assert revoked_html =~ "9 / 10"
    assert cap_occurrences(revoked_html) == 0
    assert has_element?(view, "#portal-mint-button:not([disabled])")
  end

  test "successful tenth mint keeps focus ownership with the one-time-secret dialog", %{
    conn: conn,
    token: token
  } do
    Enum.each(1..9, fn index ->
      assert {:ok, _key} =
               Governance.create_portal_api_key(token, "portal-keys", %{
                 name: "focus-seed-#{index}"
               })
    end)

    {:ok, view, _html} = live(authed(conn, token), "/portal/portal-keys/keys")
    view |> element("#portal-mint-button") |> render_click()

    html =
      view
      |> form("#portal-mint-modal form", key: %{name: "focus-tenth"})
      |> render_submit()

    assert html =~ "10 / 10"
    assert has_element?(view, "#portal-secret-modal[role=dialog][aria-modal=true]")
    refute html =~ "phx-mounted"
  end

  test "cap rejection keeps retry feedback when capacity is relieved before refresh", %{
    conn: conn,
    token: token
  } do
    Enum.each(1..9, fn index ->
      assert {:ok, _key} =
               Governance.create_portal_api_key(token, "portal-keys", %{
                 name: "race-seed-#{index}"
               })
    end)

    {:ok, view, _html} = live(authed(conn, token), "/portal/portal-keys/keys")
    view |> element("#portal-mint-button") |> render_click()

    assert {:ok, tenth} =
             Governance.create_portal_api_key(token, "portal-keys", %{name: "race-tenth"})

    test_pid = self()

    handler_id =
      {__MODULE__, :relieve_cap_before_refresh, System.unique_integer([:positive])}

    :telemetry.attach(
      handler_id,
      [:orchard, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        if String.contains?(metadata.query, ~s|ORDER BY a0."inserted_at" DESC|) do
          send(test_pid, {:listing_started, self()})

          receive do
            :capacity_relieved -> :ok
          after
            1_000 -> raise "timed out waiting for the capacity race"
          end
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    submitter =
      Task.async(fn ->
        view
        |> form("#portal-mint-modal form", key: %{name: "retry-me"})
        |> render_submit()
      end)

    assert_receive {:listing_started, listing_pid}, 1_000

    assert {:ok, _revoked} =
             Governance.revoke_portal_api_key(token, "portal-keys", tenth.api_key.id)

    send(listing_pid, :capacity_relieved)
    html = Task.await(submitter)

    assert html =~ "9 / 10"
    assert has_element?(view, "#portal-mint-modal #portal-mint-error", "try again")
    assert has_element?(view, ~s|#portal-key-name[value="retry-me"]|)
    assert cap_occurrences(html) == 0
  end

  test "reconnect after mint does not restore the plaintext token", %{
    conn: conn,
    token: token
  } do
    {:ok, view, _html} = live(authed(conn, token), "/portal/portal-keys/keys")
    view |> element("#portal-mint-button") |> render_click()

    view
    |> form("#portal-mint-modal form", key: %{name: "ephemeral"})
    |> render_submit()

    assert render(view) =~ "orchard_sk_"

    {:ok, _view, html} = live(authed(conn, token), "/portal/portal-keys/keys")
    refute html =~ "orchard_sk_"
    assert html =~ "ephemeral"
  end

  test "clipboard failure keeps the secret visible", %{conn: conn, token: token} do
    {:ok, view, _html} = live(authed(conn, token), "/portal/portal-keys/keys")
    view |> element("#portal-mint-button") |> render_click()

    html =
      view
      |> form("#portal-mint-modal form", key: %{name: "copy-fail"})
      |> render_submit()

    assert html =~ "orchard_sk_"
    [_, api_key_id] = Regex.run(~r/data-api-key-id="([^"]+)"/, html)

    html = render_hook(view, "generated_secret_copy_failed", %{"api_key_id" => api_key_id})
    assert html =~ "Copy failed"
    assert html =~ "orchard_sk_"
    assert html =~ "portal-secret-value"
  end

  test "revoke requires typing the key name", %{conn: conn, token: token} do
    {:ok, minted} =
      Governance.create_portal_api_key(token, "portal-keys", %{name: "typed-revoke"})

    {:ok, view, _html} = live(authed(conn, token), "/portal/portal-keys/keys")
    view |> element("#portal-revoke-#{minted.api_key.id}") |> render_click()

    html =
      view
      |> form("#portal-revoke-modal form", confirmation: "wrong-name")
      |> render_change()

    assert html =~ "disabled"
    assert Repo.get!(Orchard.Governance.ApiKey, minted.api_key.id).revoked_at == nil

    view
    |> form("#portal-revoke-modal form", confirmation: "typed-revoke")
    |> render_change()

    html = view |> form("#portal-revoke-modal form") |> render_submit()
    assert html =~ "Revoked"
    assert Repo.get!(Orchard.Governance.ApiKey, minted.api_key.id).revoked_at
  end

  test "Portal User disable fails revoke on a standing keys socket", %{
    conn: conn,
    token: token,
    tenant: tenant,
    user: user
  } do
    {:ok, minted} =
      Governance.create_portal_api_key(token, "portal-keys", %{name: "standing-revoke"})

    {:ok, view, _html} = live(authed(conn, token), "/portal/portal-keys/keys")
    assert {:ok, _} = Governance.disable_portal_user(tenant, user)

    view |> element("#portal-revoke-#{minted.api_key.id}") |> render_click()

    view
    |> form("#portal-revoke-modal form", confirmation: "standing-revoke")
    |> render_change()

    assert {:error, {:redirect, %{to: "/portal/portal-keys"}}} =
             view |> form("#portal-revoke-modal form") |> render_submit()

    assert Repo.get!(Orchard.Governance.ApiKey, minted.api_key.id).revoked_at == nil
  end

  defp authed(conn, token) do
    conn
    |> https_conn()
    |> Phoenix.ConnTest.init_test_session(%{Auth.session_token_key() => token})
  end

  defp start_verifier! do
    case Process.whereis(PortalPasswordVerifier) do
      nil -> start_supervised!(PortalPasswordVerifier)
      _pid -> :ok
    end
  end

  defp cap_occurrences(html), do: length(Regex.scan(~r/Portal cap reached/, html))

  defp with_public_https(fun) do
    previous_endpoint = Application.fetch_env!(:orchard_controller, Endpoint)

    endpoint =
      Keyword.put(previous_endpoint, :url,
        scheme: "https",
        host: "orchard.test",
        port: 443
      )

    try do
      Application.put_env(:orchard_controller, Endpoint, endpoint)
      :ok = Endpoint.config_change([{Endpoint, endpoint}], [])
      fun.()
    after
      Application.put_env(:orchard_controller, Endpoint, previous_endpoint)
      :ok = Endpoint.config_change([{Endpoint, previous_endpoint}], [])
    end
  end
end
