defmodule Orchard.Inference.ReasoningEffort do
  @moduledoc """
  Binds public effort controls to a reviewed model/template render identity.
  """

  alias Orchard.CanonicalRequest
  alias Orchard.Inference
  alias Orchard.Inference.EffortProfiles
  alias Orchard.Tokenizer.Client

  @profiles_path Path.expand(
                   "../../../../../native/orchard_tokenizer/src/orchard_tokenizer/effort_profiles.json",
                   __DIR__
                 )
  @external_resource @profiles_path
  @profiles EffortProfiles.load!(@profiles_path)
  @tiers %{"low" => :low, "medium" => :medium, "high" => :high}

  @type tier :: :low | :medium | :high
  @type validation_error ::
          {:error, :unsupported_parameter | :unsupported_reasoning_control, String.t()}
          | {:error, :invalid_value, String.t(), String.t()}

  @spec validate(map(), CanonicalRequest.endpoint()) :: :ok | validation_error()

  def validate(params, endpoint) do
    case requested(params, endpoint) do
      {:ok, _tier} -> :ok
      error -> error
    end
  end

  @spec requested(map(), CanonicalRequest.endpoint()) :: {:ok, tier() | nil} | validation_error()
  def requested(params, :chat_completions) do
    case Map.fetch(params, "reasoning_effort") do
      :error -> {:ok, nil}
      {:ok, value} -> tier(value, "reasoning_effort")
    end
  end

  def requested(params, :responses) do
    case Map.fetch(params, "reasoning") do
      :error ->
        {:ok, nil}

      {:ok, control} when is_map(control) ->
        response_control(control)

      {:ok, _control} ->
        {:error, :invalid_value, "reasoning", "must contain exactly one effort field"}
    end
  end

  defp response_control(control) do
    case Enum.find(Map.keys(control), &(&1 != "effort")) do
      nil -> response_effort(control)
      key -> {:error, :unsupported_parameter, "reasoning.#{key}"}
    end
  end

  defp response_effort(control) do
    case Map.fetch(control, "effort") do
      {:ok, effort} -> tier(effort, "reasoning.effort")
      :error -> {:error, :invalid_value, "reasoning", "must contain an effort field"}
    end
  end

  defp tier(value, field) when is_binary(value) do
    case Map.fetch(@tiers, value) do
      {:ok, tier} -> {:ok, tier}
      :error -> {:error, :unsupported_reasoning_control, field}
    end
  end

  defp tier(_value, field),
    do: {:error, :invalid_value, field, "must be low, medium, or high"}

  # Validated controls remain outside the unprepared skeleton until the selected
  # model's trusted manifest is available. No requested/unbound contract is stored.
  @spec bind(CanonicalRequest.t(), map(), keyword()) ::
          {:ok, CanonicalRequest.t()} | {:error, {:validation, tuple()}}
  def bind(%CanonicalRequest{} = request, params, tokenizer_opts) do
    case requested(params, request.endpoint) do
      {:ok, nil} -> {:ok, request}
      {:ok, tier} -> bind_tier(request, tier, tokenizer_opts)
      {:error, type, field} -> {:error, {:validation, {type, field}}}
      {:error, type, field, reason} -> {:error, {:validation, {type, field, reason}}}
    end
  end

  @spec resolve(tier(), term(), term()) ::
          {:ok, CanonicalRequest.Reasoning.t()} | {:error, :unsupported_reasoning_control}
  def resolve(tier, artifact_digest, template_digest) when tier in [:low, :medium, :high] do
    with profile when is_map(profile) <-
           Enum.find(@profiles, fn profile ->
             profile["model_artifact_digest"] == artifact_digest and
               profile["chat_template_digest"] == template_digest
           end),
         native when is_binary(native) <- profile["efforts"][Atom.to_string(tier)] do
      {:ok,
       %CanonicalRequest.Reasoning{
         generation_policy: :enabled,
         projection: :legacy_blended,
         reasoning_effort: tier,
         source: :explicit_public,
         effective_contract: %{
           mode: :rendered,
           model_artifact_digest: artifact_digest,
           chat_template_digest: template_digest,
           render_contract: profile["render_contract"],
           render_contract_version: profile["render_contract_version"],
           native_effort: native
         }
       }}
    else
      _unsupported -> {:error, :unsupported_reasoning_control}
    end
  end

  def resolve(_tier, _artifact_digest, _template_digest),
    do: {:error, :unsupported_reasoning_control}

  defp bind_tier(request, tier, opts) do
    manifest = Keyword.get(opts, :manifest)
    template_digest = manifest && manifest.chat_template && manifest.chat_template.sha256

    with true <- Client.mode() == :port,
         true <- Inference.tokenizer_safe_mode() == :off,
         {:ok, reasoning} <- resolve(tier, Keyword.get(opts, :bundle_sha256), template_digest) do
      {:ok, CanonicalRequest.new(Map.put(Map.from_struct(request), :reasoning, reasoning))}
    else
      _unsupported ->
        field =
          if request.endpoint == :responses, do: "reasoning.effort", else: "reasoning_effort"

        {:error, {:validation, {:unsupported_reasoning_control, field}}}
    end
  end

  @spec arguments(CanonicalRequest.Reasoning.t()) :: map()
  def arguments(%CanonicalRequest.Reasoning{effective_contract: contract}) do
    profile =
      Enum.find(@profiles, fn profile ->
        profile["model_artifact_digest"] == contract.model_artifact_digest and
          profile["chat_template_digest"] == contract.chat_template_digest
      end)

    %{
      profile["generation_argument"]["key"] => profile["generation_argument"]["value"],
      profile["effort_argument"] => contract.native_effort
    }
  end

  @spec verify_tokenization(CanonicalRequest.t(), map()) ::
          :ok | {:error, {:tokenization, tuple()}}
  def verify_tokenization(
        %CanonicalRequest{reasoning: %{effective_contract: %{mode: :rendered}}} = request,
        result
      ) do
    reasoning = request.reasoning
    contract = reasoning.effective_contract

    with {:ok, ^reasoning} <-
           resolve(
             reasoning.reasoning_effort,
             contract.model_artifact_digest,
             contract.chat_template_digest
           ),
         true <- Map.get(result, :reasoning) == CanonicalRequest.Reasoning.to_wire(reasoning),
         true <- Map.get(result, :applied_template_arguments) == arguments(reasoning) do
      :ok
    else
      _mismatch ->
        {:error,
         {:tokenization,
          {:runtime_incompatible, "tokenizer dropped or changed the selected effort proof"}}}
    end
  end

  def verify_tokenization(%CanonicalRequest{}, _result), do: :ok
end
