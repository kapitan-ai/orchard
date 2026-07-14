defmodule Orchard.Inference.ModelLoadFailureTest do
  use ExUnit.Case, async: true

  alias Orchard.Cluster.V1.EnsureModelLoadedResponse
  alias Orchard.Inference.ModelLoadFailure

  # -- from_response/1 -------------------------------------------------------

  test "from_response preserves classified response fields" do
    response = %EnsureModelLoadedResponse{
      already_loaded: false,
      placement_state: :PLACEMENT_STATE_FAILED,
      failure_category: :MODEL_LOAD_FAILURE_CATEGORY_RUNTIME_UNAVAILABLE,
      failure_code: "mlx_backend_unavailable",
      failure_message: "MLX backend is unavailable on this node"
    }

    failure = ModelLoadFailure.from_response(response)
    assert failure.category == :runtime_unavailable
    assert failure.code == "mlx_backend_unavailable"
    assert failure.message == "MLX backend is unavailable on this node"
  end

  test "from_response handles MODEL_INVALID category" do
    response = %EnsureModelLoadedResponse{
      already_loaded: false,
      placement_state: :PLACEMENT_STATE_FAILED,
      failure_category: :MODEL_LOAD_FAILURE_CATEGORY_MODEL_INVALID,
      failure_code: "manifest_not_found",
      failure_message: "model manifest is missing"
    }

    failure = ModelLoadFailure.from_response(response)
    assert failure.category == :model_invalid
    assert failure.code == "manifest_not_found"
  end

  test "from_response handles TIMEOUT category" do
    response = %EnsureModelLoadedResponse{
      already_loaded: false,
      placement_state: :PLACEMENT_STATE_FAILED,
      failure_category: :MODEL_LOAD_FAILURE_CATEGORY_TIMEOUT,
      failure_code: "deadline_exceeded",
      failure_message: "model load exceeded its deadline"
    }

    failure = ModelLoadFailure.from_response(response)
    assert failure.category == :timeout
    assert failure.code == "deadline_exceeded"
  end

  test "from_response legacy UNSPECIFIED with blank fields falls back to internal" do
    response = %EnsureModelLoadedResponse{
      already_loaded: false,
      placement_state: :PLACEMENT_STATE_FAILED,
      failure_category: :MODEL_LOAD_FAILURE_CATEGORY_UNSPECIFIED,
      failure_code: "",
      failure_message: ""
    }

    failure = ModelLoadFailure.from_response(response)
    assert failure.category == :internal
    assert failure.code == "internal_error"
    assert failure.message == "model load failed due to an internal error"
  end

  test "from_response with default struct (proto3 defaults) falls back to internal" do
    failure = ModelLoadFailure.from_response(%EnsureModelLoadedResponse{})
    assert failure.category == :internal
    assert failure.code == "internal_error"
    assert failure.message == "model load failed due to an internal error"
  end

  test "from_response with unknown category integer falls back to internal with controller default message" do
    response = %EnsureModelLoadedResponse{
      already_loaded: false,
      placement_state: :PLACEMENT_STATE_FAILED,
      failure_category: 99,
      failure_code: "some_code",
      failure_message: "some internal detail that should not leak"
    }

    failure = ModelLoadFailure.from_response(response)
    assert failure.category == :internal
    # Code is preserved (sanitized snake_case, safe for observability)
    assert failure.code == "some_code"
    # Message is NOT preserved for unknown categories — uses controller default
    assert failure.message == "model load failed due to an internal error"
  end

  test "from_response UNSPECIFIED with non-empty message uses controller default" do
    response = %EnsureModelLoadedResponse{
      already_loaded: false,
      placement_state: :PLACEMENT_STATE_FAILED,
      failure_category: :MODEL_LOAD_FAILURE_CATEGORY_UNSPECIFIED,
      failure_code: "some_code",
      failure_message: "/var/lib/orchard/models/leaked-path/model.safetensors"
    }

    failure = ModelLoadFailure.from_response(response)
    assert failure.category == :internal
    assert failure.code == "some_code"
    # Leaked path must NOT appear in the message
    assert failure.message == "model load failed due to an internal error"
    refute failure.message =~ "leaked-path"
  end

  test "from_response known INTERNAL category preserves sanitized node message" do
    response = %EnsureModelLoadedResponse{
      already_loaded: false,
      placement_state: :PLACEMENT_STATE_FAILED,
      failure_category: :MODEL_LOAD_FAILURE_CATEGORY_INTERNAL,
      failure_code: "task_crashed",
      failure_message: "model load task crashed unexpectedly"
    }

    failure = ModelLoadFailure.from_response(response)
    assert failure.category == :internal
    assert failure.code == "task_crashed"
    # Known INTERNAL category: node message is trusted
    assert failure.message == "model load task crashed unexpectedly"
  end

  test "from_response normalizes blank code to category default" do
    response = %EnsureModelLoadedResponse{
      already_loaded: false,
      placement_state: :PLACEMENT_STATE_FAILED,
      failure_category: :MODEL_LOAD_FAILURE_CATEGORY_TIMEOUT,
      failure_code: "",
      failure_message: "custom timeout message"
    }

    failure = ModelLoadFailure.from_response(response)
    assert failure.category == :timeout
    assert failure.code == "timeout"
    assert failure.message == "custom timeout message"
  end

  # -- from_transport_reason/1 ------------------------------------------------

  test "from_transport_reason node_unavailable -> runtime_unavailable" do
    failure = ModelLoadFailure.from_transport_reason(:node_unavailable)
    assert failure.category == :runtime_unavailable
    assert failure.code == "node_unavailable"
  end

  test "from_transport_reason node_timeout -> timeout" do
    failure = ModelLoadFailure.from_transport_reason(:node_timeout)
    assert failure.category == :timeout
    assert failure.code == "node_timeout"
  end

  test "from_transport_reason beam_node_unavailable -> runtime_unavailable" do
    failure = ModelLoadFailure.from_transport_reason(:beam_node_unavailable)
    assert failure.category == :runtime_unavailable
  end

  test "from_transport_reason beam_target_unknown -> runtime_unavailable" do
    failure = ModelLoadFailure.from_transport_reason(:beam_target_unknown)
    assert failure.category == :runtime_unavailable
  end

  test "from_transport_reason beam_node_timeout -> timeout" do
    failure = ModelLoadFailure.from_transport_reason(:beam_node_timeout)
    assert failure.category == :timeout
  end

  test "from_transport_reason beam_rpc_failed -> internal rpc error" do
    failure = ModelLoadFailure.from_transport_reason(:beam_rpc_failed)
    assert failure.category == :internal
    assert failure.code == "rpc_error"
  end

  test "from_transport_reason unexpected_placement_state -> internal" do
    failure =
      ModelLoadFailure.from_transport_reason(
        {:unexpected_placement_state, :PLACEMENT_STATE_LOADING}
      )

    assert failure.category == :internal
    assert failure.code == "unexpected_placement_state"
    assert failure.message =~ "PLACEMENT_STATE_LOADING"
  end

  test "from_transport_reason rpc_error with resource_exhausted" do
    failure =
      ModelLoadFailure.from_transport_reason({:rpc_error, :resource_exhausted, "too many"})

    assert failure.category == :resource_exhausted
    assert failure.code == "rpc_resource_exhausted"
  end

  test "from_transport_reason rpc_error with generic status" do
    failure = ModelLoadFailure.from_transport_reason({:rpc_error, :unavailable, "unavail"})
    assert failure.category == :internal
    assert failure.code == "rpc_unavailable"
  end

  test "from_transport_reason rpc_error 2-tuple" do
    failure = ModelLoadFailure.from_transport_reason({:rpc_error, "some detail"})
    assert failure.category == :internal
    assert failure.code == "rpc_error"
  end

  test "from_transport_reason unknown reason -> internal" do
    failure = ModelLoadFailure.from_transport_reason(:something_unexpected)
    assert failure.category == :internal
    assert failure.code == "internal_error"
  end

  # -- api_mapping/1 ----------------------------------------------------------

  test "api_mapping for runtime_unavailable -> 503 server_error" do
    failure = %ModelLoadFailure{
      category: :runtime_unavailable,
      code: "mlx_backend_unavailable",
      message: "MLX unavailable"
    }

    mapping = ModelLoadFailure.api_mapping(failure)
    assert mapping.status == :service_unavailable
    assert mapping.type == "server_error"
    assert mapping.code == "mlx_backend_unavailable"
    assert mapping.message == "MLX unavailable"
  end

  test "api_mapping for timeout -> 504 server_error" do
    failure = %ModelLoadFailure{
      category: :timeout,
      code: "deadline_exceeded",
      message: "timed out"
    }

    mapping = ModelLoadFailure.api_mapping(failure)
    assert mapping.status == :gateway_timeout
    assert mapping.type == "server_error"
  end

  test "api_mapping for internal -> 500 api_error" do
    failure = %ModelLoadFailure{category: :internal, code: "internal_error", message: "error"}
    mapping = ModelLoadFailure.api_mapping(failure)
    assert mapping.status == :internal_server_error
    assert mapping.type == "api_error"
  end

  # -- terminal_attrs/1 -------------------------------------------------------

  test "terminal_attrs sets state failed and correct http_status" do
    failure = %ModelLoadFailure{
      category: :timeout,
      code: "deadline_exceeded",
      message: "timed out"
    }

    attrs = ModelLoadFailure.terminal_attrs(failure)
    assert attrs.state == :failed
    assert attrs.http_status == 504
    assert attrs.error_code == "deadline_exceeded"
    assert attrs.error_message == "timed out"
  end

  test "terminal_attrs for model_invalid returns 503" do
    failure = %ModelLoadFailure{
      category: :model_invalid,
      code: "manifest_not_found",
      message: "missing"
    }

    attrs = ModelLoadFailure.terminal_attrs(failure)
    assert attrs.http_status == 503
  end

  test "terminal_attrs for internal returns 500" do
    failure = %ModelLoadFailure{category: :internal, code: "internal_error", message: "error"}
    attrs = ModelLoadFailure.terminal_attrs(failure)
    assert attrs.http_status == 500
  end
end
