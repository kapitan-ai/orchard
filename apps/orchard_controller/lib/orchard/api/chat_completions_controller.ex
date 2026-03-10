defmodule Orchard.API.ChatCompletionsController do
  @moduledoc """
  OpenAI-compatible chat completions.

  `POST /v1/chat/completions` accepts chat requests per SPEC.md §7.2.4.
  Validation is handled by A3 (`ChatRequestValidator`), dispatch by A4.
  This controller owns HTTP-layer concerns: content-type, error envelope
  shaping, and stream vs non-stream response framing.
  """

  use Phoenix.Controller, formats: [:json]

  import Orchard.API.ErrorHelpers, only: [send_error: 5]

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, params) do
    with {:ok, _model} <- require_field(params, "model"),
         {:ok, _messages} <- require_field(params, "messages") do
      # Validation (A3) and dispatch (A4) will be wired here.
      # For now, return not-implemented with OpenAI error envelope.
      send_error(
        conn,
        :not_implemented,
        "Chat completions dispatch not yet wired",
        "api_error",
        code: "not_implemented"
      )
    else
      {:error, field} ->
        send_error(
          conn,
          :bad_request,
          "Missing required field: #{field}",
          "invalid_request_error",
          param: field,
          code: "missing_required_field"
        )
    end
  end

  defp require_field(params, field) do
    case Map.get(params, field) do
      nil -> {:error, field}
      value -> {:ok, value}
    end
  end
end
