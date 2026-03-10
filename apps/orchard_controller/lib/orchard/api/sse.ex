defmodule Orchard.API.SSE do
  @moduledoc """
  Server-Sent Events framing for OpenAI-compatible streaming.

  Centralizes the SSE wire format so controllers only deal with
  domain data structures. Handles three cases per SPEC.md §7.2.4:

    1. Normal stream: emit typed `data:` chunks, then `data: [DONE]`
    2. Error after stream start: emit `data: {"error":{...}}`, close
       without `[DONE]`
    3. Pre-stream error: not SSE — controller returns a normal JSON
       error response (not handled here)
  """

  import Plug.Conn

  @type chunk_data :: map()

  @doc """
  Initializes the connection for SSE streaming.

  Sets the required headers (`content-type: text/event-stream`,
  `cache-control: no-cache`, `connection: keep-alive`) and sends
  the response headers with status 200.

  Returns `{:ok, conn}` on success, `{:error, :closed}` if the
  connection is already closed.
  """
  @spec start(Plug.Conn.t()) :: {:ok, Plug.Conn.t()} | {:error, :closed}
  def start(conn) do
    conn =
      conn
      |> put_resp_header("content-type", "text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> send_chunked(200)

    {:ok, conn}
  rescue
    # Connection already closed before we could start streaming
    _e in Plug.Conn.AlreadySentError -> {:error, :closed}
  end

  @doc """
  Sends a single SSE data chunk.

  The `data` map is JSON-encoded and framed as `data: <json>\n\n`.

  Returns `{:ok, conn}` on success, `{:error, :closed}` if the
  client has disconnected.
  """
  @spec send_chunk(Plug.Conn.t(), chunk_data()) :: {:ok, Plug.Conn.t()} | {:error, :closed}
  def send_chunk(conn, data) when is_map(data) do
    payload = "data: " <> Jason.encode!(data) <> "\n\n"

    case chunk(conn, payload) do
      {:ok, conn} -> {:ok, conn}
      {:error, _reason} -> {:error, :closed}
    end
  end

  @doc """
  Sends the `data: [DONE]` terminator and halts the connection.

  This is the normal end-of-stream signal per the OpenAI SSE contract.
  """
  @spec send_done(Plug.Conn.t()) :: {:ok, Plug.Conn.t()} | {:error, :closed}
  def send_done(conn) do
    case chunk(conn, "data: [DONE]\n\n") do
      {:ok, conn} -> {:ok, conn}
      {:error, _reason} -> {:error, :closed}
    end
  end

  @doc """
  Sends an error envelope after streaming has already started.

  Per SPEC.md §7.2.4: emit `data: {"error":{...}}`, then close
  the stream **without** emitting `[DONE]`.

  ## Parameters

    * `message` — human-readable error description
    * `type` — OpenAI error type (e.g. `"server_error"`)
    * `opts` — optional `:param` and `:code` fields
  """
  @spec send_error(Plug.Conn.t(), String.t(), String.t(), keyword()) ::
          {:ok, Plug.Conn.t()} | {:error, :closed}
  def send_error(conn, message, type, opts \\ []) do
    envelope = %{
      error: %{
        message: message,
        type: type,
        param: Keyword.get(opts, :param),
        code: Keyword.get(opts, :code)
      }
    }

    payload = "data: " <> Jason.encode!(envelope) <> "\n\n"

    case chunk(conn, payload) do
      {:ok, conn} -> {:ok, conn}
      {:error, _reason} -> {:error, :closed}
    end
  end
end
