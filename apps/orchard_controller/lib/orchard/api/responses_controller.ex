defmodule Orchard.API.ResponsesController do
  @moduledoc """
  OpenAI-compatible sync `/v1/responses` facade for the bounded text-only subset.
  """

  use Phoenix.Controller, formats: [:json]

  import Orchard.API.ErrorHelpers, only: [send_error: 5]

  alias Orchard.API.InferenceControllerSupport
  alias Orchard.Inference.{ChatError, ResponsesOrchestrator, ResponsesSerializer}
  alias Orchard.InferenceEvent

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, params) do
    caller_context = InferenceControllerSupport.extract_caller_context(conn)
    tenant_id = Keyword.fetch!(caller_context, :tenant_id)

    with {:ok, idempotency} <-
           InferenceControllerSupport.build_idempotency_context(conn, tenant_id, params),
         {:proceed, conn} <- InferenceControllerSupport.resolve_idempotency(conn, idempotency),
         {:ok, canonical, model} <- ResponsesOrchestrator.prepare(params, caller_context) do
      execute_request(conn, canonical, model, idempotency)
    else
      {:halt, conn} ->
        conn

      {:error, :invalid_idempotency_key} ->
        InferenceControllerSupport.send_idempotency_error(conn, :invalid_idempotency_key)

      {:error, :invalid_request_shape} ->
        send_error(
          conn,
          :internal_server_error,
          "Internal error: invalid idempotency request shape",
          "api_error",
          code: "internal_error"
        )

      {:error, reason} ->
        InferenceControllerSupport.send_prepare_error(conn, reason)
    end
  end

  defp execute_request(conn, canonical, model, idempotency) do
    created = System.system_time(:second)

    case ResponsesOrchestrator.execute(canonical, model,
           response_created_at: created,
           idempotency: idempotency
         ) do
      {:ok, canonical, events} ->
        case Enum.find(events, &InferenceEvent.terminal?/1) do
          %{event: %InferenceEvent.Failed{}} = terminal ->
            terminal
            |> ChatError.from_failed_event()
            |> ChatError.api_mapping()
            |> send_response_error(conn)

          _other ->
            json(conn, ResponsesSerializer.response_payload(canonical, events, created))
        end

      {:replay, request} ->
        json(conn, request.response_payload)

      {:error, {:idempotency_conflict, reason}} ->
        InferenceControllerSupport.send_idempotency_error(conn, reason)

      {:error, reason} ->
        InferenceControllerSupport.send_execute_error(conn, reason)
    end
  end

  defp send_response_error(mapping, conn) do
    send_error(conn, mapping.status, mapping.message, mapping.type,
      param: mapping.param,
      code: mapping.code
    )
  end
end
