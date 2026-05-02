defmodule Orchard.Inference.RequestPreparation do
  @moduledoc false

  alias Orchard.CanonicalRequest
  alias Orchard.Inference.{ToolExecutionSemantics, ToolingValidation, ToolRegistryResolver}
  alias Orchard.Models
  alias Orchard.Models.ManifestParser
  alias Orchard.Tokenizer.Client, as: TokenizerClient

  @default_max_output_tokens 4096
  @manifest_tokenization_error_message "model manifest could not be loaded for tokenization"

  @spec prepare(map(), keyword(), keyword()) ::
          {:ok, CanonicalRequest.t(), map()} | {:error, term()}
  def prepare(params, caller_context, opts) do
    validator = Keyword.fetch!(opts, :validator)
    normalizer = Keyword.fetch!(opts, :normalizer)

    with {:ok, params} <- validate(params, validator),
         {:ok, canonical} <- normalizer.normalize(params, caller_context),
         {:ok, canonical} <- resolve_requested_tools(canonical),
         {:ok, canonical} <- attach_execution_snapshot(canonical),
         {:ok, model} <- resolve_model(canonical),
         :ok <- enforce_tooling_support(canonical, model),
         {:ok, canonical} <- tokenize(canonical, model),
         :ok <- enforce_context_window(canonical, model) do
      {:ok, canonical, model}
    end
  end

  defp validate(params, validator), do: wrap_validation_result(validator.validate(params))

  defp resolve_requested_tools(%CanonicalRequest{tooling: tooling} = canonical) do
    case wrap_validation_result(ToolRegistryResolver.resolve(tooling)) do
      {:ok, resolved_tooling} -> {:ok, %{canonical | tooling: resolved_tooling}}
      {:error, _reason} = error -> error
    end
  end

  defp attach_execution_snapshot(
         %CanonicalRequest{tooling: %CanonicalRequest.Tooling{} = tooling} = canonical
       ) do
    case ToolExecutionSemantics.build(tooling) do
      {:ok, execution_snapshot} ->
        {:ok,
         %{
           canonical
           | tooling: %CanonicalRequest.Tooling{tooling | execution_snapshot: execution_snapshot}
         }}

      {:error, {:misaligned_tooling, _reason}} ->
        {:error, {:internal_error, "resolved tooling could not produce execution snapshot"}}
    end
  end

  defp wrap_validation_result({:ok, value}), do: {:ok, value}
  defp wrap_validation_result({:error, type, field}), do: {:error, {:validation, {type, field}}}

  defp wrap_validation_result({:error, type, field, reason}),
    do: {:error, {:validation, {type, field, reason}}}

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
    with {:ok, tokenizer_opts} <- build_tokenizer_opts(model),
         {:ok, tokenization} <- TokenizerClient.tokenize(canonical, tokenizer_opts) do
      {:ok, apply_tokenization(canonical, tokenization)}
    else
      {:error, {:tokenization, _reason}} = error ->
        error

      {:error, reason} ->
        {:error, {:tokenization, reason}}
    end
  end

  defp apply_tokenization(
         canonical,
         %{rendered_prompt: prompt, input_token_count: count, prompt_token_ids: prompt_token_ids}
       ) do
    CanonicalRequest.with_tokenization(canonical, prompt, count, prompt_token_ids)
  end

  defp apply_tokenization(canonical, %{rendered_prompt: prompt, input_token_count: count}) do
    CanonicalRequest.with_tokenization(canonical, prompt, count)
  end

  defp build_tokenizer_opts(model) do
    case TokenizerClient.mode() do
      :fake -> {:ok, []}
      :port -> build_port_tokenizer_opts(model)
      _other -> {:ok, []}
    end
  end

  defp build_port_tokenizer_opts(model) do
    bundle_root = uri_to_local_path(model.artifact_uri)

    case ManifestParser.parse_from_bundle(bundle_root) do
      {:ok, manifest} ->
        {:ok,
         [manifest: manifest, bundle_root: bundle_root, bundle_sha256: model.artifact_sha256]}

      {:error, _reason} ->
        {:error, manifest_tokenization_error()}
    end
  end

  defp uri_to_local_path("file://" <> path), do: path
  defp uri_to_local_path(path), do: path

  defp manifest_tokenization_error do
    {:tokenization, {:internal_error, @manifest_tokenization_error_message}}
  end

  defp enforce_tooling_support(
         %CanonicalRequest{tooling: %CanonicalRequest.Tooling{} = tooling, model_ref: model_ref},
         model
       ) do
    if ToolingValidation.effective_tool_calling?(tooling.tools, tooling.tool_choice) and
         not tool_calling_capable?(model) do
      {:error, {:tooling_not_supported, "#{model_ref.model_id}@#{model_ref.version}"}}
    else
      :ok
    end
  end

  defp tool_calling_capable?(%{capabilities: capabilities}) when is_list(capabilities) do
    "tool_calling" in capabilities
  end

  defp tool_calling_capable?(_model), do: false

  # Models with unknown context windows (nil) skip overflow enforcement.
  # This is intentional for architectures like Gemma 3 VLM where the config
  # does not declare a context limit.
  defp enforce_context_window(_canonical, %{max_context_tokens: nil}), do: :ok

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

  defp effective_max_output_tokens(%CanonicalRequest.Sampling{}), do: @default_max_output_tokens
end
