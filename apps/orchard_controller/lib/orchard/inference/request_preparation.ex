defmodule Orchard.Inference.RequestPreparation do
  @moduledoc false

  alias Orchard.CanonicalRequest

  alias Orchard.Inference.{
    AdmissionPolicy,
    ToolExecutionSemantics,
    ToolingValidation,
    ToolRegistryResolver
  }

  alias Orchard.Models
  alias Orchard.Models.Access
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
         {:ok, canonical} <- bind_reasoning_contract(canonical, model),
         :ok <- enforce_tooling_support(canonical, model),
         {:ok, canonical} <- tokenize(canonical, model),
         :ok <- enforce_context_window(canonical, model),
         {:ok, canonical} <- authorize_model(canonical, model) do
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

  defp bind_reasoning_contract(
         %CanonicalRequest{
           reasoning: %CanonicalRequest.Reasoning{
             generation_policy: :enabled,
             projection: :final_only,
             reasoning_effort: :medium,
             source: :explicit_public,
             effective_contract: %{mode: :pending}
           }
         } = canonical,
         model
       ) do
    with "1" <- System.get_env("ORCHARD_KAP112_DISPOSABLE_DB"),
         proof_root when is_binary(proof_root) <- System.get_env("ORCHARD_KAP112_POC_ROOT"),
         path when is_binary(path) <- System.get_env("ORCHARD_KAP112_REASONING_CONTRACT"),
         :ok <- validate_reasoning_registration_file(path, proof_root),
         {:ok, bytes} <- File.read(path),
         {:ok, registration} <- Jason.decode(bytes),
         :ok <- validate_kap112_reasoning_registration(registration, model) do
      contract = %{
        mode: :negotiated,
        model_artifact_digest: registration["model_artifact_digest"],
        chat_template_digest: registration["chat_template_digest"],
        render_contract: registration["render_contract"],
        render_contract_version: registration["render_contract_version"],
        parser_family: registration["parser_family"],
        parser_version: registration["parser_version"],
        runtime_contract_version: registration["runtime_contract_version"],
        event_binding_version: registration["event_binding_version"]
      }

      {:ok, put_in(canonical.reasoning.effective_contract, contract)}
    else
      _reason ->
        {:error,
         {:tokenization,
          {:unsupported_reasoning_control,
           "KAP-112 medium reasoning registration is absent, invalid, or does not match the exact artifact"}}}
    end
  end

  defp bind_reasoning_contract(%CanonicalRequest{} = canonical, model) do
    if kap112_model?(model) do
      {:error,
       {:tokenization,
        {:unsupported_reasoning_control,
         "KAP-112 requests require the exact explicit medium reasoning contract"}}}
    else
      {:ok, canonical}
    end
  end

  defp kap112_model?(model) do
    model.model_id == "Qwen/Qwen3.8-27B" and
      model.version == "1d4bf0f2ff6012fd82039f2fa52739d0dd7c60c0" and
      model.runtime_requirements["adapter"] == "vllm_poc"
  end

  defp validate_reasoning_registration_file(path, proof_root) do
    expanded_path = Path.expand(path)
    expanded_root = Path.expand(proof_root)

    with true <- expanded_path != expanded_root,
         true <- String.starts_with?(expanded_path, expanded_root <> "/"),
         {:ok, %{type: :regular, mode: mode}} <- File.lstat(expanded_path),
         0o600 <- Bitwise.band(mode, 0o777) do
      :ok
    else
      _reason -> :error
    end
  end

  defp validate_kap112_reasoning_registration(registration, model) do
    expected = %{
      "schema_version" => 1,
      "proof_only" => true,
      "model_id" => "Qwen/Qwen3.8-27B",
      "version" => "1d4bf0f2ff6012fd82039f2fa52739d0dd7c60c0",
      "model_artifact_digest" => model.artifact_sha256,
      "chat_template_digest" =>
        get_in(model.capability_evidence, ["tool_calling", "chat_template_sha256"]),
      "generation_policy" => "enabled",
      "projection" => "final_only",
      "reasoning_effort" => "medium",
      "render_contract" => "kap112-qwen3.8-medium",
      "render_contract_version" => "1",
      "parser_family" => "prompt_opened",
      "parser_version" => "v1",
      "runtime_contract_version" => "vllm-poc-v1",
      "event_binding_version" => "worker-runtime-v1",
      "template_arguments" => %{"enable_thinking" => true},
      "reasoning_effort_template_argument" => %{
        "key" => "reasoning_effort",
        "value" => "medium"
      },
      "sampling" => %{
        "temperature" => 1.0,
        "top_p" => 0.95,
        "top_k" => 20,
        "min_p" => 0.0,
        "presence_penalty" => 0.0,
        "repetition_penalty" => 1.0
      }
    }

    if registration == expected and model.model_id == expected["model_id"] and
         model.version == expected["version"] do
      :ok
    else
      :error
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

  defp authorize_model(%CanonicalRequest{} = canonical, model) do
    case Access.authorize(canonical.tenant_id, model.id) do
      {:ok, routing_opts} -> {:ok, AdmissionPolicy.resolve(canonical, routing_opts)}
      {:error, :model_not_authorized} = error -> error
    end
  end

  defp effective_max_output_tokens(%CanonicalRequest.Sampling{max_output_tokens: n})
       when is_integer(n) and n > 0,
       do: n

  defp effective_max_output_tokens(%CanonicalRequest.Sampling{}), do: @default_max_output_tokens
end
