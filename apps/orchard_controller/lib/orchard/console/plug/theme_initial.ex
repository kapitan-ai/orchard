defmodule OrchardConsole.Plug.ThemeInitial do
  @moduledoc false

  @behaviour Plug

  import Plug.Conn, only: [assign: 3, fetch_cookies: 1]

  # Keep this server contract aligned with docs/DESIGN.md §13.1 and app.js.
  @cookie "orchard_console_theme"
  @default_theme "system"
  @valid_themes ~w(system light dark)

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    conn = fetch_cookies(conn)

    assign(conn, :initial_theme, normalize_theme(conn.cookies[@cookie]))
  end

  defp normalize_theme(theme) when theme in @valid_themes, do: theme
  defp normalize_theme(_theme), do: @default_theme
end
