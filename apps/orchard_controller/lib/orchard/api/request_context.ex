defmodule Orchard.API.RequestContext do
  alias Orchard.API.ErrorHelpers
  alias Orchard.Governance

  @moduledoc """
  Plug that resolves authenticated caller context for `/v1/*` requests.

  M2a requires a single `Authorization: Bearer <api_key>` header on the public
  inference surface. Successful authentication assigns:

    * `tenant_id`
    * `principal_id`
    * `api_key_id`

  Current M2a principal semantics are temporary: `principal_id = tenant_id`
  until service-account-backed principals exist. API-key expiry is still a known
  gap because the current governance schema only supports `revoked_at`.
  """

  @behaviour Plug

  @invalid_api_key_message "Invalid API key provided."
  @invalid_api_key_type "authentication_error"
  @invalid_api_key_code "invalid_api_key"

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

        conn
        |> Plug.Conn.assign(:tenant_id, auth_context.tenant_id)
        |> Plug.Conn.assign(:principal_id, auth_context.principal_id)
        |> Plug.Conn.assign(:api_key_id, auth_context.api_key_id)

      {:error, reason} ->
        conn
        |> audit_auth_failure(token, reason)
        |> send_auth_error()
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
    Governance.audit_api_key_auth_failure(token, reason)
    conn
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
end
