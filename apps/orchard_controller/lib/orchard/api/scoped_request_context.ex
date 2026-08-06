defmodule Orchard.API.ScopedRequestContext do
  @moduledoc """
  Shared bearer-token authentication and authorization plug for cluster-scoped
  API surfaces (`/admin/v1/*`, `/ops/v1/*`).

  Concrete plugs configure the authorization callback and the role-required
  error via `use Orchard.API.ScopedRequestContext, ...`, keeping their own
  public module names while sharing the authentication and error-response flow.
  """

  alias Orchard.API.{AdminErrorHelpers, AuthenticationFailure}
  alias Orchard.Governance

  @invalid_api_key_message "Invalid API key provided."

  @type authorizer :: (Governance.api_key_auth_result() -> :ok | {:error, atom()})

  @type config :: %{
          authorizer: authorizer(),
          required_code: String.t(),
          required_message: String.t()
        }

  @doc false
  defmacro __using__(opts) do
    authorizer = Keyword.fetch!(opts, :authorizer)
    required_code = Keyword.fetch!(opts, :required_code)
    required_message = Keyword.fetch!(opts, :required_message)

    quote do
      @behaviour Plug

      @impl Plug
      @spec init(Keyword.t()) :: Keyword.t()
      def init(opts), do: opts

      @impl Plug
      @spec call(Plug.Conn.t(), Keyword.t()) :: Plug.Conn.t()
      def call(conn, _opts) do
        unquote(__MODULE__).call(conn, %{
          authorizer: unquote(authorizer),
          required_code: unquote(required_code),
          required_message: unquote(required_message)
        })
      end
    end
  end

  @spec call(Plug.Conn.t(), config()) :: Plug.Conn.t()
  def call(conn, config) do
    case bearer_token(conn) do
      {:ok, token} ->
        authenticate_request(conn, token, config)

      {:error, reason} ->
        conn
        |> audit_auth_failure(nil, reason)
        |> send_auth_error()
    end
  end

  defp authenticate_request(conn, token, config) do
    case Governance.authenticate_api_key(token) do
      {:ok, auth_context} ->
        Governance.touch_api_key_last_used(auth_context.api_key_id)
        authorize_request(conn, auth_context, config)

      {:error, reason} ->
        conn
        |> audit_auth_failure(token, reason)
        |> send_auth_error()
    end
  end

  defp authorize_request(conn, auth_context, config) do
    case config.authorizer.(auth_context) do
      :ok ->
        assign_auth_context(conn, auth_context)

      {:error, _reason} ->
        send_role_required_error(conn, config)
    end
  end

  defp assign_auth_context(conn, auth_context) do
    conn
    |> Plug.Conn.assign(:tenant_id, auth_context.tenant_id)
    |> Plug.Conn.assign(:principal_type, auth_context.principal_type)
    |> Plug.Conn.assign(:principal_id, auth_context.principal_id)
    |> Plug.Conn.assign(:service_account_id, auth_context.service_account_id)
    |> Plug.Conn.assign(:api_key_id, auth_context.api_key_id)
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
    conn
  end

  defp send_auth_error(conn) do
    conn
    |> AdminErrorHelpers.send_error(:unauthorized, "invalid_api_key", @invalid_api_key_message)
    |> Plug.Conn.halt()
  end

  defp send_role_required_error(conn, config) do
    conn
    |> AdminErrorHelpers.send_error(:forbidden, config.required_code, config.required_message)
    |> Plug.Conn.halt()
  end
end
