defmodule OrchardConsole.WorkspaceHandoffLiveTest do
  use Orchard.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Orchard.TestSupport.ModelRequestFixtures
  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Orchard.API.Endpoint
  alias Orchard.Governance
  alias Orchard.Governance.{ApiKey, PortalInviteToken, PortalUser}
  alias Orchard.Models.Access
  alias Orchard.Repo

  @moduletag :live
  @moduletag :db

  setup do
    Sandbox.mode(Repo, {:shared, self()})
    previous_mode = Application.get_env(:orchard_controller, :transport_mode)
    previous_endpoint = Application.fetch_env!(:orchard_controller, Endpoint)
    Application.put_env(:orchard_controller, :transport_mode, :direct_https)

    endpoint =
      Keyword.put(previous_endpoint, :url, scheme: "https", host: "orchard.test", port: 443)

    Application.put_env(:orchard_controller, Endpoint, endpoint)
    Endpoint.config_change([{Endpoint, endpoint}], [])

    on_exit(fn ->
      if previous_mode,
        do: Application.put_env(:orchard_controller, :transport_mode, previous_mode),
        else: Application.delete_env(:orchard_controller, :transport_mode)

      Application.put_env(:orchard_controller, Endpoint, previous_endpoint)
    end)

    {:ok, workspace} =
      Governance.create_tenant(%{slug: "handoff-workspace", name: "Handoff workspace"})

    model = create_model!(%{state: :active})
    %{workspace: workspace, model: model}
  end

  test "six steps stay visible and explicit Workspace starts at model access without granting anything",
       %{conn: conn, workspace: workspace} do
    {:ok, view, html} = live(conn, path(workspace))
    assert html =~ "Step 2 of 6"
    assert html =~ "Handoff workspace"

    assert has_element?(
             view,
             "nav[aria-label='Colleague handoff steps'] [aria-disabled='true']",
             "First request"
           )

    assert has_element?(view, "#handoff-step-2")
    refute has_element?(view, "#handoff-step-3")
    assert {:ok, []} = Access.list_model_access(workspace)
    render_patch(view, path(workspace) <> "?step=6")
    assert has_element?(view, "#handoff-step-2")
  end

  test "missing grant gives exact scoped administrator commands and refresh observes actual grant",
       %{conn: conn, workspace: workspace, model: model} do
    {:ok, view, _html} = live(conn, path(workspace))
    choose_model(view, model)
    html = render(view)
    assert html =~ "Not granted"
    assert html =~ "orchardctl models access grant"
    assert html =~ workspace.id
    assert html =~ "#{model.model_id}@#{model.version}"
    assert {:error, :not_granted} = Access.get_model_access(workspace, model)
    {:ok, _grant} = Access.grant_model_access(workspace, model)
    render_click(view, "refresh")
    assert has_element?(view, "#handoff-model-access", "Granted")
    refute has_element?(view, "#handoff-model-access", "orchardctl models access grant")
  end

  test "real invitation separates identity creation, link issuance, expiry and placeholder request",
       %{conn: conn, workspace: workspace, model: model} do
    {:ok, view, _html} = live(conn, path(workspace))
    choose_model(view, model)
    render_click(view, "next")

    view
    |> form("#handoff-colleague-form", colleague: %{email: "person@example.test"})
    |> render_submit()

    assert has_element?(view, "#handoff-step-4")
    assert Repo.aggregate(PortalUser, :count) == 1
    assert Repo.aggregate(PortalInviteToken, :count) == 0
    assert Repo.aggregate(ApiKey, :count) == 0
    render_click(view, "next")
    view |> element("#handoff-issue-invite") |> render_click()
    assert Repo.aggregate(PortalInviteToken, :count) == 1

    assert has_element?(
             view,
             "#handoff-invite-value",
             "https://orchard.test/portal/handoff-workspace/invites/"
           )

    assert has_element?(view, "#handoff-invite-value", "?model=")
    socket = :sys.get_state(view.pid).socket
    first_url = socket.assigns.invite.url
    render_click(view, "issue_invite")
    refute :sys.get_state(view.pid).socket.assigns.invite.url == first_url
    assert Repo.aggregate(PortalInviteToken, :count) == 1
    expires_at = :sys.get_state(view.pid).socket.assigns.invite.expires_at
    send(view.pid, {:expire_invite, expires_at})
    refute render(view) =~ "handoff-invite-value"
    render_click(view, "next")
    assert has_element?(view, "#handoff-request-example", "<YOUR_OWN_API_KEY>")
    assert has_element?(view, "#handoff-request-result", "not observed")
    assert Repo.aggregate(ApiKey, :count) == 0
    assert {:error, :not_granted} = Access.get_model_access(workspace, model)
  end

  test "existing active Portal User with missing grant is reused without another invite", %{
    conn: conn,
    workspace: workspace,
    model: model
  } do
    {:ok, user} = Governance.create_portal_invite(workspace, %{email: "active@example.test"})
    Repo.update_all(from(user in PortalUser, where: user.id == ^user.id), set: [status: "active"])
    {:ok, view, _html} = live(conn, path(workspace))
    choose_model(view, model)
    render_click(view, "next")

    view
    |> form("#handoff-colleague-form", colleague: %{email: "active@example.test"})
    |> render_submit()

    assert has_element?(view, "#handoff-step-4", "active")
    render_click(view, "next")
    refute has_element?(view, "#handoff-issue-invite")
    assert render(view) =~ "already active"
    assert Repo.aggregate(PortalUser, :count) == 1
    assert Repo.aggregate(PortalInviteToken, :count) == 0
    render_patch(view, path(workspace) <> "?step=2")
    assert has_element?(view, "#handoff-model-access", "Not granted")
  end

  test "issuance failure retains saved identity for retry without duplicate Portal Users", %{
    conn: conn,
    workspace: workspace,
    model: model
  } do
    {:ok, view, _html} = live(conn, path(workspace))
    choose_model(view, model)
    render_click(view, "next")

    view
    |> form("#handoff-colleague-form", colleague: %{email: "retry@example.test"})
    |> render_submit()

    render_click(view, "next")
    Application.put_env(:orchard_controller, :transport_mode, :plain_http_localhost)
    render_click(view, "issue_invite")
    assert render(view) =~ "Configure a public HTTPS Portal address"
    assert Repo.aggregate(PortalUser, :count) == 1
    assert Repo.aggregate(PortalInviteToken, :count) == 0
    Application.put_env(:orchard_controller, :transport_mode, :direct_https)
    render_click(view, "issue_invite")
    assert has_element?(view, "#handoff-invite-value")
    assert Repo.aggregate(PortalUser, :count) == 1
  end

  test "changing Workspace clears model, colleague draft and visible invite", %{
    conn: conn,
    workspace: workspace,
    model: model
  } do
    {:ok, other} = Governance.create_tenant(%{slug: "other-handoff", name: "Other"})
    {:ok, view, _html} = live(conn, path(workspace))
    choose_model(view, model)
    render_click(view, "next")

    view
    |> form("#handoff-colleague-form", colleague: %{email: "scoped@example.test"})
    |> render_submit()

    render_click(view, "next")
    render_click(view, "issue_invite")
    assert has_element?(view, "#handoff-invite-value")
    render_patch(view, path(other))
    socket = :sys.get_state(view.pid).socket
    assert socket.assigns.workspace.id == other.id
    assert socket.assigns.selected == nil
    assert socket.assigns.email == ""
    assert socket.assigns.user == nil
    assert socket.assigns.invite == nil
    assert has_element?(view, "#handoff-step-2")
    assert {:ok, []} = Governance.list_portal_users(other)
  end

  test "service rejects a user disabled after review without creating a link or duplicate", %{
    conn: conn,
    workspace: workspace,
    model: model
  } do
    {:ok, view, _html} = live(conn, path(workspace))
    choose_model(view, model)
    render_click(view, "next")

    view
    |> form("#handoff-colleague-form", colleague: %{email: "disabled@example.test"})
    |> render_submit()

    user = :sys.get_state(view.pid).socket.assigns.user
    render_click(view, "next")
    {:ok, _disabled} = Governance.disable_portal_user(workspace, user.id)
    render_click(view, "issue_invite")
    assert render(view) =~ "The Portal User is already saved"
    assert Repo.aggregate(PortalUser, :count) == 1
    assert Repo.aggregate(PortalInviteToken, :count) == 0
    refute has_element?(view, "#handoff-invite-value")
    render_click(view, "refresh")
    assert has_element?(view, "#handoff-step-3")
    assert render(view) =~ "Portal User is unavailable or disabled"
    refute has_element?(view, "#handoff-issue-invite")
  end

  test "unknown Workspace and unknown model cannot start invitation mutations", %{
    conn: conn,
    workspace: workspace
  } do
    {:ok, view, _html} = live(conn, path(workspace))
    render_click(view, "choose_model", %{"model" => %{"id" => Ecto.UUID.generate()}})

    render_click(view, "prepare_colleague", %{"colleague" => %{"email" => "invalid@example.test"}})

    assert Repo.aggregate(PortalUser, :count) == 0
    render_patch(view, "/console/access/workspaces/not-a-uuid/handoff")
    assert has_element?(view, "#handoff-load-state", "Workspace not found")
  end

  test "SPEC 6.2 registered models remain unavailable in first-request guidance", %{
    conn: conn,
    workspace: workspace
  } do
    model = create_model!(%{state: :registered})
    {:ok, view, _html} = live(conn, path(workspace))
    choose_model(view, model)
    render_click(view, "next")

    view
    |> form("#handoff-colleague-form", colleague: %{email: "registered-model@example.test"})
    |> render_submit()

    render_click(view, "next")
    render_click(view, "next")
    assert has_element?(view, "#handoff-step-6", "registered")
    assert has_element?(view, "#handoff-step-6", "not currently available for Public Inference")
    refute has_element?(view, "#handoff-step-6", "Deprecation does not by itself block inference")
  end

  test "SPEC 6.2 deprecated models remain schedulable and removed models block sharing", %{
    conn: conn,
    workspace: workspace,
    model: model
  } do
    {:ok, view, _html} = live(conn, path(workspace))
    choose_model(view, model)
    render_click(view, "next")

    view
    |> form("#handoff-colleague-form", colleague: %{email: "catalog-change@example.test"})
    |> render_submit()

    {:ok, _model} = Orchard.Models.deprecate_model(model)
    render_click(view, "refresh")
    assert has_element?(view, "#handoff-step-4", "deprecated")
    render_click(view, "next")
    render_click(view, "next")
    assert has_element?(view, "#handoff-step-6", "Deprecation does not by itself block inference")
    refute has_element?(view, "#handoff-step-6", "not currently available for Public Inference")

    {:ok, _model} = Orchard.Models.retire_model(model.id)
    render_click(view, "refresh")
    assert has_element?(view, "#handoff-step-6", "retired")
    assert has_element?(view, "#handoff-step-6", "not currently available for Public Inference")
    refute has_element?(view, "#handoff-step-6", "Deprecation does not by itself block inference")
    render_patch(view, path(workspace) <> "?step=4")
    Repo.delete!(model)
    render_click(view, "refresh")
    assert has_element?(view, "#handoff-step-2")
    assert render(view) =~ "Selected model is no longer in Catalog"
    assert has_element?(view, "#handoff-next[disabled]")
    render_click(view, "next")
    render_click(view, "issue_invite")
    assert has_element?(view, "#handoff-step-2")
    assert Repo.aggregate(PortalInviteToken, :count) == 0
  end

  test "submit without a change event cannot retain an earlier colleague after rejection", %{
    conn: conn,
    workspace: workspace,
    model: model
  } do
    {:ok, disabled} = Governance.create_portal_invite(workspace, %{email: "blocked@example.test"})
    {:ok, _user} = Governance.disable_portal_user(workspace, disabled.id)
    {:ok, view, _html} = live(conn, path(workspace))
    choose_model(view, model)
    render_click(view, "next")

    view
    |> form("#handoff-colleague-form", colleague: %{email: "earlier@example.test"})
    |> render_submit()

    render_click(view, "next")
    render_click(view, "issue_invite")
    assert has_element?(view, "#handoff-invite-value")
    render_patch(view, path(workspace) <> "?step=3")

    view
    |> form("#handoff-colleague-form", colleague: %{email: "blocked@example.test"})
    |> render_submit()

    socket = :sys.get_state(view.pid).socket
    assert socket.assigns.user == nil
    assert socket.assigns.invite == nil
    assert socket.assigns.unlocked == 3
    assert socket.assigns.email == "blocked@example.test"
    render_patch(view, path(workspace) <> "?step=5")
    assert has_element?(view, "#handoff-step-3")
    render_click(view, "issue_invite")
    refute has_element?(view, "#handoff-invite-value")
    assert Repo.aggregate(PortalUser, :count) == 2
  end

  test "failed invitation retains the rendered email through Back and Continue", %{
    conn: conn,
    workspace: workspace,
    model: model
  } do
    Application.put_env(:orchard_controller, :transport_mode, :plain_http_localhost)
    {:ok, view, _html} = live(conn, path(workspace))
    choose_model(view, model)
    render_click(view, "next")

    view
    |> form("#handoff-colleague-form", colleague: %{email: "access-review@example.test"})
    |> render_change()

    view
    |> form("#handoff-colleague-form", colleague: %{email: "access-review@example.test"})
    |> render_submit()

    assert render(view) =~ "Configure public HTTPS"
    assert has_element?(view, "#handoff-colleague-email[value='access-review@example.test']")
    render_patch(view, path(workspace) <> "?step=2")
    render_click(view, "next")
    assert has_element?(view, "#handoff-colleague-email[value='access-review@example.test']")
    assert Repo.aggregate(PortalUser, :count) == 0
  end

  test "refresh returns later steps to model selection when the exact model disappears", %{
    conn: conn,
    workspace: workspace
  } do
    for step <- [5, 6] do
      model = create_model!(%{state: :active})
      {:ok, view, _html} = live(conn, path(workspace))
      choose_model(view, model)
      render_click(view, "next")

      view
      |> form("#handoff-colleague-form", colleague: %{email: "removed-#{step}@example.test"})
      |> render_submit()

      render_click(view, "next")
      if step == 6, do: render_click(view, "next")
      assert has_element?(view, "#handoff-step-#{step}")
      Repo.delete!(model)
      render_click(view, "refresh")

      assert has_element?(view, "#handoff-step-2")
      assert render(view) =~ "Selected model is no longer in Catalog"
      refute has_element?(view, "#handoff-issue-invite")
      refute has_element?(view, "nav[aria-label='Colleague handoff steps'] a[href$='step=5']")
      render_patch(view, path(workspace) <> "?step=6")
      assert has_element?(view, "#handoff-step-2")
      render_click(view, "issue_invite")
      assert Repo.aggregate(PortalInviteToken, :count) == 0
    end
  end

  test "leaving the invite reveal clears its plaintext and timer before Back or reissue", %{
    conn: conn,
    workspace: workspace,
    model: model
  } do
    {:ok, view, _html} = live(conn, path(workspace))
    choose_model(view, model)
    render_click(view, "next")

    view
    |> form("#handoff-colleague-form", colleague: %{email: "one-time@example.test"})
    |> render_submit()

    render_click(view, "next")
    render_click(view, "issue_invite")
    assigns = :sys.get_state(view.pid).socket.assigns
    first_url = assigns.invite.url
    first_token = Repo.one!(PortalInviteToken)
    assert has_element?(view, "#handoff-invite-value", first_url)

    render_click(view, "next")
    assert has_element?(view, "#handoff-step-6")
    assert :sys.get_state(view.pid).socket.assigns.invite == nil
    assert Process.read_timer(assigns.invite_timer) == false
    render_click(view, "issue_invite")
    assert Repo.one!(PortalInviteToken).id == first_token.id
    render_patch(view, path(workspace) <> "?step=5")
    refute has_element?(view, "#handoff-invite-value")
    refute render(view) =~ first_url

    render_click(view, "issue_invite")
    assert has_element?(view, "#handoff-invite-value")
    refute :sys.get_state(view.pid).socket.assigns.invite.url == first_url
    assert Repo.aggregate(PortalInviteToken, :count) == 1
    render_patch(view, path(workspace) <> "?step=4")
    assert :sys.get_state(view.pid).socket.assigns.invite == nil
    render_patch(view, path(workspace) <> "?step=5")
    refute has_element?(view, "#handoff-invite-value")
  end

  defp choose_model(view, model),
    do: view |> form("#handoff-model-form", model: %{id: model.id}) |> render_change()

  defp path(workspace), do: "/console/access/workspaces/#{workspace.id}/handoff"
end
