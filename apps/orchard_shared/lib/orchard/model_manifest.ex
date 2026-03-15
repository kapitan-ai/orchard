defmodule Orchard.ModelManifest do
  @moduledoc """
  Shared domain shape for imported Orchard model bundle manifests.
  """

  import Orchard.StructCasting, only: [cast_nested: 3, build_struct!: 2]

  defmodule Tokenizer do
    @moduledoc false

    @enforce_keys [:kind, :path]
    defstruct kind: nil, path: nil

    @type t :: %__MODULE__{kind: String.t(), path: String.t()}
  end

  defmodule ChatTemplate do
    @moduledoc false

    @enforce_keys [:path, :sha256]
    defstruct path: nil, sha256: nil

    @type t :: %__MODULE__{path: String.t(), sha256: String.t()}
  end

  defmodule RuntimeRequirements do
    @moduledoc false

    @enforce_keys [:adapter, :min_agent_capability]
    defstruct adapter: nil, min_agent_capability: nil

    @type t :: %__MODULE__{adapter: String.t(), min_agent_capability: String.t()}
  end

  alias __MODULE__.{ChatTemplate, RuntimeRequirements, Tokenizer}

  @enforce_keys [
    :model_id,
    :version,
    :format,
    :artifact_layout,
    :entrypoint,
    :sha256,
    :max_context_tokens,
    :capabilities,
    :tokenizer,
    :runtime_requirements
  ]
  defstruct model_id: nil,
            version: nil,
            format: nil,
            artifact_layout: nil,
            entrypoint: nil,
            sha256: nil,
            size_bytes: nil,
            resident_memory_bytes: nil,
            kv_cache_bytes_per_token: nil,
            prefill_workspace_bytes_per_token: nil,
            max_context_tokens: nil,
            capabilities: [],
            tokenizer: nil,
            chat_template: nil,
            runtime_requirements: nil

  @type t :: %__MODULE__{
          model_id: String.t(),
          version: String.t(),
          format: String.t(),
          artifact_layout: String.t(),
          entrypoint: String.t(),
          sha256: String.t(),
          size_bytes: non_neg_integer() | nil,
          resident_memory_bytes: non_neg_integer() | nil,
          kv_cache_bytes_per_token: non_neg_integer() | nil,
          prefill_workspace_bytes_per_token: non_neg_integer() | nil,
          max_context_tokens: pos_integer(),
          capabilities: [String.t()],
          tokenizer: Tokenizer.t(),
          chat_template: ChatTemplate.t() | nil,
          runtime_requirements: RuntimeRequirements.t()
        }

  @doc """
  Builds a model manifest from already-normalized, atom-keyed attrs.

  Parsing external manifest JSON or string-keyed maps belongs in the import
  layer, not in this shared domain constructor.
  """
  @spec new(keyword() | %{optional(atom()) => term()}) :: t()
  def new(attrs) do
    attrs
    |> Map.new()
    |> cast_nested(:tokenizer, Tokenizer)
    |> cast_nested(:chat_template, ChatTemplate)
    |> cast_nested(:runtime_requirements, RuntimeRequirements)
    |> then(&build_struct!(__MODULE__, &1))
    |> validate_required!([
      :model_id,
      :version,
      :format,
      :artifact_layout,
      :entrypoint,
      :sha256,
      :max_context_tokens,
      :capabilities,
      :tokenizer,
      :runtime_requirements
    ])
    |> validate_string_fields!([
      :model_id,
      :version,
      :format,
      :artifact_layout,
      :entrypoint,
      :sha256
    ])
    |> validate_max_context_tokens!()
    |> validate_optional_non_negative_integers!([
      :size_bytes,
      :resident_memory_bytes,
      :kv_cache_bytes_per_token,
      :prefill_workspace_bytes_per_token
    ])
    |> validate_capabilities!()
    |> validate_tokenizer!()
    |> validate_runtime_requirements!()
    |> validate_chat_template!()
  end

  @spec identity(t()) :: {String.t(), String.t()}
  def identity(%__MODULE__{model_id: model_id, version: version}), do: {model_id, version}

  defp validate_required!(struct, keys) do
    Enum.each(keys, fn key ->
      if is_nil(Map.fetch!(struct, key)) do
        raise ArgumentError,
              "#{inspect(__MODULE__)} requires #{inspect(key)} to be present and non-nil"
      end
    end)

    struct
  end

  defp validate_string_fields!(struct, keys) do
    Enum.each(keys, fn key ->
      value = Map.fetch!(struct, key)

      unless is_binary(value) and value != "" do
        raise ArgumentError,
              "#{inspect(__MODULE__)} requires #{inspect(key)} to be a non-empty binary, got: #{inspect(value)}"
      end
    end)

    struct
  end

  defp validate_max_context_tokens!(%__MODULE__{max_context_tokens: max_context_tokens} = struct)
       when is_integer(max_context_tokens) and max_context_tokens > 0,
       do: struct

  defp validate_max_context_tokens!(%__MODULE__{max_context_tokens: max_context_tokens}) do
    raise ArgumentError,
          "#{inspect(__MODULE__)} max_context_tokens must be a positive integer, got: #{inspect(max_context_tokens)}"
  end

  defp validate_optional_non_negative_integers!(struct, fields) do
    Enum.each(fields, fn field ->
      case Map.fetch!(struct, field) do
        nil ->
          :ok

        value when is_integer(value) and value >= 0 ->
          :ok

        value ->
          raise ArgumentError,
                "#{inspect(__MODULE__)} #{inspect(field)} must be nil or a non-negative integer, got: #{inspect(value)}"
      end
    end)

    struct
  end

  defp validate_capabilities!(%__MODULE__{capabilities: capabilities} = struct)
       when is_list(capabilities) do
    if Enum.all?(capabilities, &(is_binary(&1) and &1 != "")) do
      struct
    else
      raise ArgumentError,
            "#{inspect(__MODULE__)} capabilities must be a list of non-empty strings, got: #{inspect(capabilities)}"
    end
  end

  defp validate_capabilities!(%__MODULE__{capabilities: capabilities}) do
    raise ArgumentError,
          "#{inspect(__MODULE__)} capabilities must be a list of non-empty strings, got: #{inspect(capabilities)}"
  end

  defp validate_tokenizer!(%__MODULE__{tokenizer: %Tokenizer{kind: kind, path: path}} = struct)
       when is_binary(kind) and kind != "" and is_binary(path) and path != "",
       do: struct

  defp validate_tokenizer!(%__MODULE__{tokenizer: tokenizer}) do
    raise ArgumentError,
          "#{inspect(__MODULE__)} tokenizer must include non-empty kind/path, got: #{inspect(tokenizer)}"
  end

  defp validate_runtime_requirements!(
         %__MODULE__{
           runtime_requirements: %RuntimeRequirements{
             adapter: adapter,
             min_agent_capability: capability
           }
         } = struct
       )
       when is_binary(adapter) and adapter != "" and is_binary(capability) and capability != "",
       do: struct

  defp validate_runtime_requirements!(%__MODULE__{runtime_requirements: runtime_requirements}) do
    raise ArgumentError,
          "#{inspect(__MODULE__)} runtime_requirements must include non-empty adapter/min_agent_capability, got: #{inspect(runtime_requirements)}"
  end

  defp validate_chat_template!(%__MODULE__{chat_template: nil} = struct), do: struct

  defp validate_chat_template!(
         %__MODULE__{chat_template: %ChatTemplate{path: path, sha256: sha256}} = struct
       )
       when is_binary(path) and path != "" and is_binary(sha256) and sha256 != "",
       do: struct

  defp validate_chat_template!(%__MODULE__{chat_template: chat_template}) do
    raise ArgumentError,
          "#{inspect(__MODULE__)} chat_template must include non-empty path/sha256 when present, got: #{inspect(chat_template)}"
  end
end
