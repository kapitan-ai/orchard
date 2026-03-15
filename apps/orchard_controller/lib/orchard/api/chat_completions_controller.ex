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
  alias Orchard.Inference.{ChatError, ChatOrchestrator}
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

  defp send_prepare_error(conn, reason) do
    reason
    |> ChatError.from_prepare_reason()
    |> ChatError.api_mapping()
    |> send_chat_error(conn)
  end

  # -- Non-streaming response ------------------------------------------------

  defp handle_non_streaming(conn, canonical, model) do
    case ChatOrchestrator.execute(canonical, model) do
      {:ok, canonical, events} ->
        case Enum.find(events, &InferenceEvent.terminal?/1) do
          %{event: %InferenceEvent.Failed{}} = terminal ->
            terminal
            |> ChatError.from_failed_event()
            |> ChatError.api_mapping()
            |> send_chat_error(conn)

          _other ->
            send_completion_response(conn, canonical, events)
        end

      {:error, reason} ->
        reason
        |> ChatError.from_execute_error()
        |> ChatError.api_mapping()
        |> send_chat_error(conn)
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
      dispatch_stream_event(state_key, event, canonical.public_id, model_display, created)
    end

    result = ChatOrchestrator.execute(canonical, model, event_handler: handler)
    state = Process.get(state_key)
    Process.delete(state_key)

    finalize_stream(state, result, canonical, model_display, created)
  end

  # Checks whether the SSE connection is still alive, delegates to
  # handle_stream_event, and returns :cancel when the client has gone.
  defp dispatch_stream_event(state_key, event, public_id, model_display, created) do
    state = Process.get(state_key)

    if state.closed or state.errored do
      :cancel
    else
      new_state = handle_stream_event(state, event, public_id, model_display, created)
      Process.put(state_key, new_state)
      if new_state.closed, do: :cancel, else: :ok
    end
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
    mapping =
      event
      |> ChatError.from_failed_event()
      |> ChatError.sse_mapping()

    case SSE.send_error(state.conn, mapping.message, mapping.type,
           code: mapping.code,
           param: mapping.param
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
    mapping =
      reason
      |> ChatError.from_execute_error()
      |> ChatError.sse_mapping()

    case SSE.send_error(state.conn, mapping.message, mapping.type,
           code: mapping.code,
           param: mapping.param
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

  defp send_chat_error(mapping, conn) do
    send_error(conn, mapping.status, mapping.message, mapping.type,
      param: mapping.param,
      code: mapping.code
    )
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
end
