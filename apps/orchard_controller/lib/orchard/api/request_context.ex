defmodule Orchard.API.RequestContext do
  alias Orchard.API.{AuthenticationFailure, ErrorHelpers}
  alias Orchard.Governance
  alias Orchard.SentryContext

  @moduledoc """
  Plug that resolves authenticated caller context for `/v1/*` requests.

  M2a requires a single `Authorization: Bearer <api-token>` header on the
  public inference surface.
  The bearer credential may be tenant-direct or service-account-owned.
  Successful authentication assigns:

    * `tenant_id`
    * `principal_type`
    * `principal_id`
    * `service_account_id`
    * `api_key_id`
  """

  @behaviour Plug

  @invalid_api_key_message "Invalid API key provided."
  @invalid_api_key_type "authentication_error"
  @invalid_api_key_code "invalid_api_key"
  @api_client_disabled_message "API client is disabled."
  @forbidden_message "Forbidden."

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case bearer_token(conn) do
      {:ok, token} ->
        authenticate_request(conn, token)

      {:error, reason} ->
        conn
        |> audit_auth_failure(nil, reason)
        |> send_auth_error()
    end
  end

  defp authenticate_request(conn, token) do
    case Governance.authenticate_api_key(token) do
      {:ok, auth_context} ->
        Governance.touch_api_key_last_used(auth_context.api_key_id)
        authorize_request(conn, auth_context)

      {:error, reason} ->
        conn
        |> audit_auth_failure(token, reason)
        |> send_auth_error()
    end
  end

  defp authorize_request(conn, auth_context) do
    case Governance.authorize_public_inference(auth_context) do
      :ok ->
        put_auth_success_context(auth_context)

        conn
        |> Plug.Conn.assign(:tenant_id, auth_context.tenant_id)
        |> Plug.Conn.assign(:principal_type, auth_context.principal_type)
        |> Plug.Conn.assign(:principal_id, auth_context.principal_id)
        |> Plug.Conn.assign(:service_account_id, auth_context.service_account_id)
        |> Plug.Conn.assign(:api_key_id, auth_context.api_key_id)

      {:error, reason} ->
        put_auth_failure_context(reason)
        send_authorization_error(conn, reason)
    end
  end

  defp bearer_token(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      [header] -> parse_bearer_header(header)
      [] -> {:error, :missing_header}
      _headers -> {:error, :malformed_header}
    end
  end

  defp parse_bearer_header("Bearer " <> token) when token != "", do: {:ok, token}
  defp parse_bearer_header(_header), do: {:error, :malformed_header}

  defp audit_auth_failure(conn, token, reason) do
    AuthenticationFailure.record(token, reason)
    put_auth_failure_context(reason)
    conn
  end

  defp put_auth_success_context(auth_context) do
    if SentryContext.controller_enabled?() do
      put_api_tags()

      auth_context
      |> SentryContext.build_caller_extra()
      |> SentryContext.put_extra()

      SentryContext.add_breadcrumb(
        category: "orchard.auth",
        message: "auth.success",
        level: :info,
        data: %{auth_mechanism: "bearer"}
      )
    end
  end

  defp put_auth_failure_context(reason) do
    if SentryContext.controller_enabled?() do
      put_api_tags()

      SentryContext.add_breadcrumb(
        category: "orchard.auth",
        message: "auth.failure",
        level: :warning,
        data: %{reason: reason}
      )
    end
  end

  defp put_api_tags do
    SentryContext.put_tags(%{
      orchard_app: "controller",
      orchard_surface: "api"
    })
  end

  defp send_auth_error(conn) do
    conn
    |> ErrorHelpers.send_error(
      :unauthorized,
      @invalid_api_key_message,
      @invalid_api_key_type,
      code: @invalid_api_key_code
    )
    |> Plug.Conn.halt()
  end

  defp send_authorization_error(conn, :api_client_disabled) do
    conn
    |> ErrorHelpers.send_error(
      :forbidden,
      @api_client_disabled_message,
      "invalid_request_error",
      code: "api_client_disabled"
    )
    |> Plug.Conn.halt()
  end

  defp send_authorization_error(conn, :missing_inference_client_access) do
    conn
    |> ErrorHelpers.send_error(
      :forbidden,
      @forbidden_message,
      "invalid_request_error",
      code: "forbidden"
    )
    |> Plug.Conn.halt()
  end
end
