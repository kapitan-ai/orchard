defmodule Orchard.Inference.ModelLoadFailure do
  @moduledoc """
  Controller-side model load failure normalization and API mapping.

  Converts Runtime Endpoint ensure-model-loaded results, legacy
  `EnsureModelLoadedResponse` proto failure fields, and transport-level errors
  into a structured failure value used by the orchestrator and API
  layer for HTTP status selection, SSE error envelopes, and persistence.

  This module operates at the controller boundary — it never sees raw node-agent
  error reasons. It normalizes only:
  - Runtime Endpoint result fields (`failure_category`, `failure_code`, `failure_message`)
  - Proto response fields (`failure_category`, `failure_code`, `failure_message`)
  - Transport errors from Runtime Endpoint clients (`:node_unavailable`, `:node_timeout`, etc.)
  """

  alias Orchard.Cluster.V1.EnsureModelLoadedResponse
  alias Orchard.RuntimeEndpoint.Operation

  @enforce_keys [:category, :code, :message]
  defstruct [:category, :code, :message]

  @type category ::
          :model_invalid
          | :acquisition_failed
          | :runtime_unavailable
          | :timeout
          | :resource_exhausted
          | :internal

  @type t :: %__MODULE__{
          category: category(),
          code: String.t(),
          message: String.t()
        }

  # -- Public API ------------------------------------------------------------

  @doc """
  Extracts a failure struct from an `EnsureModelLoadedResponse` with
  `PLACEMENT_STATE_FAILED`.

  Handles legacy responses (UNSPECIFIED + blank fields) and unknown enum values
  defensively — never raises.
  """
  @spec from_response(EnsureModelLoadedResponse.t()) :: t()
  def from_response(%EnsureModelLoadedResponse{} = response) do
    {category, trusted?} = normalize_category(response.failure_category)
    {default_code, default_message} = defaults_for_category(category)
    code = normalize_code(response.failure_code, default_code)

    # Trust node-provided messages only for explicitly known categories.
    # For UNSPECIFIED/unknown values, always use controller-owned defaults
    # to prevent leaking arbitrary node-side text to API consumers.
    message =
      if trusted? do
        normalize_message(response.failure_message, default_message)
      else
        default_message
      end

    %__MODULE__{category: category, code: code, message: message}
  end

  @doc """
  Extracts a failure struct from a Runtime Endpoint ensure-model-loaded result.
  """
  @spec from_result(Operation.EnsureModelLoadedResult.t()) :: t()
  def from_result(%Operation.EnsureModelLoadedResult{} = result) do
    {category, trusted?} = normalize_result_category(result.failure_category)
    {default_code, default_message} = defaults_for_category(category)
    code = normalize_code(result.failure_code, default_code)

    message =
      if trusted? do
        normalize_message(result.failure_message, default_message)
      else
        default_message
      end

    %__MODULE__{category: category, code: code, message: message}
  end

  @doc """
  Rebuilds the Controller-owned public model-load failure for a normalized
  attempt failure category.

  Attempt evidence deliberately stores the stable category default rather than
  trusting a Runtime Endpoint failure code or message to control public output.
  """
  @spec from_category(category() | String.t()) :: t()
  def from_category("model_invalid"), do: from_category(:model_invalid)
  def from_category("acquisition_failed"), do: from_category(:acquisition_failed)
  def from_category("runtime_unavailable"), do: from_category(:runtime_unavailable)
  def from_category("timeout"), do: from_category(:timeout)
  def from_category("resource_exhausted"), do: from_category(:resource_exhausted)
  def from_category("internal_error"), do: from_category(:internal)

  def from_category(category)
      when category in [
             :model_invalid,
             :acquisition_failed,
             :runtime_unavailable,
             :timeout,
             :resource_exhausted,
             :internal
           ] do
    {code, message} = defaults_for_category(category)
    %__MODULE__{category: category, code: code, message: message}
  end

  def from_category(_category), do: from_category(:internal)

  @doc """
  Converts a transport-level error reason into a failure struct.

  Accepts normalized error shapes from Runtime Endpoint clients.
  """
  @spec from_transport_reason(term()) :: t()
  def from_transport_reason(:node_unavailable) do
    %__MODULE__{
      category: :runtime_unavailable,
      code: "node_unavailable",
      message: "node runtime is unavailable"
    }
  end

  def from_transport_reason(:beam_node_unavailable),
    do: from_transport_reason(:node_unavailable)

  def from_transport_reason(:beam_target_unknown),
    do: from_transport_reason(:node_unavailable)

  def from_transport_reason(:node_timeout) do
    %__MODULE__{
      category: :timeout,
      code: "load_timeout",
      message: "model load timed out"
    }
  end

  def from_transport_reason(:beam_node_timeout), do: from_transport_reason(:node_timeout)
  def from_transport_reason(:timeout), do: from_transport_reason(:node_timeout)

  def from_transport_reason(:beam_rpc_failed),
    do: from_transport_reason({:rpc_error, :beam_rpc_failed})

  def from_transport_reason({:unexpected_placement_state, placement_state}) do
    %__MODULE__{
      category: :internal,
      code: "unexpected_placement_state",
      message: "unexpected placement state: #{format_placement_state(placement_state)}"
    }
  end

  def from_transport_reason({:rpc_error, :resource_exhausted, _message}) do
    %__MODULE__{
      category: :resource_exhausted,
      code: "rpc_resource_exhausted",
      message: "model load RPC was rejected due to resource exhaustion"
    }
  end

  def from_transport_reason({:rpc_error, status, _message})
      when status in [:deadline_exceeded, 4] do
    from_transport_reason(:node_timeout)
  end

  def from_transport_reason({:rpc_error, status, _message}) when is_atom(status) do
    %__MODULE__{
      category: :internal,
      code: "rpc_#{status}",
      message: "model load RPC failed"
    }
  end

  def from_transport_reason({:rpc_error, _detail}) do
    %__MODULE__{
      category: :internal,
      code: "rpc_error",
      message: "model load RPC failed"
    }
  end

  def from_transport_reason(_reason) do
    %__MODULE__{
      category: :internal,
      code: "internal_error",
      message: "model load failed due to an internal error"
    }
  end

  @doc """
  Maps a failure to HTTP status and OpenAI error envelope fields.

  Returns a map with `:status` (Plug status atom), `:type` (OpenAI error type),
  `:code` (failure code), and `:message` (client-safe message).
  """
  @spec api_mapping(t()) :: %{
          status: atom(),
          type: String.t(),
          code: String.t(),
          message: String.t()
        }
  def api_mapping(%__MODULE__{} = failure) do
    {status, type} = http_mapping(failure.category)

    %{
      status: status,
      type: type,
      code: failure.code,
      message: failure.message
    }
  end

  @doc """
  Builds terminal persistence attrs for `Requests.mark_terminal/2`.

  Always sets `:state` to `:failed` — model load failures are pre-inference
  terminal outcomes.
  """
  @spec terminal_attrs(t()) :: %{
          state: :failed,
          http_status: integer(),
          error_code: String.t(),
          error_message: String.t()
        }
  def terminal_attrs(%__MODULE__{} = failure) do
    %{
      state: :failed,
      http_status: http_status_code(failure.category),
      error_code: failure.code,
      error_message: failure.message
    }
  end

  # -- Private helpers -------------------------------------------------------

  # Proto enum atom → {controller_category, trusted?}.
  # Returns trusted? = true for explicitly known enum values so the caller
  # can decide whether to trust node-provided failure_message content.
  # UNSPECIFIED, unknown integers, and nil map to {:internal, false}.
  defp normalize_category(:MODEL_LOAD_FAILURE_CATEGORY_MODEL_INVALID), do: {:model_invalid, true}

  defp normalize_category(:MODEL_LOAD_FAILURE_CATEGORY_ACQUISITION_FAILED),
    do: {:acquisition_failed, true}

  defp normalize_category(:MODEL_LOAD_FAILURE_CATEGORY_RUNTIME_UNAVAILABLE),
    do: {:runtime_unavailable, true}

  defp normalize_category(:MODEL_LOAD_FAILURE_CATEGORY_TIMEOUT), do: {:timeout, true}

  defp normalize_category(:MODEL_LOAD_FAILURE_CATEGORY_RESOURCE_EXHAUSTED),
    do: {:resource_exhausted, true}

  defp normalize_category(:MODEL_LOAD_FAILURE_CATEGORY_INTERNAL), do: {:internal, true}
  # Raw integer fallback (future-proofing for unknown proto values)
  defp normalize_category(1), do: {:model_invalid, true}
  defp normalize_category(2), do: {:acquisition_failed, true}
  defp normalize_category(3), do: {:runtime_unavailable, true}
  defp normalize_category(4), do: {:timeout, true}
  defp normalize_category(5), do: {:resource_exhausted, true}
  defp normalize_category(6), do: {:internal, true}
  # UNSPECIFIED, unknown values, nil — untrusted
  defp normalize_category(_), do: {:internal, false}

  defp normalize_result_category(category)
       when category in [
              :model_invalid,
              :acquisition_failed,
              :runtime_unavailable,
              :timeout,
              :resource_exhausted,
              :internal
            ],
       do: {category, true}

  defp normalize_result_category(_category), do: {:internal, false}

  defp normalize_code(code, default) when is_binary(code) do
    trimmed = String.trim(code)

    if trimmed != "" and Regex.match?(~r/^[a-z0-9_]+$/, trimmed) do
      trimmed
    else
      default
    end
  end

  defp normalize_code(_, default), do: default

  defp normalize_message(message, default) when is_binary(message) do
    trimmed = String.trim(message)
    if trimmed != "", do: trimmed, else: default
  end

  defp normalize_message(_, default), do: default

  defp defaults_for_category(:model_invalid), do: {"model_invalid", "model artifact is invalid"}

  defp defaults_for_category(:acquisition_failed),
    do: {"acquisition_failed", "model acquisition failed"}

  defp defaults_for_category(:runtime_unavailable),
    do: {"runtime_unavailable", "model runtime is unavailable"}

  defp defaults_for_category(:timeout), do: {"load_timeout", "model load timed out"}

  defp defaults_for_category(:resource_exhausted),
    do: {"resource_exhausted", "resources exhausted"}

  defp defaults_for_category(:internal),
    do: {"internal_error", "model load failed due to an internal error"}

  defp http_mapping(:model_invalid), do: {:service_unavailable, "server_error"}
  defp http_mapping(:acquisition_failed), do: {:service_unavailable, "server_error"}
  defp http_mapping(:runtime_unavailable), do: {:service_unavailable, "server_error"}
  defp http_mapping(:timeout), do: {:gateway_timeout, "server_error"}
  defp http_mapping(:resource_exhausted), do: {:service_unavailable, "server_error"}
  defp http_mapping(:internal), do: {:internal_server_error, "api_error"}

  defp http_status_code(:model_invalid), do: 503
  defp http_status_code(:acquisition_failed), do: 503
  defp http_status_code(:runtime_unavailable), do: 503
  defp http_status_code(:timeout), do: 504
  defp http_status_code(:resource_exhausted), do: 503
  defp http_status_code(:internal), do: 500

  # Safely format a placement state for error messages without leaking internals.
  defp format_placement_state(state) when is_atom(state), do: Atom.to_string(state)
  defp format_placement_state(state) when is_integer(state), do: "unknown(#{state})"
  defp format_placement_state(_), do: "unknown"
end
