defmodule Orchard.API.ErrorHelpers do
  @moduledoc """
  OpenAI-compatible error envelope builder.

  All public inference errors use this shape per SPEC.md §7.2.6:

      %{
        "error" => %{
          "message" => "...",
          "type"    => "...",
          "param"   => "...",
          "code"    => "..."
        }
      }

  ## Error types (per §7.2.7)

    * `"invalid_request_error"` — 400 bad request / unsupported parameter
    * `"authentication_error"` — 401
    * `"permission_error"` — 403
    * `"not_found_error"` — 404
    * `"conflict_error"` — 409
    * `"rate_limit_error"` — 429
    * `"server_error"` — 503, 504
    * `"api_error"` — catch-all
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  @doc """
  Sends an OpenAI-compatible error response.

  ## Parameters

    * `conn` — the Plug connection
    * `status` — HTTP status atom or integer
    * `message` — human-readable error description
    * `type` — OpenAI error type string
    * `opts` — optional `:param` and `:code` fields
  """
  @spec send_error(Plug.Conn.t(), atom() | integer(), String.t(), String.t(), keyword()) ::
          Plug.Conn.t()
  def send_error(conn, status, message, type, opts \\ []) do
    conn
    |> put_status(status)
    |> json(%{
      error: %{
        message: message,
        type: type,
        param: Keyword.get(opts, :param),
        code: Keyword.get(opts, :code)
      }
    })
  end

  @doc """
  Builds an error envelope map without sending it.

  Useful for SSE error-after-start and other non-controller contexts.
  """
  @spec error_envelope(String.t(), String.t(), keyword()) :: map()
  def error_envelope(message, type, opts \\ []) do
    %{
      error: %{
        message: message,
        type: type,
        param: Keyword.get(opts, :param),
        code: Keyword.get(opts, :code)
      }
    }
  end
end
