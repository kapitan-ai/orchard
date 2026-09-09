defmodule Orchard.Portal.SessionController do
  @moduledoc """
  Controller POST login so the portal token can be stored HttpOnly.
  """

  use Orchard.Portal, :controller

  alias Orchard.Governance
  alias Orchard.Portal.Auth
  alias Orchard.Portal.SessionHTML

  plug(:put_layout, html: {Orchard.Portal.Layouts, :app})
  plug(:put_root_layout, html: {Orchard.Portal.Layouts, :root})
  plug(:put_view, html: SessionHTML)

  @spec new(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def new(conn, %{"organization_slug" => slug} = params) do
    slug = normalize_slug(slug)
    requested_model = requested_model(params)

    case maybe_redirect_authenticated(conn, slug, requested_model) do
      {:halt, conn} ->
        conn

      :cont ->
        conn
        |> assign(:page_title, "Sign in")
        |> assign(:organization_slug, slug)
        |> assign(:requested_model, requested_model)
        |> assign(:form_action, requested_model_path("/portal/#{slug}/session", requested_model))
        |> assign(:login_error, nil)
        |> assign(:throttled, false)
        |> assign(:retry_after, nil)
        |> render(:new)
    end
  end

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"organization_slug" => slug} = params) do
    slug = normalize_slug(slug)
    requested_model = requested_model(params)
    email = login_email(params)
    password = login_password(params)

    case Governance.create_portal_session(slug, email, password, Auth.source_ip(conn)) do
      {:ok, result} ->
        conn
        |> Auth.put_session_token(result.token)
        |> redirect(to: requested_model_path("/portal/#{slug}/keys", requested_model))

      {:error, :throttled} ->
        conn
        |> assign(:page_title, "Sign in")
        |> assign(:organization_slug, slug)
        |> assign(:requested_model, requested_model)
        |> assign(:form_action, requested_model_path("/portal/#{slug}/session", requested_model))
        |> assign(:login_error, nil)
        |> assign(:throttled, true)
        |> assign(:retry_after, "a few minutes")
        |> put_status(:too_many_requests)
        |> render(:new)

      {:error, _reason} ->
        conn
        |> assign(:page_title, "Sign in")
        |> assign(:organization_slug, slug)
        |> assign(:requested_model, requested_model)
        |> assign(:form_action, requested_model_path("/portal/#{slug}/session", requested_model))
        |> assign(:login_error, :invalid_credentials)
        |> assign(:throttled, false)
        |> assign(:retry_after, nil)
        |> put_status(:unauthorized)
        |> render(:new)
    end
  end

  @spec delete(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete(conn, %{"organization_slug" => slug}) do
    slug = normalize_slug(slug)

    case Auth.session_token(conn) do
      token when is_binary(token) -> Governance.logout_portal_session(token)
      nil -> :ok
    end

    conn
    |> Auth.clear_session_token()
    |> redirect(to: "/portal/#{slug}")
  end

  @spec invite(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def invite(conn, %{"organization_slug" => slug, "token" => token} = params) do
    slug = normalize_slug(slug)
    requested_model = requested_model(params)

    case Governance.validate_portal_invite(slug, token) do
      :ok ->
        conn
        |> assign(:page_title, "Set your password")
        |> assign(:organization_slug, slug)
        |> assign(:requested_model, requested_model)
        |> assign(
          :form_action,
          requested_model_path("/portal/#{slug}/invites/#{token}", requested_model)
        )
        |> assign(:invite_token, token)
        |> assign(:invite_error, nil)
        |> render(:invite)

      {:error, _reason} ->
        conn
        |> assign(:page_title, "Invite unavailable")
        |> assign(:organization_slug, slug)
        |> assign(:requested_model, requested_model)
        |> assign(
          :form_action,
          requested_model_path("/portal/#{slug}/invites/#{token}", requested_model)
        )
        |> assign(:invite_token, nil)
        |> assign(:invite_error, :invalid_invite)
        |> put_status(:unprocessable_entity)
        |> render(:invite)
    end
  end

  @spec redeem(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def redeem(conn, %{"organization_slug" => slug, "token" => token} = params) do
    slug = normalize_slug(slug)
    requested_model = requested_model(params)
    invite = Map.get(params, "invite", %{})
    password = Map.get(invite, "password", "")
    confirmation = Map.get(invite, "password_confirmation", "")

    result =
      if password == confirmation,
        do: Governance.redeem_portal_invite(slug, token, password),
        else: {:error, :password_confirmation}

    case result do
      {:ok, _user} ->
        conn
        |> put_flash(:notice, "Password set. Sign in with your email.")
        |> redirect(to: requested_model_path("/portal/#{slug}", requested_model))

      {:error, _reason} ->
        conn
        |> assign(:page_title, "Set your password")
        |> assign(:organization_slug, slug)
        |> assign(:requested_model, requested_model)
        |> assign(
          :form_action,
          requested_model_path("/portal/#{slug}/invites/#{token}", requested_model)
        )
        |> assign(:invite_token, token)
        |> assign(:invite_error, :invalid_invite)
        |> put_status(:unprocessable_entity)
        |> render(:invite)
    end
  end

  defp maybe_redirect_authenticated(conn, slug, requested_model) do
    case Auth.session_token(conn) do
      token when is_binary(token) ->
        case Governance.validate_portal_session(token, slug) do
          {:ok, _result} ->
            {:halt,
             redirect(conn, to: requested_model_path("/portal/#{slug}/keys", requested_model))}

          {:error, :invalid_session} ->
            :cont
        end

      nil ->
        :cont
    end
  end

  defp login_email(%{"session" => %{"email" => email}}) when is_binary(email), do: email
  defp login_email(_params), do: ""

  defp login_password(%{"session" => %{"password" => password}}) when is_binary(password),
    do: password

  defp login_password(_params), do: ""

  defp requested_model(%{"model" => model}) when is_binary(model) and model != "", do: model
  defp requested_model(_params), do: nil

  defp requested_model_path(path, nil), do: path

  defp requested_model_path(path, model) do
    path <> "?" <> URI.encode_query(%{"model" => model})
  end

  defp normalize_slug(slug) when is_binary(slug), do: slug |> String.trim() |> String.downcase()
end
