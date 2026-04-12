defmodule Orchard.Cluster.V1.StatusRequest do
  @moduledoc false

  use Protobuf,
    full_name: "cluster.v1.StatusRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3
end

defmodule Orchard.Cluster.V1.RuntimeNodeMetadata do
  @moduledoc false

  use Protobuf,
    full_name: "cluster.v1.RuntimeNodeMetadata",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:node_id, 1, type: :string, json_name: "nodeId")
  field(:display_name, 2, type: :string, json_name: "displayName")
  field(:hostname, 3, type: :string)
  field(:agent_version, 4, type: :string, json_name: "agentVersion")
  field(:listen_host, 5, type: :string, json_name: "listenHost")
  field(:listen_port, 6, type: :uint32, json_name: "listenPort")
  field(:worker_backend, 7, type: :string, json_name: "workerBackend")
end

defmodule Orchard.Cluster.V1.RuntimeHealth do
  @moduledoc false

  use Protobuf,
    full_name: "cluster.v1.RuntimeHealth",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:ready, 1, type: :bool)
  field(:health_code, 2, type: :string, json_name: "healthCode")
  field(:health_message, 3, type: :string, json_name: "healthMessage")
  field(:affected_model, 4, type: Orchard.Cluster.V1.ModelRef, json_name: "affectedModel")
end

defmodule Orchard.Cluster.V1.HostedToolCapability do
  @moduledoc false

  use Protobuf,
    full_name: "cluster.v1.HostedToolCapability",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:name, 1, type: :string)
  field(:version, 2, type: :string)
  field(:adapter_kind, 3, type: :string, json_name: "adapterKind")
end

defmodule Orchard.Cluster.V1.HostedToolReadiness do
  @moduledoc false

  use Protobuf,
    full_name: "cluster.v1.HostedToolReadiness",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:name, 1, type: :string)
  field(:version, 2, type: :string)
  field(:ready, 3, type: :bool)
  field(:readiness_code, 4, type: :string, json_name: "readinessCode")
  field(:readiness_message, 5, type: :string, json_name: "readinessMessage")
end

defmodule Orchard.Cluster.V1.StatusResponse do
  @moduledoc false

  use Protobuf,
    full_name: "cluster.v1.StatusResponse",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:worker_state, 1,
    type: Orchard.Cluster.V1.WorkerState,
    json_name: "workerState",
    enum: true
  )

  field(:loaded_models, 2,
    repeated: true,
    type: Orchard.Cluster.V1.ModelRef,
    json_name: "loadedModels"
  )

  field(:active_request_count, 3, type: :uint32, json_name: "activeRequestCount")

  field(:node_metadata, 4,
    type: Orchard.Cluster.V1.RuntimeNodeMetadata,
    json_name: "nodeMetadata"
  )

  field(:runtime_health, 5, type: Orchard.Cluster.V1.RuntimeHealth, json_name: "runtimeHealth")

  field(:hosted_tool_capabilities, 6,
    repeated: true,
    type: Orchard.Cluster.V1.HostedToolCapability,
    json_name: "hostedToolCapabilities"
  )

  field(:hosted_tool_readiness, 7,
    repeated: true,
    type: Orchard.Cluster.V1.HostedToolReadiness,
    json_name: "hostedToolReadiness"
  )
end

defmodule Orchard.Cluster.V1.EnsureModelLoadedRequest do
  @moduledoc false

  use Protobuf,
    full_name: "cluster.v1.EnsureModelLoadedRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:node_id, 1, type: :string, json_name: "nodeId")
  field(:model_id, 2, type: :string, json_name: "modelId")
  field(:version, 3, type: :string)
  field(:artifact_sha256, 4, type: :string, json_name: "artifactSha256")
  field(:preload, 5, type: :bool)
  field(:deadline_unix_ms, 6, type: :uint64, json_name: "deadlineUnixMs")
  field(:artifact_source_uri, 7, type: :string, json_name: "artifactSourceUri")
end

defmodule Orchard.Cluster.V1.EnsureModelLoadedResponse do
  @moduledoc false

  use Protobuf,
    full_name: "cluster.v1.EnsureModelLoadedResponse",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:already_loaded, 1, type: :bool, json_name: "alreadyLoaded")

  field(:placement_state, 2,
    type: Orchard.Cluster.V1.PlacementState,
    json_name: "placementState",
    enum: true
  )

  field(:failure_category, 3,
    type: Orchard.Cluster.V1.ModelLoadFailureCategory,
    json_name: "failureCategory",
    enum: true
  )

  field(:failure_code, 4, type: :string, json_name: "failureCode")
  field(:failure_message, 5, type: :string, json_name: "failureMessage")
end

defmodule Orchard.Cluster.V1.UnloadModelRequest do
  @moduledoc false

  use Protobuf,
    full_name: "cluster.v1.UnloadModelRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:model_id, 1, type: :string, json_name: "modelId")
  field(:version, 2, type: :string)
  field(:force, 3, type: :bool)
  field(:evict, 4, type: :bool)
end

defmodule Orchard.Cluster.V1.ExecuteInferenceRequest do
  @moduledoc false

  use Protobuf,
    full_name: "cluster.v1.ExecuteInferenceRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:request_id, 1, type: :string, json_name: "requestId")
  field(:controller_session_id, 2, type: :string, json_name: "controllerSessionId")
  field(:model_id, 3, type: :string, json_name: "modelId")
  field(:version, 4, type: :string)
  field(:rendered_prompt_utf8, 5, type: :bytes, json_name: "renderedPromptUtf8")
  field(:input_tokens, 6, type: :uint32, json_name: "inputTokens")
  field(:params, 7, type: Orchard.Cluster.V1.GenerationParams)
  field(:deadline_unix_ms, 8, type: :uint64, json_name: "deadlineUnixMs")
  field(:metadata_json, 9, type: :bytes, json_name: "metadataJson")
end

defmodule Orchard.Cluster.V1.CancelInferenceRequest do
  @moduledoc false

  use Protobuf,
    full_name: "cluster.v1.CancelInferenceRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:request_id, 1, type: :string, json_name: "requestId")
  field(:controller_session_id, 2, type: :string, json_name: "controllerSessionId")
end

defmodule Orchard.Cluster.V1.NodeRuntimeService.Service do
  @moduledoc false

  use GRPC.Service, name: "cluster.v1.NodeRuntimeService", protoc_gen_elixir_version: "0.16.0"

  rpc(:GetStatus, Orchard.Cluster.V1.StatusRequest, Orchard.Cluster.V1.StatusResponse)

  rpc(
    :EnsureModelLoaded,
    Orchard.Cluster.V1.EnsureModelLoadedRequest,
    Orchard.Cluster.V1.EnsureModelLoadedResponse
  )

  rpc(:UnloadModel, Orchard.Cluster.V1.UnloadModelRequest, Orchard.Cluster.V1.Ack)

  rpc(
    :ExecuteInference,
    Orchard.Cluster.V1.ExecuteInferenceRequest,
    stream(Orchard.Cluster.V1.InferenceEvent)
  )

  rpc(:CancelInference, Orchard.Cluster.V1.CancelInferenceRequest, Orchard.Cluster.V1.Ack)
end

defmodule Orchard.Cluster.V1.NodeRuntimeService.Stub do
  @moduledoc false

  use GRPC.Stub, service: Orchard.Cluster.V1.NodeRuntimeService.Service
end
