defmodule Orchard.API.ChatCompletionsController do
  @moduledoc """
  OpenAI-compatible chat completions.

  `POST /v1/chat/completions` accepts chat requests per SPEC.md §7.2.4.
  Validation is delegated to the orchestrator; this controller owns HTTP-layer
  concerns: content-type, error envelope shaping, and response framing.

  Non-streaming: returns a single JSON response with the full completion.
  Streaming (SSE): emits `chat.completion.chunk` events per §7.2.4, with
  optional usage chunk when `stream_options.include_usage=true`.
  """

  use Phoenix.Controller, formats: [:json]

  import Orchard.API.ErrorHelpers, only: [send_error: 5]

  alias Orchard.API.SSE
  alias Orchard.Inference.ChatOrchestrator
  alias Orchard.InferenceEvent

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, params) do
    caller_context = extract_caller_context(conn)

    case ChatOrchestrator.prepare(params, caller_context) do
      {:ok, canonical, model} ->
        if canonical.stream? do
          handle_streaming(conn, canonical, model)
        else
          handle_non_streaming(conn, canonical, model)
        end

      {:error, reason} ->
        send_prepare_error(conn, reason)
    end
  end

  defp send_prepare_error(conn, {:validation, errors}),
    do: send_validation_error(conn, errors)

  defp send_prepare_error(conn, {:model_not_found, model_ref}) do
    send_error(conn, :not_found, "Model not found: #{model_ref}", "invalid_request_error",
      param: "model",
      code: "model_not_found"
    )
  end

  defp send_prepare_error(conn, {:context_overflow, detail}) do
    send_error(conn, :bad_request, detail, "invalid_request_error",
      code: "context_length_exceeded"
    )
  end

  defp send_prepare_error(conn, {:tokenization, {cat, message}})
       when is_binary(message) and cat in [:invalid_input, :unsupported_tokenizer] do
    send_error(conn, :bad_request, message, "invalid_request_error", [])
  end

  defp send_prepare_error(conn, {:tokenization, {_cat, message}}) when is_binary(message) do
    send_error(conn, :internal_server_error, "Tokenization failed: #{message}", "server_error",
      code: "internal_error"
    )
  end

  defp send_prepare_error(conn, {:tokenization, reason}) do
    send_error(
      conn,
      :internal_server_error,
      "Tokenization failed: #{inspect(reason)}",
      "server_error", code: "internal_error")
  end

  # -- Non-streaming response ------------------------------------------------

  defp handle_non_streaming(conn, canonical, model) do
    case ChatOrchestrator.execute(canonical, model) do
      {:ok, canonical, events} ->
        # Check if the terminal event indicates failure — if so, return an
        # error envelope instead of a completion object (P0 review fix).
        case terminal_outcome(events) do
          :completed ->
            send_completion_response(conn, canonical, events)

          {:failed, message} ->
            send_error(
              conn,
              :internal_server_error,
              "Inference failed: #{message}",
              "server_error",
              code: "internal_error"
            )

          :cancelled ->
            send_error(conn, :internal_server_error, "Request was cancelled", "server_error",
              code: "request_cancelled"
            )

          :timed_out ->
            send_error(conn, :gateway_timeout, "Request timed out", "server_error",
              code: "request_timeout"
            )

          :unknown ->
            send_completion_response(conn, canonical, events)
        end

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

  defp send_completion_response(conn, canonical, events) do
    deltas = collect_deltas(events)
    content = Enum.join(deltas, "")
    usage = extract_usage(events)

    response = %{
      id: canonical.public_id,
      object: "chat.completion",
      created: System.system_time(:second),
      model: format_model_display(canonical),
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

  # -- Streaming (SSE) response ----------------------------------------------

  defp handle_streaming(conn, canonical, model) do
    case SSE.start(conn) do
      {:ok, conn} ->
        stream_completion(conn, canonical, model)

      {:error, :closed} ->
        conn
    end
  end

  defp stream_completion(conn, canonical, model) do
    model_display = format_model_display(canonical)
    created = System.system_time(:second)

    # Track mutable state across synchronous event_handler callbacks.
    # All calls happen in this process, so Process dictionary is safe.
    state_key = make_ref()

    Process.put(state_key, %{
      conn: conn,
      closed: false,
      errored: false,
      role_sent: false,
      usage: nil
    })

    handler = fn _request_id, event ->
      state = Process.get(state_key)

      unless state.closed or state.errored do
        new_state =
          handle_stream_event(state, event, canonical.public_id, model_display, created)

        Process.put(state_key, new_state)
      end
    end

    result = ChatOrchestrator.execute(canonical, model, event_handler: handler)
    state = Process.get(state_key)
    Process.delete(state_key)

    finalize_stream(state, result, canonical, model_display, created)
  end

  defp handle_stream_event(state, event, public_id, model_display, created) do
    case InferenceEvent.kind(event) do
      :output_text_delta ->
        state
        |> maybe_emit_role_chunk(public_id, model_display, created)
        |> emit_content_chunk(event.event.delta, public_id, model_display, created)

      :completed ->
        state
        |> maybe_emit_role_chunk(public_id, model_display, created)
        |> emit_finish_chunk(event, public_id, model_display, created)
        |> store_usage(event)

      :failed ->
        emit_stream_error(state, event)

      :usage ->
        store_usage_from_update(state, event)

      _other ->
        # Skip :accepted, :progress, :tool_call_delta for M1
        state
    end
  end

  defp maybe_emit_role_chunk(%{role_sent: true} = state, _id, _model, _created), do: state

  defp maybe_emit_role_chunk(state, public_id, model_display, created) do
    chunk =
      build_chunk(public_id, model_display, created, [
        %{index: 0, delta: %{role: "assistant", content: ""}, finish_reason: nil}
      ])

    send_sse_chunk(state, chunk)
    |> Map.put(:role_sent, true)
  end

  defp emit_content_chunk(state, delta, public_id, model_display, created) do
    chunk =
      build_chunk(public_id, model_display, created, [
        %{index: 0, delta: %{content: delta}, finish_reason: nil}
      ])

    send_sse_chunk(state, chunk)
  end

  defp emit_finish_chunk(state, event, public_id, model_display, created) do
    finish_reason = map_finish_reason(event)

    chunk =
      build_chunk(public_id, model_display, created, [
        %{index: 0, delta: %{}, finish_reason: finish_reason}
      ])

    send_sse_chunk(state, chunk)
  end

  defp emit_stream_error(state, event) do
    case SSE.send_error(
           state.conn,
           event.event.message,
           "server_error",
           code: event.event.code
         ) do
      {:ok, conn} -> %{state | conn: conn, errored: true}
      {:error, :closed} -> %{state | closed: true, errored: true}
    end
  end

  defp store_usage(state, event) do
    case event.event do
      %InferenceEvent.Completed{usage: nil} -> state
      %InferenceEvent.Completed{usage: usage} -> %{state | usage: usage}
    end
  end

  defp store_usage_from_update(state, event) do
    %{state | usage: event.event.usage}
  end

  defp send_sse_chunk(state, chunk_data) do
    case SSE.send_chunk(state.conn, chunk_data) do
      {:ok, conn} -> %{state | conn: conn}
      {:error, :closed} -> %{state | closed: true}
    end
  end

  defp build_chunk(public_id, model_display, created, choices) do
    %{
      id: public_id,
      object: "chat.completion.chunk",
      created: created,
      model: model_display,
      choices: choices
    }
  end

  defp finalize_stream(state, _result, _canonical, _model_display, _created)
       when state.closed do
    state.conn
  end

  defp finalize_stream(state, _result, _canonical, _model_display, _created)
       when state.errored do
    # Error already emitted via SSE — do NOT send [DONE] per §7.2.4
    state.conn
  end

  defp finalize_stream(state, {:error, reason}, _canonical, _model_display, _created) do
    # Post-start error: dispatch/persistence failed after SSE started
    case SSE.send_error(
           state.conn,
           "Internal error: #{inspect(reason)}",
           "server_error",
           code: "internal_error"
         ) do
      {:ok, conn} -> conn
      {:error, :closed} -> state.conn
    end
  end

  defp finalize_stream(state, {:ok, _canonical, _events}, canonical, model_display, created) do
    conn =
      if canonical.stream_include_usage do
        emit_usage_chunk(state, canonical.public_id, model_display, created)
      else
        state.conn
      end

    case SSE.send_done(conn) do
      {:ok, conn} -> conn
      {:error, :closed} -> state.conn
    end
  end

  defp emit_usage_chunk(state, public_id, model_display, created) do
    usage = format_usage(state.usage)

    chunk =
      build_chunk(public_id, model_display, created, [])
      |> Map.put(:usage, usage)

    case SSE.send_chunk(state.conn, chunk) do
      {:ok, conn} -> conn
      {:error, :closed} -> state.conn
    end
  end

  # -- Shared helpers --------------------------------------------------------

  defp extract_caller_context(conn) do
    [
      tenant_id: conn.assigns[:tenant_id],
      principal_id: conn.assigns[:principal_id],
      api_key_id: conn.assigns[:api_key_id]
    ]
  end

  defp format_model_display(canonical) do
    "#{canonical.model_ref.model_id}@#{canonical.model_ref.version}"
  end

  # Determine the terminal outcome from event list.
  # Returns :completed, {:failed, message}, :cancelled, :timed_out, or :unknown.
  defp terminal_outcome(events) do
    terminal = Enum.find(events, &InferenceEvent.terminal?/1)

    case terminal do
      nil ->
        :unknown

      %{event: %InferenceEvent.Completed{}} ->
        :completed

      %{event: %InferenceEvent.Failed{code: code, message: message}} ->
        cond do
          code in ["cancelled", "request_cancelled"] -> :cancelled
          code in ["timed_out", "request_timeout", "deadline_exceeded"] -> :timed_out
          true -> {:failed, message}
        end
    end
  end

  defp collect_deltas(events) do
    events
    |> Enum.filter(&(InferenceEvent.kind(&1) == :output_text_delta))
    |> Enum.map(fn event -> event.event.delta end)
  end

  defp extract_usage(events) do
    format_usage(find_usage(events))
  end

  defp find_usage(events) do
    usage_event = Enum.find(events, &(InferenceEvent.kind(&1) == :usage))
    completed_event = Enum.find(events, &(InferenceEvent.kind(&1) == :completed))

    cond do
      usage_event != nil -> usage_event.event.usage
      completed_event != nil && completed_event.event.usage != nil -> completed_event.event.usage
      true -> nil
    end
  end

  defp format_usage(nil) do
    %{prompt_tokens: 0, completion_tokens: 0, total_tokens: 0}
  end

  defp format_usage(usage) do
    %{
      prompt_tokens: usage.input_tokens,
      completion_tokens: usage.output_tokens,
      total_tokens: usage.total_tokens
    }
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
end
