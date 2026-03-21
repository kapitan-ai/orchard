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
    RequestOrchestrator
  }

  alias Orchard.InferenceEvent
  alias Orchard.Models
  alias Orchard.Models.ManifestParser
  alias Orchard.Tokenizer.Client, as: TokenizerClient

  # Default max output tokens when the client omits max_tokens / max_completion_tokens.
  # Applied at orchestration time for both context-window enforcement and runtime dispatch.
  # Canonical sampling keeps nil to preserve the distinction between "omitted" and "explicit".
  @default_max_output_tokens 4096

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
    with {:ok, params} <- validate(params),
         {:ok, canonical} <- normalize(params, caller_context),
         {:ok, model} <- resolve_model(canonical),
         {:ok, canonical} <- tokenize(canonical, model),
         :ok <- enforce_context_window(canonical, model) do
      {:ok, canonical, model}
    end
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

  # -- Steps -----------------------------------------------------------------

  defp validate(params) do
    case ChatRequestValidator.validate(params) do
      {:ok, validated} -> {:ok, validated}
      {:error, type, field} -> {:error, {:validation, {type, field}}}
      {:error, type, field, reason} -> {:error, {:validation, {type, field, reason}}}
    end
  end

  defp normalize(params, caller_context) do
    ChatRequestNormalizer.normalize(params, caller_context)
  end

  defp resolve_model(%CanonicalRequest{model_ref: model_ref}) do
    case Models.get_model_by_identity(model_ref.model_id, model_ref.version) do
      nil ->
        {:error, {:model_not_found, "#{model_ref.model_id}@#{model_ref.version}"}}

      %{state: :active} = model ->
        {:ok, model}

      %{state: state} ->
        {:error,
         {:model_not_found, "#{model_ref.model_id}@#{model_ref.version} is #{state}, not active"}}
    end
  end

  defp tokenize(canonical, model) do
    tokenizer_opts = build_tokenizer_opts(model)

    case TokenizerClient.tokenize(canonical, tokenizer_opts) do
      {:ok, %{rendered_prompt: prompt, input_token_count: count}} ->
        {:ok, CanonicalRequest.with_tokenization(canonical, prompt, count)}

      {:error, reason} ->
        {:error, {:tokenization, reason}}
    end
  end

  # In fake mode, the tokenizer doesn't need model assets.
  # In port mode, resolve the bundle root from the model's artifact_uri
  # and parse the manifest for tokenizer/chat-template asset paths.
  defp build_tokenizer_opts(model) do
    case TokenizerClient.mode() do
      :fake ->
        []

      :port ->
        bundle_root = uri_to_local_path(model.artifact_uri)

        case ManifestParser.parse_from_bundle(bundle_root) do
          {:ok, manifest} -> [manifest: manifest, bundle_root: bundle_root]
          {:error, _reason} -> []
        end

      _other ->
        []
    end
  end

  defp uri_to_local_path("file://" <> path), do: path
  defp uri_to_local_path(path), do: path

  defp enforce_context_window(canonical, model) do
    max_output = effective_max_output_tokens(canonical.sampling)
    total = canonical.input_token_count + max_output

    if total > model.max_context_tokens do
      {:error,
       {:context_overflow,
        "request requires #{total} tokens (#{canonical.input_token_count} input + #{max_output} output) but model supports at most #{model.max_context_tokens}"}}
    else
      :ok
    end
  end

  defp effective_max_output_tokens(%CanonicalRequest.Sampling{max_output_tokens: n})
       when is_integer(n) and n > 0,
       do: n

  defp effective_max_output_tokens(%CanonicalRequest.Sampling{}),
    do: @default_max_output_tokens
end
