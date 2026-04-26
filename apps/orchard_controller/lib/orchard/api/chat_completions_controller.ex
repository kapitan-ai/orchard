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

  alias Orchard.API.{InferenceControllerSupport, SSE}
  alias Orchard.Inference.{ChatError, ChatOrchestrator, ChatResponseSerializer}
  alias Orchard.InferenceEvent
  alias Orchard.SentryContext

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, params) do
    caller_context = InferenceControllerSupport.extract_caller_context(conn)
    tenant_id = Keyword.fetch!(caller_context, :tenant_id)

    case InferenceControllerSupport.build_idempotency_context(conn, tenant_id, params) do
      {:ok, idempotency} ->
        case resolve_idempotency(conn, idempotency) do
          {:proceed, conn} ->
            execute_request(conn, params, caller_context, idempotency)

          {:halt, conn} ->
            conn
        end

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
    end
  end

  defp execute_request(conn, params, caller_context, idempotency) do
    case orchestrator_impl().prepare(params, caller_context) do
      {:ok, canonical, model} ->
        if canonical.stream? do
          handle_streaming(conn, canonical, model, idempotency)
        else
          handle_non_streaming(conn, canonical, model, idempotency)
        end

      {:error, reason} ->
        InferenceControllerSupport.send_prepare_error(conn, reason)
    end
  end

  # -- Non-streaming response ------------------------------------------------

  defp handle_non_streaming(conn, canonical, model, idempotency) do
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
            |> send_chat_error(conn)

          _other ->
            send_completion_response(conn, canonical, events, created)
        end

      {:replay, request} ->
        json(conn, request.response_payload)

      {:error, {:idempotency_conflict, reason}} ->
        InferenceControllerSupport.send_idempotency_error(conn, reason)

      {:error, reason} ->
        InferenceControllerSupport.send_execute_error(conn, reason)
    end
  end

  defp send_completion_response(conn, canonical, events, created) do
    json(conn, ChatResponseSerializer.completion_payload(canonical, events, created))
  end

  # -- Streaming (SSE) response ----------------------------------------------

  defp handle_streaming(conn, canonical, model, idempotency) do
    case do_handle_streaming(conn, canonical, model, idempotency) do
      result ->
        SentryContext.clear_all()
        result
    end
  end

  defp do_handle_streaming(conn, canonical, model, idempotency) do
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
      orchestrator_impl().execute(canonical, model,
        event_handler: handler,
        idempotency: idempotency
      )

    state = Process.get(state_key)
    Process.delete(state_key)

    finalize_stream(state, result, canonical, model_display, created)
  end

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

      :tool_call_delta ->
        state
        |> maybe_emit_role_chunk(public_id, model_display, created)
        |> emit_tool_call_chunk(event, public_id, model_display, created)

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

  defp emit_tool_call_chunk(state, event, public_id, model_display, created) do
    case tool_call_choice(event) do
      {:ok, choice} ->
        chunk = build_chunk(public_id, model_display, created, [choice])
        send_sse_chunk(state, chunk)

      {:error, _reason} ->
        emit_internal_stream_error(state, "Malformed tool call delta")
    end
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

  defp emit_internal_stream_error(state, message) do
    case SSE.send_error(state.conn, message, "server_error", code: "internal_error") do
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

  defp format_model_display(canonical) do
    "#{canonical.model_ref.model_id}@#{canonical.model_ref.version}"
  end

  defp resolve_idempotency(conn, idempotency) do
    InferenceControllerSupport.resolve_idempotency(conn, idempotency)
  end

  defp orchestrator_impl do
    Application.get_env(:orchard_controller, :api_chat_orchestrator_impl, ChatOrchestrator)
  end

  defp sse_error_mapping({:idempotency_conflict, reason}) do
    InferenceControllerSupport.sse_error_mapping({:idempotency_conflict, reason})
  end

  defp sse_error_mapping(reason) do
    InferenceControllerSupport.sse_error_mapping(reason)
  end

  defp send_chat_error(mapping, conn) do
    send_error(conn, mapping.status, mapping.message, mapping.type,
      param: mapping.param,
      code: mapping.code
    )
  end

  defp tool_call_choice(%InferenceEvent{event: %InferenceEvent.ToolCallDelta{} = delta_event}) do
    with {:ok, delta} <- Jason.decode(delta_event.delta_json),
         {:ok, tool_call} <- stream_tool_call_delta(delta_event.tool_call_id, delta) do
      {:ok, %{index: 0, delta: %{tool_calls: [tool_call]}, finish_reason: nil}}
    else
      {:error, _reason} = error -> error
    end
  end

  defp stream_tool_call_delta(tool_call_id, %{"index" => index} = delta)
       when is_integer(index) and index >= 0 do
    function_delta = Map.get(delta, "function")

    with {:ok, type} <- normalize_delta_type(Map.get(delta, "type"), function_delta),
         {:ok, function_fragment} <- normalize_function_fragment(function_delta),
         true <- type != nil or function_fragment != nil do
      tool_call =
        %{index: index, id: tool_call_id}
        |> maybe_put(:type, type)
        |> maybe_put(:function, function_fragment)

      {:ok, tool_call}
    else
      {:error, _reason} = error -> error
      false -> {:error, :empty_tool_call_delta}
    end
  end

  defp stream_tool_call_delta(_tool_call_id, delta),
    do: {:error, {:invalid_tool_call_delta, delta}}

  defp normalize_delta_type(nil, %{"name" => name}) when is_binary(name), do: {:ok, "function"}
  defp normalize_delta_type(nil, _function_delta), do: {:ok, nil}
  defp normalize_delta_type("function", _function_delta), do: {:ok, "function"}
  defp normalize_delta_type(type, _function_delta), do: {:error, {:invalid_type, type}}

  defp normalize_function_fragment(nil), do: {:ok, nil}

  defp normalize_function_fragment(function_delta) when is_map(function_delta) do
    with {:ok, name} <- normalize_function_name(Map.get(function_delta, "name")),
         {:ok, arguments} <- normalize_function_arguments(function_delta) do
      {:ok, build_function_fragment(name, arguments)}
    end
  end

  defp normalize_function_fragment(other), do: {:error, {:invalid_function, other}}

  defp normalize_function_name(nil), do: {:ok, nil}
  defp normalize_function_name(name) when is_binary(name), do: {:ok, name}
  defp normalize_function_name(name), do: {:error, {:invalid_name, name}}

  defp normalize_function_arguments(function_delta) do
    arguments =
      cond do
        is_binary(Map.get(function_delta, "arguments_delta")) ->
          Map.get(function_delta, "arguments_delta")

        is_binary(Map.get(function_delta, "arguments")) ->
          Map.get(function_delta, "arguments")

        true ->
          nil
      end

    if arguments == nil or is_binary(arguments) do
      {:ok, arguments}
    else
      {:error, {:invalid_arguments, arguments}}
    end
  end

  defp build_function_fragment(nil, nil), do: nil
  defp build_function_fragment(name, nil), do: %{name: name}
  defp build_function_fragment(nil, arguments), do: %{arguments: arguments}
  defp build_function_fragment(name, arguments), do: %{name: name, arguments: arguments}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
