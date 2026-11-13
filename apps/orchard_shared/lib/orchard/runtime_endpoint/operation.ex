defmodule Orchard.RuntimeEndpoint.Operation do
  @moduledoc """
  Operation structs exchanged through the Runtime Endpoint Interface.
  """

  defmodule Ack do
    @moduledoc false

    defstruct ok: false, message: ""

    @type t :: %__MODULE__{ok: boolean(), message: String.t()}
  end

  defmodule EnsureModelLoadedRequest do
    @moduledoc false

    alias Orchard.RuntimeEndpoint.{ModelRef, Operation}

    @enforce_keys [:model_ref]
    defstruct model_ref: nil,
              node_id: nil,
              artifact_sha256: nil,
              preload: false,
              deadline_unix_ms: nil,
              artifact_source_uri: nil,
              metadata: %{}

    @type t :: %__MODULE__{
            model_ref: ModelRef.t(),
            node_id: String.t() | nil,
            artifact_sha256: String.t() | nil,
            preload: boolean(),
            deadline_unix_ms: non_neg_integer() | nil,
            artifact_source_uri: String.t() | nil,
            metadata: map()
          }

    @spec new!(map() | keyword()) :: t()
    def new!(attrs) when is_list(attrs), do: attrs |> Map.new() |> new!()

    def new!(%{} = attrs) do
      %__MODULE__{
        model_ref: ModelRef.new!(Operation.value(attrs, :model_ref)),
        node_id: Operation.value(attrs, :node_id),
        artifact_sha256:
          Operation.optional_binary!(Operation.value(attrs, :artifact_sha256), :artifact_sha256),
        preload: Operation.value(attrs, :preload) == true,
        deadline_unix_ms:
          Operation.optional_non_neg_integer!(
            Operation.value(attrs, :deadline_unix_ms),
            :deadline_unix_ms
          ),
        artifact_source_uri:
          Operation.optional_binary!(
            Operation.value(attrs, :artifact_source_uri),
            :artifact_source_uri
          ),
        metadata: Operation.map_value(attrs, :metadata)
      }
    end
  end

  defmodule EnsureModelLoadedResult do
    @moduledoc false

    alias Orchard.RuntimeEndpoint.PlacementCapacity

    @type placement_capacity_evidence_state :: :absent | :valid | :invalid

    defstruct already_loaded: false,
              placement_state: :unknown,
              failure_category: nil,
              failure_code: nil,
              failure_message: nil,
              worker_supports_prompt_token_ids: false,
              placement_capacity: nil,
              placement_capacity_evidence_state: :absent

    @type t :: %__MODULE__{
            already_loaded: boolean(),
            placement_state: atom() | String.t(),
            failure_category: atom() | String.t() | nil,
            failure_code: String.t() | nil,
            failure_message: String.t() | nil,
            worker_supports_prompt_token_ids: boolean(),
            placement_capacity: PlacementCapacity.t() | nil,
            placement_capacity_evidence_state: placement_capacity_evidence_state()
          }
  end

  defmodule UnloadModelRequest do
    @moduledoc false

    alias Orchard.RuntimeEndpoint.{ModelRef, Operation}

    @enforce_keys [:model_ref]
    defstruct model_ref: nil, force: false, evict: false, deadline_unix_ms: nil, metadata: %{}

    @type t :: %__MODULE__{
            model_ref: ModelRef.t(),
            force: boolean(),
            evict: boolean(),
            deadline_unix_ms: non_neg_integer() | nil,
            metadata: map()
          }

    @spec new!(map() | keyword()) :: t()
    def new!(attrs) when is_list(attrs), do: attrs |> Map.new() |> new!()

    def new!(%{} = attrs) do
      %__MODULE__{
        model_ref: ModelRef.new!(Operation.value(attrs, :model_ref)),
        force: Operation.value(attrs, :force) == true,
        evict: Operation.value(attrs, :evict) == true,
        deadline_unix_ms:
          Operation.optional_non_neg_integer!(
            Operation.value(attrs, :deadline_unix_ms),
            :deadline_unix_ms
          ),
        metadata: Operation.map_value(attrs, :metadata)
      }
    end
  end

  defmodule ExecuteRequest do
    @moduledoc false

    alias Orchard.RuntimeEndpoint.{ModelRef, Operation}

    @enforce_keys [
      :request_id,
      :controller_session_id,
      :model_ref,
      :rendered_prompt_utf8,
      :input_tokens
    ]
    defstruct request_id: nil,
              controller_session_id: nil,
              model_ref: nil,
              rendered_prompt_utf8: "",
              input_tokens: 0,
              params: %{},
              deadline_unix_ms: nil,
              metadata_json: "{}",
              cache_affinity_fingerprint: nil,
              prompt_token_ids: nil,
              artifact_sha256: nil,
              artifact_source_uri: nil,
              preload: false

    @type t :: %__MODULE__{
            request_id: String.t(),
            controller_session_id: String.t(),
            model_ref: ModelRef.t(),
            rendered_prompt_utf8: binary(),
            input_tokens: non_neg_integer(),
            params: map(),
            deadline_unix_ms: non_neg_integer() | nil,
            metadata_json: binary(),
            cache_affinity_fingerprint: String.t() | nil,
            prompt_token_ids: [non_neg_integer()] | nil,
            artifact_sha256: String.t() | nil,
            artifact_source_uri: String.t() | nil,
            preload: boolean()
          }

    @spec new!(map() | keyword()) :: t()
    def new!(attrs) when is_list(attrs), do: attrs |> Map.new() |> new!()

    def new!(%{} = attrs) do
      %__MODULE__{
        request_id: Operation.non_empty_binary!(Operation.value(attrs, :request_id), :request_id),
        controller_session_id:
          Operation.non_empty_binary!(
            Operation.value(attrs, :controller_session_id),
            :controller_session_id
          ),
        model_ref: ModelRef.new!(Operation.value(attrs, :model_ref)),
        rendered_prompt_utf8:
          Operation.binary!(Operation.value(attrs, :rendered_prompt_utf8), :rendered_prompt_utf8),
        input_tokens:
          Operation.non_neg_integer!(Operation.value(attrs, :input_tokens), :input_tokens),
        params: Operation.map_value(attrs, :params),
        deadline_unix_ms:
          Operation.optional_non_neg_integer!(
            Operation.value(attrs, :deadline_unix_ms),
            :deadline_unix_ms
          ),
        metadata_json:
          Operation.binary!(Operation.value(attrs, :metadata_json) || "{}", :metadata_json),
        cache_affinity_fingerprint:
          Operation.optional_binary!(
            Operation.value(attrs, :cache_affinity_fingerprint),
            :cache_affinity_fingerprint
          ),
        prompt_token_ids:
          Operation.optional_token_ids!(Operation.value(attrs, :prompt_token_ids)),
        artifact_sha256:
          Operation.optional_binary!(Operation.value(attrs, :artifact_sha256), :artifact_sha256),
        artifact_source_uri:
          Operation.optional_binary!(
            Operation.value(attrs, :artifact_source_uri),
            :artifact_source_uri
          ),
        preload: Operation.value(attrs, :preload) == true
      }
    end
  end

  defmodule CancelRequest do
    @moduledoc false

    alias Orchard.RuntimeEndpoint.Operation

    @enforce_keys [:request_id, :controller_session_id]
    defstruct request_id: nil, controller_session_id: nil, metadata: %{}

    @type t :: %__MODULE__{
            request_id: String.t(),
            controller_session_id: String.t(),
            metadata: map()
          }

    @spec new!(map() | keyword()) :: t()
    def new!(attrs) when is_list(attrs), do: attrs |> Map.new() |> new!()

    def new!(%{} = attrs) do
      %__MODULE__{
        request_id: Operation.non_empty_binary!(Operation.value(attrs, :request_id), :request_id),
        controller_session_id:
          Operation.non_empty_binary!(
            Operation.value(attrs, :controller_session_id),
            :controller_session_id
          ),
        metadata: Operation.map_value(attrs, :metadata)
      }
    end
  end

  defmodule PrefixCacheScoreRequest do
    @moduledoc false

    alias Orchard.RuntimeEndpoint.{ModelRef, Operation}

    @enforce_keys [:request_id, :controller_session_id, :model_ref, :cache_affinity_fingerprint]
    defstruct request_id: nil,
              controller_session_id: nil,
              model_ref: nil,
              cache_affinity_fingerprint: nil,
              deadline_unix_ms: nil,
              metadata: %{}

    @type t :: %__MODULE__{
            request_id: String.t(),
            controller_session_id: String.t(),
            model_ref: ModelRef.t(),
            cache_affinity_fingerprint: String.t(),
            deadline_unix_ms: non_neg_integer() | nil,
            metadata: map()
          }

    @spec new!(map() | keyword()) :: t()
    def new!(attrs) when is_list(attrs), do: attrs |> Map.new() |> new!()

    def new!(%{} = attrs) do
      %__MODULE__{
        request_id: Operation.non_empty_binary!(Operation.value(attrs, :request_id), :request_id),
        controller_session_id:
          Operation.non_empty_binary!(
            Operation.value(attrs, :controller_session_id),
            :controller_session_id
          ),
        model_ref: ModelRef.new!(Operation.value(attrs, :model_ref)),
        cache_affinity_fingerprint:
          Operation.non_empty_binary!(
            Operation.value(attrs, :cache_affinity_fingerprint),
            :cache_affinity_fingerprint
          ),
        deadline_unix_ms:
          Operation.optional_non_neg_integer!(
            Operation.value(attrs, :deadline_unix_ms),
            :deadline_unix_ms
          ),
        metadata: Operation.map_value(attrs, :metadata)
      }
    end
  end

  defmodule PrefixCacheScoreResult do
    @moduledoc false

    defstruct status_code: "unknown",
              status_message: "",
              resident_fingerprint_match: false,
              score_tier: "unknown",
              session_started_unix_ms: 0

    @type t :: %__MODULE__{
            status_code: String.t(),
            status_message: String.t(),
            resident_fingerprint_match: boolean(),
            score_tier: String.t(),
            session_started_unix_ms: non_neg_integer()
          }
  end

  @spec value(map(), atom()) :: term()
  def value(%{} = attrs, key) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(attrs, key) -> Map.fetch!(attrs, key)
      Map.has_key?(attrs, string_key) -> Map.fetch!(attrs, string_key)
      true -> nil
    end
  end

  @spec map_value(map(), atom()) :: map()
  def map_value(attrs, key) do
    case value(attrs, key) do
      %{} = map -> map
      nil -> %{}
      other -> raise ArgumentError, "#{key} must be a map, got: #{inspect(other)}"
    end
  end

  @spec non_empty_binary!(term(), atom()) :: String.t()
  def non_empty_binary!(value, _key) when is_binary(value) and value != "", do: value

  def non_empty_binary!(value, key),
    do: raise(ArgumentError, "#{key} must be a non-empty binary, got: #{inspect(value)}")

  @spec binary!(term(), atom()) :: binary()
  def binary!(value, _key) when is_binary(value), do: value

  def binary!(value, key),
    do: raise(ArgumentError, "#{key} must be a binary, got: #{inspect(value)}")

  @spec optional_binary!(term(), atom()) :: String.t() | nil
  def optional_binary!(nil, _key), do: nil
  def optional_binary!(value, key), do: binary!(value, key)

  @spec non_neg_integer!(term(), atom()) :: non_neg_integer()
  def non_neg_integer!(value, _key) when is_integer(value) and value >= 0, do: value

  def non_neg_integer!(value, key),
    do: raise(ArgumentError, "#{key} must be a non-negative integer, got: #{inspect(value)}")

  @spec optional_non_neg_integer!(term(), atom()) :: non_neg_integer() | nil
  def optional_non_neg_integer!(nil, _key), do: nil
  def optional_non_neg_integer!(value, key), do: non_neg_integer!(value, key)

  @spec optional_token_ids!(term()) :: [non_neg_integer()] | nil
  def optional_token_ids!(nil), do: nil

  def optional_token_ids!(token_ids) when is_list(token_ids) do
    if Enum.all?(token_ids, &(is_integer(&1) and &1 >= 0)) do
      token_ids
    else
      raise ArgumentError, "prompt_token_ids must be a list of non-negative integers"
    end
  end

  def optional_token_ids!(token_ids),
    do:
      raise(
        ArgumentError,
        "prompt_token_ids must be a list of non-negative integers, got: #{inspect(token_ids)}"
      )
end
