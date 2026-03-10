defmodule Orchard.API.ChatCompletionsController do
  @moduledoc """
  OpenAI-compatible chat completions.

  `POST /v1/chat/completions` accepts chat requests per SPEC.md §7.2.4.
  Validation is delegated to the orchestrator; this controller owns HTTP-layer
  concerns: content-type, error envelope shaping, and response framing.

  Non-streaming: returns a single JSON response with the full completion.
  Streaming (SSE): will be wired in A5.
  """

  use Phoenix.Controller, formats: [:json]

  import Orchard.API.ErrorHelpers, only: [send_error: 5]

  alias Orchard.Inference.ChatOrchestrator
  alias Orchard.InferenceEvent

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, params) do
    case ChatOrchestrator.orchestrate(params) do
      {:ok, canonical, events} ->
        send_completion_response(conn, canonical, events)

      {:error, {:validation, errors}} ->
        send_validation_error(conn, errors)

      {:error, {:model_not_found, model_ref}} ->
        send_error(
          conn,
          :not_found,
          "Model not found: #{model_ref}",
          "invalid_request_error",
          param: "model",
          code: "model_not_found"
        )

      {:error, reason} ->
        send_error(
          conn,
          :internal_server_error,
          "Internal error: #{inspect(reason)}",
          "api_error",
          code: "internal_error"
        )
    end
  end

  # -- Non-streaming response ------------------------------------------------

  defp send_completion_response(conn, canonical, events) do
    deltas = collect_deltas(events)
    content = Enum.join(deltas, "")
    usage = extract_usage(events)

    response = %{
      id: canonical.public_id,
      object: "chat.completion",
      created: System.system_time(:second),
      model: "#{canonical.model_ref.model_id}@#{canonical.model_ref.version}",
      choices: [
        %{
          index: 0,
          message: %{role: "assistant", content: content},
          finish_reason: extract_finish_reason(events)
        }
      ],
      usage: usage
    }

    json(conn, response)
  end

  defp collect_deltas(events) do
    events
    |> Enum.filter(&(InferenceEvent.kind(&1) == :output_text_delta))
    |> Enum.map(fn event -> event.event.delta end)
  end

  defp extract_usage(events) do
    usage_event = Enum.find(events, &(InferenceEvent.kind(&1) == :usage))
    completed_event = Enum.find(events, &(InferenceEvent.kind(&1) == :completed))

    usage =
      cond do
        usage_event != nil -> usage_event.event.usage
        completed_event != nil && completed_event.event.usage != nil -> completed_event.event.usage
        true -> nil
      end

    case usage do
      nil ->
        %{prompt_tokens: 0, completion_tokens: 0, total_tokens: 0}

      u ->
        %{
          prompt_tokens: u.input_tokens,
          completion_tokens: u.output_tokens,
          total_tokens: u.total_tokens
        }
    end
  end

  defp extract_finish_reason(events) do
    terminal = Enum.find(events, &InferenceEvent.terminal?/1)

    case terminal do
      nil -> "stop"
      event -> map_finish_reason(event)
    end
  end

  defp map_finish_reason(event) do
    case InferenceEvent.kind(event) do
      :completed -> map_proto_finish_reason(event.event.finish_reason)
      :failed -> "error"
      _ -> "stop"
    end
  end

  defp map_proto_finish_reason(:finish_reason_stop), do: "stop"
  defp map_proto_finish_reason(:finish_reason_length), do: "length"
  defp map_proto_finish_reason(_), do: "stop"

  # -- Error response helpers ------------------------------------------------

  defp send_validation_error(conn, {:missing_required_field, field}) do
    send_error(
      conn,
      :bad_request,
      "Missing required field: #{field}",
      "invalid_request_error",
      param: field,
      code: "missing_required_field"
    )
  end

  defp send_validation_error(conn, {:unsupported_parameter, field}) do
    send_error(
      conn,
      :bad_request,
      "Unsupported parameter: #{field}",
      "invalid_request_error",
      param: field,
      code: "unsupported_parameter"
    )
  end

  defp send_validation_error(conn, {:invalid_value, field, reason}) do
    send_error(
      conn,
      :bad_request,
      "Invalid value for #{field}: #{reason}",
      "invalid_request_error",
      param: field,
      code: "invalid_value"
    )
  end

  defp send_validation_error(conn, error) do
    send_error(
      conn,
      :bad_request,
      "Validation error: #{inspect(error)}",
      "invalid_request_error",
      code: "invalid_value"
    )
  end
end
