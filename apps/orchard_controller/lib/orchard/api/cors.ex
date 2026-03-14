defmodule Orchard.API.CORS do
  @moduledoc """
  Endpoint-level CORS plug that resolves allowed origins at runtime.

  Reads `cors_origins` from the `Orchard.API.Endpoint` config on every
  request (in `call/2`, not `init/1`) so that origin lists are never
  captured at compile time.

  Behavior:
  - If `cors_origins` is empty or nil → pass through unchanged (no-op).
  - Allowed origin on normal request → add CORS response headers, continue.
  - Allowed origin on preflight (OPTIONS + Origin + Request-Method) →
    respond 204, set headers, halt.
  - Disallowed origin → no CORS headers, continue normally.

  ## Endpoint placement

  Insert between `Plug.Head` and `Plug.Parsers` so preflights are
  answered before body parsing:

      plug Plug.Head
      plug Orchard.API.CORS
      plug Plug.Parsers, ...
  """

  @behaviour Plug

  @cors_methods ["GET", "POST", "OPTIONS"]
  @cors_headers [
    "Authorization",
    "Content-Type",
    "Idempotency-Key",
    "OpenAI-Beta",
    "X-Requested-With"
  ]
  @cors_expose ["x-request-id"]

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case cors_origins() do
      origins when origins in [nil, []] ->
        conn

      origins when is_list(origins) ->
        cors_opts =
          CORSPlug.init(
            origin: origins,
            methods: @cors_methods,
            headers: @cors_headers,
            expose: @cors_expose,
            credentials: false,
            send_preflight_response?: true
          )

        CORSPlug.call(conn, cors_opts)

      other ->
        raise ArgumentError,
              "expected cors_origins to be a list of origin strings, got: #{inspect(other)}"
    end
  end

  defp cors_origins do
    :orchard_controller
    |> Application.get_env(Orchard.API.Endpoint, [])
    |> Keyword.get(:cors_origins, [])
  end
end
