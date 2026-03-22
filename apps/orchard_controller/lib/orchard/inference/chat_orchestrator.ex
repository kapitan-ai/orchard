defmodule Orchard.Inference.ChatOrchestrator do
  @moduledoc """
  Orchestrates the full lifecycle of a chat completions request.

  Ties together validation, normalization, persistence, FSM state
  transitions, dispatch to the runtime, and terminal state recording.

  Used by both `ChatCompletionsController` (non-stream and stream)
  and any future programmatic callers.

  ## Flow

      validate → normalize → resolve model → tokenize → enforce context window
      → persist request row → start FSM → transition validated → schedule
      → transition scheduled → transition dispatching → dispatch → collect events
      → transition terminal → persist usage

  ## Error Handling

  Returns `{:error, {:validation, errors}}` for request validation failures,
  `{:error, {:model_not_found, model_ref}}` when the requested model doesn't
  exist or isn't active, and `{:error, reason}` for dispatch/persistence
  failures.
  """

  alias Orchard.CanonicalRequest

  alias Orchard.Inference.{
    ChatRequestNormalizer,
    ChatRequestValidator,
    ChatResponseSerializer,
    RequestOrchestrator,
    RequestPreparation
  }

  alias Orchard.InferenceEvent

  @type orchestrate_result ::
          {:ok, CanonicalRequest.t(), [InferenceEvent.t()]}
          | {:replay, struct()}
          | {:error, term()}

  @doc """
  Prepares a chat completion request: validates, normalizes, resolves model.

  Returns `{:ok, canonical_request, model}` if all pre-dispatch checks pass.
  This step does not persist anything or start dispatch — use `execute/3` for that.

  `caller_context` is a keyword list from the request context plug:
    * `:tenant_id` — resolved tenant (default: `"default"` in M1)
    * `:principal_id` — resolved principal (nil in M1)
    * `:api_key_id` — resolved API key (nil in M1)

  Returns `{:error, {:validation, errors}}` for request validation failures,
  `{:error, {:model_not_found, model_ref}}` when the requested model doesn't
  exist or isn't active, `{:error, {:tokenization, reason}}` for prompt
  rendering/tokenizer failures, and `{:error, {:context_overflow, detail}}`
  when input tokens + max output tokens exceed the model's context window.
  """
  @spec prepare(map(), keyword()) :: {:ok, CanonicalRequest.t(), map()} | {:error, term()}
  def prepare(params, caller_context \\ []) do
    RequestPreparation.prepare(params, caller_context,
      validator: ChatRequestValidator,
      normalizer: ChatRequestNormalizer
    )
  end

  @doc """
  Executes the shared request pipeline for a prepared chat request.

  ## Options

    * `:event_handler` — optional callback `fun(request_id, event)` called
      with each `InferenceEvent` as it arrives from dispatch
    * `:caller` — optional pid to monitor for dispatch cancellation semantics
      (defaults to the current process)
    * `:idempotency` — optional tenant-scoped idempotency context built from
      the public request header and raw body
  """
  @spec execute(CanonicalRequest.t(), map(), keyword()) :: orchestrate_result()
  def execute(canonical, model, opts \\ []) do
    response_created_at = Keyword.get(opts, :response_created_at, System.system_time(:second))

    RequestOrchestrator.execute(
      canonical,
      model,
      Keyword.put_new(opts, :success_persistence, fn canonical_request, events ->
        ChatResponseSerializer.success_persistence_attrs(
          canonical_request,
          events,
          response_created_at
        )
      end)
    )
  end

  @doc """
  Orchestrates a complete chat completion request from raw HTTP params.

  Convenience that calls `prepare/1` then `execute/3`. Suitable for
  non-streaming callers that don't need to start SSE between the two phases.

  Returns `{:ok, canonical_request, events}` on success, where `events`
  includes terminal (completed/failed/cancelled) events with usage data.

  ## Options

    * `:event_handler` — optional callback `fun(request_id, event)` for
      streaming-style event delivery
    * `:caller` — optional pid forwarded to the dispatcher for cancellation
      monitoring
  """
  @spec orchestrate(map(), keyword()) :: orchestrate_result()
  def orchestrate(params, opts \\ []) do
    caller_context = Keyword.get(opts, :caller_context, [])

    with {:ok, canonical, model} <- prepare(params, caller_context) do
      execute(canonical, model, opts)
    end
  end
end
