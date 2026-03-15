defmodule OrchardConsole.Auth do
  @moduledoc """
  Plug that gates `/console` access with a feature flag and optional Basic Auth.

  Reads console config from `Application.get_env(:orchard_controller, :console)`
  at request time (not compile time) to support runtime configuration.

  Also provides `authorize_live_session/2` for LiveView `on_mount` hooks
  to re-check auth state on WebSocket mount/reconnect.

  ## Behavior

    * **Non-console paths**: passes through unchanged (no-op)
    * **`console_enabled: false`**: returns 404 and halts
    * **`auth: :none`**: passes through (dev/test mode)
    * **`auth: :basic`**: enforces HTTP Basic Auth with configured credentials;
      on success, writes a session marker so LiveView mounts can verify auth

  ## Config shape

      config :orchard_controller, :console,
        enabled: true,
        auth: :none | :basic,
        username: String.t() | nil,
        password: String.t() | nil

  ## Usage

  Add to the `:browser` pipeline in the router (after `:fetch_session`):

      pipeline :browser do
        plug :accepts, ["html"]
        plug :fetch_session
        plug OrchardConsole.Auth
        # ... remaining browser plugs
      end
  """

  @behaviour Plug

  @session_key "_orchard_console_authenticated"

  @doc "Returns the session key used to mark authenticated console sessions."
  @spec session_marker_key() :: String.t()
  def session_marker_key, do: @session_key

  @doc "Returns the current console config from application env."
  @spec console_config() :: keyword()
  def console_config, do: Application.get_env(:orchard_controller, :console, [])

  @doc """
  Checks whether a LiveView session is authorized for console access.

  Returns `:ok` if access is allowed, or `{:error, reason}` if denied.
  Used by `OrchardConsole.on_mount/4` to gate WebSocket mount/reconnect.
  """
  @spec authorize_live_session(map(), keyword()) :: :ok | {:error, :disabled | :unauthorized}
  def authorize_live_session(session, config) do
    cond do
      not config[:enabled] ->
        {:error, :disabled}

      config[:auth] == :none ->
        :ok

      config[:auth] == :basic ->
        if session[@session_key] == true, do: :ok, else: {:error, :unauthorized}

      true ->
        {:error, :unauthorized}
    end
  end

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{path_info: ["console" | _]} = conn, _opts) do
    config = Application.get_env(:orchard_controller, :console, [])

    if config[:enabled] do
      enforce_auth(conn, config)
    else
      conn
      |> Plug.Conn.send_resp(404, "Not Found")
      |> Plug.Conn.halt()
    end
  end

  def call(conn, _opts), do: conn

  defp enforce_auth(conn, config) do
    case config[:auth] do
      :none ->
        conn

      :basic ->
        username = require_credential!(config, :username)
        password = require_credential!(config, :password)
        enforce_basic_auth(conn, username, password)

      other ->
        raise ArgumentError,
              "invalid console auth mode: #{inspect(other)}. Expected :none or :basic"
    end
  end

  defp enforce_basic_auth(conn, username, password) do
    # If already authenticated via session marker, skip the challenge.
    if Plug.Conn.get_session(conn, @session_key) == true do
      conn
    else
      conn = Plug.BasicAuth.basic_auth(conn, username: username, password: password)

      # On successful auth (not halted), write the session marker.
      if conn.halted, do: conn, else: Plug.Conn.put_session(conn, @session_key, true)
    end
  end

  defp require_credential!(config, field) do
    case config[field] do
      value when is_binary(value) and value != "" ->
        if String.trim(value) == "" do
          raise ArgumentError,
                "console auth mode :basic requires a non-blank :#{field} " <>
                  "in :orchard_controller, :console config"
        end

        value

      _ ->
        raise ArgumentError,
              "console auth mode :basic requires a non-blank :#{field} " <>
                "in :orchard_controller, :console config"
    end
  end
end
