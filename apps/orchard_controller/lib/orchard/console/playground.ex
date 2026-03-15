defmodule OrchardConsole.Playground do
  @moduledoc """
  Console-facing service seam for the chat playground.

  Wraps `ChatOrchestrator.prepare/2` + `execute/3` into a console-facing
  API with async streaming and operator-safe error normalization.

  The module is injectable via `:playground_impl` in the
  `:orchard_controller, :console` config for testing.

  ## Message Contract

  `start_stream/4` sends structured messages to the owner process:

      {:playground, run_ref, :started, %{request_id: public_id}}
      {:playground, run_ref, :event, %InferenceEvent{}}
      {:playground, run_ref, :finished, {:ok, summary}}
      {:playground, run_ref, :finished, {:error, error_map}}

  The `:started` message is sent after `prepare/2` succeeds and dispatch
  begins. Events are forwarded as they arrive from the dispatcher.
  `:finished` is always the last message, sent exactly once.
  """

  alias Orchard.Inference.{ChatError, ChatOrchestrator}
  alias Orchard.InferenceEvent
  alias Orchard.Models

  @type model_option :: %{model_id: String.t(), version: String.t()}

  @type stream_error :: %{
          phase: :prepare | :execute | :stream,
          type: String.t(),
          code: String.t() | nil,
          message: String.t(),
          param: String.t() | nil
        }

  # ===========================================================================
  # Public API
  # ===========================================================================

  @doc """
  Returns active models for the playground model picker.

  Models are projected to plain maps and sorted by `{model_id, version}`
  for deterministic display order.
  """
  @spec list_models() :: {:ok, [model_option()]} | {:error, map()}
  def list_models do
    models =
      models_impl().list_active_models()
      |> Enum.map(fn model ->
        %{
          model_id: safe_string(model.model_id),
          version: safe_string(model.version)
        }
      end)
      |> Enum.sort_by(&{&1.model_id, &1.version})

    {:ok, models}
  rescue
    _ ->
      {:error,
       %{
         status: :error,
         code: "models_unavailable",
         message: "Active model list unavailable."
       }}
  end

  @doc """
  Starts an async streaming chat run.

  Prepares and executes the chat request in an unlinked task. All results
  are delivered as messages to `owner` tagged with `run_ref`.

  The `owner` pid is passed as the `:caller` option to
  `ChatOrchestrator.execute/3` so the dispatcher cancels the inference
  if the LiveView process exits.

  Returns `{:ok, pid}` immediately.
  """
  @spec start_stream(pid(), term(), map(), keyword()) :: {:ok, pid()}
  def start_stream(owner, run_ref, params, caller_context \\ []) do
    orchestrator = orchestrator_impl()

    Task.start(fn ->
      run_stream(orchestrator, owner, run_ref, params, caller_context)
    end)
  end

  # ===========================================================================
  # Stream task body
  # ===========================================================================

  defp run_stream(orchestrator, owner, run_ref, params, caller_context) do
    case orchestrator.prepare(params, caller_context) do
      {:ok, canonical, model} ->
        send(owner, {:playground, run_ref, :started, %{request_id: canonical.public_id}})

        event_handler = fn _request_id, event ->
          bridge_event(owner, run_ref, event)
        end

        case orchestrator.execute(canonical, model,
               event_handler: event_handler,
               caller: owner
             ) do
          {:ok, canonical_result, events} ->
            send(
              owner,
              {:playground, run_ref, :finished,
               {:ok, %{canonical_request: canonical_result, events: events}}}
            )

          {:error, reason} ->
            error = normalize_error(:execute, reason)
            send(owner, {:playground, run_ref, :finished, {:error, error}})
        end

      {:error, reason} ->
        error = normalize_error(:prepare, reason)
        send(owner, {:playground, run_ref, :finished, {:error, error}})
    end
  rescue
    exception ->
      error = %{
        phase: :execute,
        type: "server_error",
        code: "internal_error",
        message: "Unexpected error: #{Exception.message(exception)}",
        param: nil
      }

      send(owner, {:playground, run_ref, :finished, {:error, error}})
  end

  # ===========================================================================
  # Event bridge
  # ===========================================================================

  defp bridge_event(owner, run_ref, %InferenceEvent{} = event) do
    if Process.alive?(owner) do
      send(owner, {:playground, run_ref, :event, event})
      :ok
    else
      :cancel
    end
  end

  # ===========================================================================
  # Error normalization
  # ===========================================================================

  defp normalize_error(:prepare, reason) do
    mapping = reason |> ChatError.from_prepare_reason() |> ChatError.api_mapping()

    %{
      phase: :prepare,
      type: mapping.type,
      code: mapping.code,
      message: mapping.message,
      param: mapping.param
    }
  end

  defp normalize_error(:execute, reason) do
    mapping = reason |> ChatError.from_execute_error() |> ChatError.api_mapping()

    %{
      phase: :execute,
      type: mapping.type,
      code: mapping.code,
      message: mapping.message,
      param: mapping.param
    }
  end

  # ===========================================================================
  # Config seam
  # ===========================================================================

  defp models_impl do
    console_config()[:playground_models_impl] || Models
  end

  defp orchestrator_impl do
    console_config()[:playground_orchestrator_impl] || ChatOrchestrator
  end

  defp console_config do
    Application.get_env(:orchard_controller, :console, [])
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp safe_string(value) when is_binary(value), do: value
  defp safe_string(_), do: ""
end
