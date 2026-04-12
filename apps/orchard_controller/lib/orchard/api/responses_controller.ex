defmodule Orchard.API.ResponsesController do
  @moduledoc """
  OpenAI-compatible `/v1/responses` endpoint with sync and typed SSE streaming.

  Non-streaming: returns a single JSON response object.
  Streaming (SSE): emits typed semantic events per the Responses API contract:
  `response.created`, zero or more `response.output_text.delta`, an optional
  `response.output_text.done` when text deltas were emitted, and a terminal
  `response.completed` or `response.failed`.
  """

  use Phoenix.Controller, formats: [:json]

  import Orchard.API.ErrorHelpers, only: [send_error: 5]

  alias Orchard.API.{InferenceControllerSupport, SSE}

  alias Orchard.Inference.{
    ChatError,
    ResponsesOrchestrator,
    ResponsesSerializer,
    ResponsesTerminalStatus,
    ToolCallAccumulator
  }

  alias Orchard.InferenceEvent

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, params) do
    caller_context = InferenceControllerSupport.extract_caller_context(conn)
    tenant_id = Keyword.fetch!(caller_context, :tenant_id)

    with {:ok, idempotency} <-
           InferenceControllerSupport.build_idempotency_context(conn, tenant_id, params),
         {:proceed, conn} <- InferenceControllerSupport.resolve_idempotency(conn, idempotency),
         {:ok, canonical, model} <- orchestrator_impl().prepare(params, caller_context) do
      if canonical.stream? do
        handle_streaming(conn, canonical, model, idempotency)
      else
        execute_sync_request(conn, canonical, model, idempotency)
      end
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

  # -- Non-streaming (sync) response -----------------------------------------

  defp execute_sync_request(conn, canonical, model, idempotency) do
    created = System.system_time(:second)

    case orchestrator_impl().execute(canonical, model,
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

  # -- Streaming (SSE) response ----------------------------------------------

  defp handle_streaming(conn, canonical, model, idempotency) do
    case SSE.start(conn) do
      {:ok, conn} ->
        stream_responses(conn, canonical, model, idempotency)

      {:error, :closed} ->
        conn
    end
  end

  defp stream_responses(conn, canonical, model, idempotency) do
    created = System.system_time(:second)

    {conn, closed} =
      emit_typed_event(
        conn,
        "response.created",
        ResponsesSerializer.created_event(canonical, created)
      )

    if closed do
      conn
    else
      do_stream_responses(conn, canonical, model, idempotency, created)
    end
  end

  defp do_stream_responses(conn, canonical, model, idempotency, created) do
    state_key = make_ref()

    Process.put(state_key, %{
      conn: conn,
      closed: false,
      terminal_sent: false,
      output_done_sent: false,
      output_delta_sent: false,
      output_chunks: [],
      usage: nil,
      tool_call_accumulator: ToolCallAccumulator.new()
    })

    handler = fn _request_id, event ->
      dispatch_stream_event(state_key, event, canonical, created)
    end

    result =
      orchestrator_impl().execute(canonical, model,
        event_handler: handler,
        idempotency: idempotency
      )

    state = Process.get(state_key)
    Process.delete(state_key)

    finalize_stream(state, result, canonical, created)
  end

  defp dispatch_stream_event(state_key, event, canonical, created) do
    state = Process.get(state_key)

    if state.closed or state.terminal_sent do
      :cancel
    else
      new_state = handle_stream_event(state, event, canonical, created)
      Process.put(state_key, new_state)
      if new_state.closed, do: :cancel, else: :ok
    end
  end

  defp handle_stream_event(state, event, canonical, created) do
    case InferenceEvent.kind(event) do
      :output_text_delta ->
        delta = event.event.delta

        state
        |> Map.update!(:output_chunks, &[delta | &1])
        |> Map.put(:output_delta_sent, true)
        |> emit_event(
          "response.output_text.delta",
          ResponsesSerializer.output_text_delta_event(canonical.public_id, delta)
        )

      :usage ->
        %{state | usage: event.event.usage}

      :tool_call_delta ->
        apply_tool_call_delta(state, event, canonical, created)

      :completed ->
        output_text = collected_text(state)
        usage = latest_usage(state, event)
        function_call_items = tool_call_items(state, :completed)

        state
        |> Map.put(:usage, usage)
        |> maybe_emit_output_done(canonical, output_text)
        |> emit_event(
          "response.completed",
          ResponsesSerializer.completed_event(
            canonical,
            output_text,
            usage,
            created,
            function_call_items
          )
        )
        |> Map.put(:terminal_sent, true)

      :failed ->
        output_text = collected_text(state)
        usage = state.usage
        error_map = build_error_map(event)
        function_call_items = tool_call_items(state, :incomplete)

        status =
          ResponsesTerminalStatus.inference_failed_status(
            event,
            partial_output_surfaced?: function_call_items != []
          )

        state
        |> maybe_emit_output_done(canonical, output_text)
        |> emit_event(
          "response.failed",
          ResponsesSerializer.failed_event(
            canonical,
            output_text,
            usage,
            error_map,
            created,
            function_call_items,
            status
          )
        )
        |> Map.put(:terminal_sent, true)

      _other ->
        state
    end
  end

  defp maybe_emit_output_done(%{output_done_sent: true} = state, _canonical, _text), do: state
  defp maybe_emit_output_done(%{output_delta_sent: false} = state, _canonical, _text), do: state

  defp maybe_emit_output_done(state, canonical, output_text) do
    state
    |> emit_event(
      "response.output_text.done",
      ResponsesSerializer.output_text_done_event(canonical.public_id, output_text)
    )
    |> Map.put(:output_done_sent, true)
  end

  defp collected_text(state) do
    state.output_chunks |> Enum.reverse() |> Enum.join("")
  end

  defp latest_usage(state, event) do
    case event.event do
      %InferenceEvent.Completed{usage: nil} -> state.usage
      %InferenceEvent.Completed{usage: usage} -> usage
    end
  end

  defp build_error_map(event) do
    mapping =
      event
      |> ChatError.from_failed_event()
      |> ChatError.sse_mapping()

    %{
      message: mapping.message,
      type: mapping.type,
      code: mapping.code,
      param: mapping.param
    }
  end

  defp emit_event(state, event_type, payload) do
    if state.closed do
      state
    else
      case SSE.send_event(state.conn, event_type, payload) do
        {:ok, conn} -> %{state | conn: conn}
        {:error, :closed} -> %{state | closed: true}
      end
    end
  end

  defp emit_typed_event(conn, event_type, payload) do
    case SSE.send_event(conn, event_type, payload) do
      {:ok, conn} -> {conn, false}
      {:error, :closed} -> {conn, true}
    end
  end

  defp apply_tool_call_delta(state, event, canonical, created) do
    case ToolCallAccumulator.apply_event(state.tool_call_accumulator, event) do
      {:ok, accumulator} ->
        %{state | tool_call_accumulator: accumulator}

      {:error, reason} ->
        output_text = collected_text(state)

        error_map = %{
          message: "Malformed tool call delta: #{inspect(reason)}",
          type: "server_error",
          code: "internal_error",
          param: nil
        }

        function_call_items = tool_call_items(state, :incomplete)

        state
        |> maybe_emit_output_done(canonical, output_text)
        |> emit_event(
          "response.failed",
          ResponsesSerializer.failed_event(
            canonical,
            output_text,
            state.usage,
            error_map,
            created,
            function_call_items,
            "failed"
          )
        )
        |> Map.put(:terminal_sent, true)
    end
  end

  # -- Stream finalization ----------------------------------------------------

  defp finalize_stream(state, _result, _canonical, _created) when state.closed do
    state.conn
  end

  defp finalize_stream(state, _result, _canonical, _created) when state.terminal_sent do
    state.conn
  end

  defp finalize_stream(state, {:error, reason}, canonical, created) do
    output_text = collected_text(state)
    mapping = InferenceControllerSupport.sse_error_mapping(reason)

    error_map = %{
      message: mapping.message,
      type: mapping.type,
      code: mapping.code,
      param: mapping.param
    }

    function_call_items = tool_call_items(state, :incomplete)

    status =
      ResponsesTerminalStatus.execute_error_status(
        reason,
        partial_output_surfaced?: function_call_items != []
      )

    state
    |> maybe_emit_output_done(canonical, output_text)
    |> emit_event(
      "response.failed",
      ResponsesSerializer.failed_event(
        canonical,
        output_text,
        state.usage,
        error_map,
        created,
        function_call_items,
        status
      )
    )
    |> then(& &1.conn)
  end

  defp finalize_stream(state, {:replay, _request}, canonical, created) do
    output_text = collected_text(state)

    mapping =
      InferenceControllerSupport.sse_error_mapping(
        {:idempotency_conflict, :idempotency_not_replayable}
      )

    error_map = %{
      message: mapping.message,
      type: mapping.type,
      code: mapping.code,
      param: mapping.param
    }

    function_call_items = tool_call_items(state, :incomplete)

    state
    |> maybe_emit_output_done(canonical, output_text)
    |> emit_event(
      "response.failed",
      ResponsesSerializer.failed_event(
        canonical,
        output_text,
        state.usage,
        error_map,
        created,
        function_call_items,
        "failed"
      )
    )
    |> then(& &1.conn)
  end

  defp finalize_stream(state, {:ok, _canonical, _events}, canonical, created) do
    output_text = collected_text(state)
    function_call_items = tool_call_items(state, :completed)

    state
    |> maybe_emit_output_done(canonical, output_text)
    |> emit_event(
      "response.completed",
      ResponsesSerializer.completed_event(
        canonical,
        output_text,
        state.usage,
        created,
        function_call_items
      )
    )
    |> then(& &1.conn)
  end

  # -- Shared helpers --------------------------------------------------------

  defp send_response_error(mapping, conn) do
    send_error(conn, mapping.status, mapping.message, mapping.type,
      param: mapping.param,
      code: mapping.code
    )
  end

  defp orchestrator_impl do
    Application.get_env(
      :orchard_controller,
      :api_responses_orchestrator_impl,
      ResponsesOrchestrator
    )
  end

  defp tool_call_items(state, status) do
    ToolCallAccumulator.responses_output_items(state.tool_call_accumulator, status)
  end
end
