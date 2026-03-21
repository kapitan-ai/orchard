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
  alias Orchard.Inference.{ChatError, ChatOrchestrator, ChatResponseSerializer}
  alias Orchard.InferenceEvent
  alias Orchard.Requests.Idempotency

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, params) do
    caller_context = extract_caller_context(conn)
    tenant_id = Keyword.fetch!(caller_context, :tenant_id)

    case build_idempotency_context(conn, tenant_id, params) do
      {:ok, idempotency} ->
        case resolve_idempotency(conn, idempotency) do
          {:proceed, conn} ->
            execute_request(conn, params, caller_context, idempotency)

          {:halt, conn} ->
            conn
        end

      {:error, :invalid_idempotency_key} ->
        send_idempotency_error(conn, :invalid_idempotency_key)

      {:error, :invalid_request_shape} ->
        send_error(
          conn,
          :internal_server_error,
          "Internal error: invalid idempotency request shape",
          "api_error",
          code: "internal_error"
        )
    end
  end

  defp execute_request(conn, params, caller_context, idempotency) do
    case ChatOrchestrator.prepare(params, caller_context) do
      {:ok, canonical, model} ->
        if canonical.stream? do
          handle_streaming(conn, canonical, model, idempotency)
        else
          handle_non_streaming(conn, canonical, model, idempotency)
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

  defp handle_non_streaming(conn, canonical, model, idempotency) do
    created = System.system_time(:second)

    case ChatOrchestrator.execute(canonical, model,
           response_created_at: created,
           idempotency: idempotency
         ) do
      {:ok, canonical, events} ->
        case Enum.find(events, &InferenceEvent.terminal?/1) do
          %{event: %InferenceEvent.Failed{}} = terminal ->
            terminal
            |> ChatError.from_failed_event()
            |> ChatError.api_mapping()
            |> send_chat_error(conn)

          _other ->
            send_completion_response(conn, canonical, events, created)
        end

      {:replay, request} ->
        json(conn, request.response_payload)

      {:error, {:idempotency_conflict, reason}} ->
        send_idempotency_error(conn, reason)

      {:error, reason} ->
        reason
        |> ChatError.from_execute_error()
        |> ChatError.api_mapping()
        |> send_chat_error(conn)
    end
  end

  defp send_completion_response(conn, canonical, events, created) do
    json(conn, ChatResponseSerializer.completion_payload(canonical, events, created))
  end

  # -- Streaming (SSE) response ----------------------------------------------

  defp handle_streaming(conn, canonical, model, idempotency) do
    case SSE.start(conn) do
      {:ok, conn} ->
        stream_completion(conn, canonical, model, idempotency)

      {:error, :closed} ->
        conn
    end
  end

  defp stream_completion(conn, canonical, model, idempotency) do
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

    result =
      ChatOrchestrator.execute(canonical, model,
        event_handler: handler,
        idempotency: idempotency
      )

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
    finish_reason = ChatResponseSerializer.finish_reason_from_event(event)

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
    mapping = sse_error_mapping(reason)

    case SSE.send_error(state.conn, mapping.message, mapping.type,
           code: mapping.code,
           param: mapping.param
         ) do
      {:ok, conn} -> conn
      {:error, :closed} -> state.conn
    end
  end

  defp finalize_stream(state, {:replay, _request}, _canonical, _model_display, _created) do
    mapping = sse_error_mapping({:idempotency_conflict, :idempotency_not_replayable})

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
    usage = ChatResponseSerializer.usage_map(state.usage)

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

  defp build_idempotency_context(conn, tenant_id, params) do
    case Idempotency.extract_key(conn) do
      {:ok, key} ->
        maybe_build_idempotency_context(tenant_id, key, params)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_build_idempotency_context(_tenant_id, nil, _params), do: {:ok, nil}

  defp maybe_build_idempotency_context(tenant_id, key, params) do
    Idempotency.build_context(tenant_id, key, params)
  end

  defp resolve_idempotency(conn, nil), do: {:proceed, conn}

  defp resolve_idempotency(conn, idempotency) do
    case Idempotency.resolve(idempotency) do
      :proceed ->
        {:proceed, conn}

      {:replay, request} ->
        {:halt, json(conn, request.response_payload)}

      {:conflict, reason, _request} ->
        {:halt, send_idempotency_error(conn, reason)}
    end
  end

  defp send_idempotency_error(conn, reason) do
    mapping = Idempotency.conflict_mapping(reason)
    send_chat_error(mapping, conn)
  end

  defp sse_error_mapping({:idempotency_conflict, reason}) do
    reason
    |> Idempotency.conflict_mapping()
    |> Map.delete(:status)
  end

  defp sse_error_mapping(reason) do
    reason
    |> ChatError.from_execute_error()
    |> ChatError.sse_mapping()
  end

  defp send_chat_error(mapping, conn) do
    send_error(conn, mapping.status, mapping.message, mapping.type,
      param: mapping.param,
      code: mapping.code
    )
  end
end
