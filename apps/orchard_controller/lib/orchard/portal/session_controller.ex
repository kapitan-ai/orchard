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
  def new(conn, %{"organization_slug" => slug}) do
    slug = normalize_slug(slug)

    case maybe_redirect_authenticated(conn, slug) do
      {:halt, conn} ->
        conn

      :cont ->
        conn
        |> assign(:page_title, "Sign in")
        |> assign(:organization_slug, slug)
        |> assign(:login_error, nil)
        |> assign(:throttled, false)
        |> assign(:retry_after, nil)
        |> render(:new)
    end
  end

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"organization_slug" => slug} = params) do
    slug = normalize_slug(slug)
    email = login_email(params)
    password = login_password(params)

    case Governance.create_portal_session(slug, email, password, Auth.source_ip(conn)) do
      {:ok, result} ->
        conn
        |> Auth.put_session_token(result.token)
        |> redirect(to: "/portal/#{slug}/keys")

      {:error, :throttled} ->
        conn
        |> assign(:page_title, "Sign in")
        |> assign(:organization_slug, slug)
        |> assign(:login_error, nil)
        |> assign(:throttled, true)
        |> assign(:retry_after, "a few minutes")
        |> put_status(:too_many_requests)
        |> render(:new)

      {:error, _reason} ->
        conn
        |> assign(:page_title, "Sign in")
        |> assign(:organization_slug, slug)
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
  def invite(conn, %{"organization_slug" => slug, "token" => token}) do
    conn
    |> assign(:page_title, "Set your password")
    |> assign(:organization_slug, normalize_slug(slug))
    |> assign(:invite_token, token)
    |> assign(:invite_error, nil)
    |> render(:invite)
  end

  @spec redeem(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def redeem(conn, %{"organization_slug" => slug, "token" => token} = params) do
    slug = normalize_slug(slug)
    invite = Map.get(params, "invite", %{})
    password = Map.get(invite, "password", "")
    confirmation = Map.get(invite, "password_confirmation", "")

    result =
      if password == confirmation,
        do: Governance.redeem_portal_invite(token, password),
        else: {:error, :password_confirmation}

    case result do
      {:ok, _user} ->
        conn
        |> put_flash(:notice, "Password set. Sign in with your email.")
        |> redirect(to: "/portal/#{slug}")

      {:error, _reason} ->
        conn
        |> assign(:page_title, "Set your password")
        |> assign(:organization_slug, slug)
        |> assign(:invite_token, token)
        |> assign(:invite_error, :invalid_invite)
        |> put_status(:unprocessable_entity)
        |> render(:invite)
    end
  end


  defp maybe_redirect_authenticated(conn, slug) do
    case Auth.session_token(conn) do
      token when is_binary(token) ->
        case Governance.validate_portal_session(token, slug) do
          {:ok, _result} -> {:halt, redirect(conn, to: "/portal/#{slug}/keys")}
          {:error, :invalid_session} -> :cont
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

  defp normalize_slug(slug) when is_binary(slug), do: slug |> String.trim() |> String.downcase()
end
