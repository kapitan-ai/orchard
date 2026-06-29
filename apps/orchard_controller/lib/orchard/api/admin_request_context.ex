defmodule Orchard.API.AdminRequestContext do
  @moduledoc """
  Plug that resolves and authorizes `/admin/v1/*` caller context.
  """

  @behaviour Plug

  alias Orchard.API.AdminErrorHelpers
  alias Orchard.Governance

  @invalid_api_key_message "Invalid API key provided."
  @admin_required_message "Admin API requires a cluster-scoped admin API Client token."

  @impl Plug
  @spec init(Keyword.t()) :: Keyword.t()
  def init(opts), do: opts

  @impl Plug
  @spec call(Plug.Conn.t(), Keyword.t()) :: Plug.Conn.t()
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
    case Governance.authorize_admin_api(auth_context) do
      :ok ->
        conn
        |> Plug.Conn.assign(:tenant_id, auth_context.tenant_id)
        |> Plug.Conn.assign(:principal_type, auth_context.principal_type)
        |> Plug.Conn.assign(:principal_id, auth_context.principal_id)
        |> Plug.Conn.assign(:service_account_id, auth_context.service_account_id)
        |> Plug.Conn.assign(:api_key_id, auth_context.api_key_id)

      {:error, :admin_required} ->
        send_admin_required_error(conn)
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
    |> AdminErrorHelpers.send_error(:unauthorized, "invalid_api_key", @invalid_api_key_message)
    |> Plug.Conn.halt()
  end

  defp send_admin_required_error(conn) do
    conn
    |> AdminErrorHelpers.send_error(:forbidden, "admin_required", @admin_required_message)
    |> Plug.Conn.halt()
  end
end
