defmodule Orchard.CanonicalRequest do
  @moduledoc """
  Shared internal request shape derived from the spec-defined canonical request model.
  """

  import Orchard.StructCasting, only: [cast_nested: 3, build_struct!: 2]

  defmodule ModelRef do
    @moduledoc false

    @enforce_keys [:model_id, :version]
    defstruct model_id: nil, version: nil

    @type t :: %__MODULE__{model_id: String.t(), version: String.t()}
  end

  defmodule Sampling do
    @moduledoc false

    defstruct temperature: 1.0,
              top_p: 1.0,
              max_output_tokens: nil,
              stop: [],
              seed: nil

    @type t :: %__MODULE__{
            temperature: float(),
            top_p: float(),
            max_output_tokens: pos_integer() | nil,
            stop: [String.t()],
            seed: integer() | nil
          }
  end

  defmodule ResponseFormat do
    @moduledoc false

    defstruct type: :text

    @type type :: :text | :json_object
    @type t :: %__MODULE__{type: type()}
  end

  defmodule Tooling do
    @moduledoc false

    defstruct tools: [],
              requested_tools: [],
              tool_choice: nil,
              registry_snapshot: %{entries: []},
              execution_snapshot: %{entries: []}

    @type entries_snapshot :: %{required(:entries) => [map()]}

    @type t :: %__MODULE__{
            tools: [map()],
            requested_tools: [map()],
            tool_choice: map() | String.t() | nil,
            registry_snapshot: entries_snapshot(),
            execution_snapshot: entries_snapshot()
          }
  end

  defmodule Admission do
    @moduledoc false

    defstruct timeout_ms: 30_000, queue_wait_ms: 0, max_cold_start_ms: 0

    @type t :: %__MODULE__{
            timeout_ms: pos_integer(),
            queue_wait_ms: non_neg_integer(),
            max_cold_start_ms: non_neg_integer()
          }
  end

  defmodule ResolvedPolicy do
    @moduledoc false

    defstruct quota_id: nil,
              routing_policy_id: nil,
              allowed_pool_ids: [],
              max_active_requests: nil,
              residency_preference: :allow_cold_load

    @type residency_preference :: :required_loaded | :prefer_loaded | :allow_cold_load

    @type t :: %__MODULE__{
            quota_id: String.t() | nil,
            routing_policy_id: String.t() | nil,
            allowed_pool_ids: [String.t()],
            max_active_requests: pos_integer() | nil,
            residency_preference: residency_preference()
          }
  end

  alias __MODULE__.{Admission, ModelRef, ResolvedPolicy, ResponseFormat, Sampling, Tooling}

  @enforce_keys [:internal_id, :public_id, :endpoint, :tenant_id, :model_ref]
  defstruct internal_id: nil,
            public_id: nil,
            endpoint: nil,
            tenant_id: nil,
            principal_id: nil,
            api_key_id: nil,
            model_ref: nil,
            input_items: [],
            rendered_prompt: nil,
            input_token_count: 0,
            prompt_token_ids: nil,
            stream?: false,
            stream_include_usage: false,
            sampling: nil,
            response_format: nil,
            tooling: nil,
            metadata: %{},
            admission: nil,
            resolved_policy: nil

  @type endpoint :: :chat_completions | :responses

  @type t :: %__MODULE__{
          internal_id: String.t(),
          public_id: String.t(),
          endpoint: endpoint(),
          tenant_id: String.t(),
          principal_id: String.t() | nil,
          api_key_id: String.t() | nil,
          model_ref: ModelRef.t(),
          input_items: [map()],
          rendered_prompt: binary() | nil,
          input_token_count: non_neg_integer(),
          prompt_token_ids: [non_neg_integer()] | nil,
          stream?: boolean(),
          stream_include_usage: boolean(),
          sampling: Sampling.t(),
          response_format: ResponseFormat.t(),
          tooling: Tooling.t(),
          metadata: map(),
          admission: Admission.t(),
          resolved_policy: ResolvedPolicy.t()
        }

  @doc """
  Builds a canonical request from already-normalized, atom-keyed attrs.

  External JSON/string-key parsing belongs in dedicated normalization layers,
  not in this shared domain constructor.
  """
  @spec new(keyword() | %{optional(atom()) => term()}) :: t()
  def new(attrs) do
    attrs
    |> Map.new()
    |> cast_nested(:model_ref, ModelRef)
    |> cast_nested(:sampling, Sampling)
    |> cast_nested(:response_format, ResponseFormat)
    |> cast_nested(:tooling, Tooling)
    |> cast_nested(:admission, Admission)
    |> cast_nested(:resolved_policy, ResolvedPolicy)
    |> put_default_struct(:sampling, %Sampling{})
    |> put_default_struct(:response_format, %ResponseFormat{})
    |> put_default_struct(:tooling, %Tooling{})
    |> put_default_struct(:admission, %Admission{})
    |> put_default_struct(:resolved_policy, %ResolvedPolicy{})
    |> then(&build_struct!(__MODULE__, &1))
    |> normalize_sampling_numbers()
    |> validate_required!([:internal_id, :public_id, :endpoint, :tenant_id, :model_ref])
    |> validate_id_fields!()
    |> validate_endpoint!()
    |> validate_model_ref!()
    |> validate_input_items!()
    |> validate_rendered_prompt!()
    |> validate_input_token_count!()
    |> validate_tokenization_state!()
    |> validate_stream!()
    |> validate_sampling!()
    |> validate_tooling!()
    |> validate_metadata!()
    |> validate_response_format!()
    |> validate_admission!()
    |> validate_residency_preference!()
  end

  @spec with_tokenization(t(), binary(), non_neg_integer()) :: t()
  def with_tokenization(%__MODULE__{} = request, rendered_prompt, input_token_count)
      when is_binary(rendered_prompt) and is_integer(input_token_count) and
             input_token_count >= 0 do
    %__MODULE__{
      request
      | rendered_prompt: rendered_prompt,
        input_token_count: input_token_count,
        prompt_token_ids: nil
    }
  end

  def with_tokenization(request, rendered_prompt, input_token_count) do
    raise ArgumentError,
          "#{inspect(__MODULE__)} with_tokenization expects a canonical request, binary rendered_prompt, and non-negative integer input_token_count, got: #{inspect({request, rendered_prompt, input_token_count})}"
  end

  @spec with_tokenization(t(), binary(), non_neg_integer(), [non_neg_integer()]) :: t()
  def with_tokenization(
        %__MODULE__{} = request,
        rendered_prompt,
        input_token_count,
        prompt_token_ids
      )
      when is_binary(rendered_prompt) and is_integer(input_token_count) and
             input_token_count >= 0 and is_list(prompt_token_ids) do
    if length(prompt_token_ids) == input_token_count and
         Enum.all?(prompt_token_ids, &(is_integer(&1) and &1 >= 0)) do
      %__MODULE__{
        request
        | rendered_prompt: rendered_prompt,
          input_token_count: input_token_count,
          prompt_token_ids: prompt_token_ids
      }
    else
      raise ArgumentError,
            "#{inspect(__MODULE__)} with_tokenization expects prompt_token_ids length to equal input_token_count and IDs to be non-negative integers, got count=#{inspect(input_token_count)} ids=#{inspect(prompt_token_ids)}"
    end
  end

  def with_tokenization(request, rendered_prompt, input_token_count, prompt_token_ids) do
    raise ArgumentError,
          "#{inspect(__MODULE__)} with_tokenization expects a canonical request, binary rendered_prompt, non-negative integer input_token_count, and list of non-negative integer prompt_token_ids, got: #{inspect({request, rendered_prompt, input_token_count, prompt_token_ids})}"
  end

  defp put_default_struct(attrs, key, default_struct) do
    case Map.get(attrs, key) do
      nil -> Map.put(attrs, key, default_struct)
      _value -> attrs
    end
  end

  defp validate_required!(struct, keys) do
    Enum.each(keys, fn key ->
      if is_nil(Map.fetch!(struct, key)) do
        raise ArgumentError,
              "#{inspect(__MODULE__)} requires #{inspect(key)} to be present and non-nil"
      end
    end)

    struct
  end

  defp validate_id_fields!(%__MODULE__{} = struct) do
    validate_non_empty_binary!(struct.internal_id, :internal_id)
    validate_non_empty_binary!(struct.public_id, :public_id)
    validate_non_empty_binary!(struct.tenant_id, :tenant_id)

    if not is_nil(struct.principal_id),
      do: validate_non_empty_binary!(struct.principal_id, :principal_id)

    if not is_nil(struct.api_key_id),
      do: validate_non_empty_binary!(struct.api_key_id, :api_key_id)

    struct
  end

  defp validate_endpoint!(%__MODULE__{endpoint: endpoint} = struct)
       when endpoint in [:chat_completions, :responses],
       do: struct

  defp validate_endpoint!(%__MODULE__{endpoint: endpoint}) do
    raise ArgumentError,
          "#{inspect(__MODULE__)} endpoint must be :chat_completions or :responses, got: #{inspect(endpoint)}"
  end

  defp validate_model_ref!(
         %__MODULE__{model_ref: %ModelRef{model_id: model_id, version: version}} = struct
       )
       when is_binary(model_id) and model_id != "" and is_binary(version) and version != "",
       do: struct

  defp validate_model_ref!(%__MODULE__{model_ref: model_ref}) do
    raise ArgumentError,
          "#{inspect(__MODULE__)} model_ref must include non-empty binary model_id/version, got: #{inspect(model_ref)}"
  end

  defp validate_input_items!(%__MODULE__{input_items: input_items} = struct)
       when is_list(input_items) do
    if Enum.all?(input_items, &is_map/1) do
      struct
    else
      raise ArgumentError,
            "#{inspect(__MODULE__)} input_items must be a list of maps, got: #{inspect(input_items)}"
    end
  end

  defp validate_input_items!(%__MODULE__{input_items: input_items}) do
    raise ArgumentError,
          "#{inspect(__MODULE__)} input_items must be a list of maps, got: #{inspect(input_items)}"
  end

  defp validate_rendered_prompt!(%__MODULE__{rendered_prompt: nil} = struct), do: struct

  defp validate_rendered_prompt!(%__MODULE__{rendered_prompt: rendered_prompt} = struct)
       when is_binary(rendered_prompt), do: struct

  defp validate_rendered_prompt!(%__MODULE__{rendered_prompt: rendered_prompt}) do
    raise ArgumentError,
          "#{inspect(__MODULE__)} rendered_prompt must be nil or a binary, got: #{inspect(rendered_prompt)}"
  end

  defp validate_input_token_count!(%__MODULE__{input_token_count: input_token_count} = struct)
       when is_integer(input_token_count) and input_token_count >= 0,
       do: struct

  defp validate_input_token_count!(%__MODULE__{input_token_count: input_token_count}) do
    raise ArgumentError,
          "#{inspect(__MODULE__)} input_token_count must be a non-negative integer, got: #{inspect(input_token_count)}"
  end

  defp validate_tokenization_state!(
         %__MODULE__{rendered_prompt: nil, input_token_count: 0, prompt_token_ids: nil} = struct
       ),
       do: struct

  defp validate_tokenization_state!(
         %__MODULE__{
           rendered_prompt: rendered_prompt,
           input_token_count: input_token_count,
           prompt_token_ids: nil
         } = struct
       )
       when is_binary(rendered_prompt) and is_integer(input_token_count) and
              input_token_count >= 0,
       do: struct

  defp validate_tokenization_state!(
         %__MODULE__{
           rendered_prompt: rendered_prompt,
           input_token_count: input_token_count,
           prompt_token_ids: prompt_token_ids
         } = struct
       )
       when is_binary(rendered_prompt) and is_integer(input_token_count) and
              input_token_count >= 0 and
              is_list(prompt_token_ids) do
    if length(prompt_token_ids) == input_token_count and
         Enum.all?(prompt_token_ids, &(is_integer(&1) and &1 >= 0)) do
      struct
    else
      raise ArgumentError,
            "#{inspect(__MODULE__)} prompt_token_ids must contain non-negative integers and match input_token_count, got: #{inspect({input_token_count, prompt_token_ids})}"
    end
  end

  defp validate_tokenization_state!(%__MODULE__{
         rendered_prompt: rendered_prompt,
         input_token_count: input_token_count,
         prompt_token_ids: prompt_token_ids
       }) do
    raise ArgumentError,
          "#{inspect(__MODULE__)} tokenization state must be one of {nil, 0, nil}, {rendered_prompt, input_token_count, nil}, or {rendered_prompt, input_token_count, prompt_token_ids}, got: #{inspect({rendered_prompt, input_token_count, prompt_token_ids})}"
  end

  defp validate_stream!(
         %__MODULE__{stream?: stream?, stream_include_usage: include_usage} = struct
       )
       when is_boolean(stream?) and is_boolean(include_usage),
       do: struct

  defp validate_stream!(%__MODULE__{stream?: stream?, stream_include_usage: include_usage}) do
    raise ArgumentError,
          "#{inspect(__MODULE__)} stream? must be a boolean and stream_include_usage must be a boolean, got: #{inspect({stream?, include_usage})}"
  end

  defp validate_sampling!(%__MODULE__{sampling: %Sampling{} = sampling} = struct) do
    if valid_sampling?(sampling) do
      struct
    else
      raise ArgumentError,
            "#{inspect(__MODULE__)} sampling contains invalid temperature/top_p/max_output_tokens/stop/seed values: #{inspect(sampling)}"
    end
  end

  defp validate_tooling!(
         %__MODULE__{
           tooling: %Tooling{
             tools: tools,
             requested_tools: requested_tools,
             tool_choice: tool_choice,
             registry_snapshot: registry_snapshot,
             execution_snapshot: execution_snapshot
           }
         } = struct
       )
       when is_list(tools) and is_list(requested_tools) and is_map(registry_snapshot) and
              is_map(execution_snapshot) and
              (is_nil(tool_choice) or is_map(tool_choice) or
                 (is_binary(tool_choice) and tool_choice != "")) do
    validate_tool_maps!(tools, :tools)
    validate_tool_maps!(requested_tools, :requested_tools)
    validate_snapshot!(registry_snapshot, :registry_snapshot)
    validate_snapshot!(execution_snapshot, :execution_snapshot)
    struct
  end

  defp validate_tooling!(%__MODULE__{tooling: tooling}) do
    raise ArgumentError,
          "#{inspect(__MODULE__)} tooling must include tools/requested_tools lists of maps, registry_snapshot/execution_snapshot entries lists of maps, and nil/map/binary tool_choice, got: #{inspect(tooling)}"
  end

  defp validate_metadata!(%__MODULE__{metadata: metadata} = struct) when is_map(metadata),
    do: struct

  defp validate_metadata!(%__MODULE__{metadata: metadata}) do
    raise ArgumentError,
          "#{inspect(__MODULE__)} metadata must be a map, got: #{inspect(metadata)}"
  end

  defp validate_response_format!(
         %__MODULE__{response_format: %ResponseFormat{type: type}} = struct
       )
       when type in [:text, :json_object],
       do: struct

  defp validate_response_format!(%__MODULE__{response_format: response_format}) do
    raise ArgumentError,
          "#{inspect(__MODULE__)} response_format.type must be :text or :json_object, got: #{inspect(response_format)}"
  end

  defp validate_admission!(
         %__MODULE__{
           admission: %Admission{
             timeout_ms: timeout_ms,
             queue_wait_ms: queue_wait_ms,
             max_cold_start_ms: max_cold_start_ms
           }
         } = struct
       )
       when is_integer(timeout_ms) and timeout_ms > 0 and is_integer(queue_wait_ms) and
              queue_wait_ms >= 0 and
              is_integer(max_cold_start_ms) and max_cold_start_ms >= 0,
       do: struct

  defp validate_admission!(%__MODULE__{admission: admission}) do
    raise ArgumentError,
          "#{inspect(__MODULE__)} admission must include positive timeout_ms and non-negative queue_wait_ms/max_cold_start_ms, got: #{inspect(admission)}"
  end

  defp validate_residency_preference!(
         %__MODULE__{
           resolved_policy: %ResolvedPolicy{
             quota_id: quota_id,
             routing_policy_id: routing_policy_id,
             allowed_pool_ids: allowed_pool_ids,
             max_active_requests: max_active_requests,
             residency_preference: preference
           }
         } = struct
       )
       when preference in [:required_loaded, :prefer_loaded, :allow_cold_load] do
    if valid_optional_binary?(quota_id) and valid_optional_binary?(routing_policy_id) and
         valid_allowed_pool_ids?(allowed_pool_ids) and
         valid_optional_positive_integer?(max_active_requests) do
      struct
    else
      raise ArgumentError,
            "#{inspect(__MODULE__)} resolved_policy must include non-empty optional IDs, non-empty string allowed_pool_ids, and optional positive max_active_requests, got: #{inspect(struct.resolved_policy)}"
    end
  end

  defp validate_residency_preference!(%__MODULE__{
         resolved_policy: %ResolvedPolicy{residency_preference: preference}
       }) do
    raise ArgumentError,
          "#{inspect(__MODULE__)} residency_preference must be :required_loaded, :prefer_loaded, or :allow_cold_load, got: #{inspect(preference)}"
  end

  defp normalize_sampling_numbers(%__MODULE__{sampling: %Sampling{} = sampling} = struct) do
    %__MODULE__{
      struct
      | sampling: %Sampling{
          sampling
          | temperature: normalize_numeric(sampling.temperature),
            top_p: normalize_numeric(sampling.top_p)
        }
    }
  end

  defp validate_non_empty_binary!(value, _field_name) when is_binary(value) and value != "",
    do: :ok

  defp validate_non_empty_binary!(value, field_name) do
    raise ArgumentError,
          "#{inspect(__MODULE__)} #{inspect(field_name)} must be a non-empty binary, got: #{inspect(value)}"
  end

  defp valid_sampling?(%Sampling{} = sampling) do
    valid_temperature?(sampling.temperature) and valid_top_p?(sampling.top_p) and
      valid_stop_sequences?(sampling.stop) and valid_seed?(sampling.seed) and
      valid_max_output_tokens?(sampling.max_output_tokens)
  end

  defp valid_stop_sequences?(stop) when is_list(stop),
    do: Enum.all?(stop, &(is_binary(&1) and &1 != ""))

  defp valid_stop_sequences?(_stop), do: false

  defp valid_temperature?(temperature),
    do: is_float(temperature) and temperature >= 0.0

  defp valid_top_p?(top_p),
    do: is_float(top_p) and top_p > 0.0 and top_p <= 1.0

  defp valid_seed?(nil), do: true
  defp valid_seed?(seed), do: is_integer(seed)

  defp valid_max_output_tokens?(nil), do: true

  defp valid_max_output_tokens?(max_output_tokens),
    do: is_integer(max_output_tokens) and max_output_tokens > 0

  defp valid_optional_binary?(nil), do: true
  defp valid_optional_binary?(value), do: is_binary(value) and value != ""

  defp valid_optional_positive_integer?(nil), do: true
  defp valid_optional_positive_integer?(value), do: is_integer(value) and value > 0

  defp valid_allowed_pool_ids?(allowed_pool_ids) when is_list(allowed_pool_ids),
    do: Enum.all?(allowed_pool_ids, &(is_binary(&1) and &1 != ""))

  defp valid_allowed_pool_ids?(_allowed_pool_ids), do: false

  defp validate_tool_maps!(maps, field_name) do
    if Enum.all?(maps, &is_map/1) do
      :ok
    else
      raise ArgumentError,
            "#{inspect(__MODULE__)} tooling.#{field_name} must be a list of maps, got: #{inspect(maps)}"
    end
  end

  defp validate_snapshot!(snapshot, field_name) do
    if valid_entries_snapshot?(snapshot) do
      :ok
    else
      raise ArgumentError,
            "#{inspect(__MODULE__)} tooling.#{field_name} must include an entries list of maps, got: #{inspect(snapshot)}"
    end
  end

  defp valid_entries_snapshot?(%{entries: entries}) when is_list(entries),
    do: Enum.all?(entries, &is_map/1)

  defp valid_entries_snapshot?(%{"entries" => entries}) when is_list(entries),
    do: Enum.all?(entries, &is_map/1)

  defp valid_entries_snapshot?(_snapshot), do: false

  defp normalize_numeric(value) when is_integer(value), do: value * 1.0
  defp normalize_numeric(value), do: value
end
