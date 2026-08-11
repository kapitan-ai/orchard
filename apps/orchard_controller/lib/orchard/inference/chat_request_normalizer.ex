defmodule Orchard.Inference.ChatRequestNormalizer do
  @moduledoc """
  Normalizes validated `/v1/chat/completions` parameters into a
  `CanonicalRequest`.

  Assumes the input has already passed through `ChatRequestValidator`.
  Handles:
  - `max_tokens` → `max_completion_tokens` normalization
  - `model` string → `ModelRef` parsing (`model_id@version` or bare `model_id`)
  - Default value population
  - ID generation (internal_id, public_id)
  - Caller context propagation from authenticated public routes or internal callers
  """

  alias Orchard.CanonicalRequest
  alias Orchard.CanonicalRequest.{ModelRef, ResponseFormat, Sampling, Tooling}
  alias Orchard.Governance
  alias Orchard.Inference.AdmissionPolicy

  @doc """
  Normalizes validated params into a `CanonicalRequest`.

  ## Options (caller context)

    * `:tenant_id` — resolved tenant (default: seeded legacy tenant UUID)
    * `:principal_type` — resolved principal type (default: `:tenant`)
    * `:principal_id` — resolved principal when available
    * `:service_account_id` — resolved service account when available
    * `:api_key_id` — resolved API key when available

  ## Options (test overrides)

    * `:internal_id` — override internal UUID (default: generated)
    * `:public_id` — override public ID (default: `"chatcmpl-" <> uuid`)
  """
  @spec normalize(map(), keyword()) :: {:ok, CanonicalRequest.t()}
  def normalize(params, opts \\ []) when is_map(params) do
    internal_id = Keyword.get(opts, :internal_id, Ecto.UUID.generate())
    public_id = Keyword.get(opts, :public_id, "chatcmpl-" <> internal_id)
    tenant_id = Keyword.get(opts, :tenant_id, Governance.legacy_tenant_id())
    principal_type = Keyword.get(opts, :principal_type, :tenant)
    principal_id = Keyword.get(opts, :principal_id)
    service_account_id = Keyword.get(opts, :service_account_id)
    api_key_id = Keyword.get(opts, :api_key_id)

    policy_opts = Keyword.take(opts, AdmissionPolicy.resolve_option_keys())

    canonical =
      CanonicalRequest.new(
        internal_id: internal_id,
        public_id: public_id,
        endpoint: :chat_completions,
        tenant_id: tenant_id,
        principal_type: principal_type,
        principal_id: principal_id,
        service_account_id: service_account_id,
        api_key_id: api_key_id,
        model_ref: parse_model_ref(params["model"]),
        input_items: params["messages"],
        stream?: Map.get(params, "stream", false),
        stream_include_usage: extract_stream_include_usage(params),
        sampling: build_sampling(params),
        response_format: build_response_format(params),
        tooling: build_tooling(params),
        metadata: normalize_metadata(Map.get(params, "metadata"))
      )
      |> AdmissionPolicy.resolve(policy_opts)

    {:ok, canonical}
  end

  # -- Stream options --

  defp extract_stream_include_usage(params) do
    case get_in(params, ["stream_options", "include_usage"]) do
      true -> true
      _ -> false
    end
  end

  # -- Model ref parsing --

  defp parse_model_ref(model_string) when is_binary(model_string) do
    case String.split(model_string, "@", parts: 2) do
      [model_id, version] -> %ModelRef{model_id: model_id, version: version}
      [model_id] -> %ModelRef{model_id: model_id, version: "default"}
    end
  end

  # -- Sampling --

  defp build_sampling(params) do
    max_output_tokens = resolve_max_tokens(params)

    stop =
      case Map.get(params, "stop") do
        nil -> []
        s when is_binary(s) -> [s]
        s when is_list(s) -> s
      end

    %Sampling{
      temperature: to_float(Map.get(params, "temperature", 1.0)),
      top_p: to_float(Map.get(params, "top_p", 1.0)),
      max_output_tokens: max_output_tokens,
      stop: stop,
      seed: Map.get(params, "seed")
    }
  end

  defp resolve_max_tokens(params) do
    # max_completion_tokens takes precedence (newer field name)
    # max_tokens is the legacy alias
    Map.get(params, "max_completion_tokens") || Map.get(params, "max_tokens")
  end

  defp to_float(value) when is_integer(value), do: value * 1.0
  defp to_float(value) when is_float(value), do: value

  defp normalize_metadata(nil), do: %{}
  defp normalize_metadata(metadata), do: metadata

  # -- Response format --

  defp build_response_format(%{"response_format" => %{"type" => "json_object"}}) do
    %ResponseFormat{type: :json_object}
  end

  defp build_response_format(_params) do
    %ResponseFormat{type: :text}
  end

  # -- Tooling --

  defp build_tooling(params) do
    %Tooling{
      tools: [],
      requested_tools: Map.get(params, "tools", []),
      tool_choice: Map.get(params, "tool_choice"),
      registry_snapshot: %{entries: []},
      execution_snapshot: %{entries: []}
    }
  end
end
