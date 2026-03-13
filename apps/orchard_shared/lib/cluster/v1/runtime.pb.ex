defmodule Orchard.Cluster.V1.StatusRequest do
  @moduledoc false

  use Protobuf,
    full_name: "cluster.v1.StatusRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3
end

defmodule Orchard.Cluster.V1.StatusResponse do
  @moduledoc false

  use Protobuf,
    full_name: "cluster.v1.StatusResponse",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :worker_state, 1,
    type: Orchard.Cluster.V1.WorkerState,
    json_name: "workerState",
    enum: true

  field :loaded_models, 2,
    repeated: true,
    type: Orchard.Cluster.V1.ModelRef,
    json_name: "loadedModels"

  field :active_request_count, 3, type: :uint32, json_name: "activeRequestCount"
end

defmodule Orchard.Cluster.V1.EnsureModelLoadedRequest do
  @moduledoc false

  use Protobuf,
    full_name: "cluster.v1.EnsureModelLoadedRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :node_id, 1, type: :string, json_name: "nodeId"
  field :model_id, 2, type: :string, json_name: "modelId"
  field :version, 3, type: :string
  field :artifact_sha256, 4, type: :string, json_name: "artifactSha256"
  field :preload, 5, type: :bool
  field :deadline_unix_ms, 6, type: :uint64, json_name: "deadlineUnixMs"
  field :artifact_source_uri, 7, type: :string, json_name: "artifactSourceUri"
end

defmodule Orchard.Cluster.V1.EnsureModelLoadedResponse do
  @moduledoc false

  use Protobuf,
    full_name: "cluster.v1.EnsureModelLoadedResponse",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :already_loaded, 1, type: :bool, json_name: "alreadyLoaded"

  field :placement_state, 2,
    type: Orchard.Cluster.V1.PlacementState,
    json_name: "placementState",
    enum: true

  field :failure_category, 3,
    type: Orchard.Cluster.V1.ModelLoadFailureCategory,
    json_name: "failureCategory",
    enum: true

  field :failure_code, 4, type: :string, json_name: "failureCode"
  field :failure_message, 5, type: :string, json_name: "failureMessage"
end

defmodule Orchard.Cluster.V1.UnloadModelRequest do
  @moduledoc false

  use Protobuf,
    full_name: "cluster.v1.UnloadModelRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :model_id, 1, type: :string, json_name: "modelId"
  field :version, 2, type: :string
  field :force, 3, type: :bool
  field :evict, 4, type: :bool
end

defmodule Orchard.Cluster.V1.ExecuteInferenceRequest do
  @moduledoc false

  use Protobuf,
    full_name: "cluster.v1.ExecuteInferenceRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :request_id, 1, type: :string, json_name: "requestId"
  field :controller_session_id, 2, type: :string, json_name: "controllerSessionId"
  field :model_id, 3, type: :string, json_name: "modelId"
  field :version, 4, type: :string
  field :rendered_prompt_utf8, 5, type: :bytes, json_name: "renderedPromptUtf8"
  field :input_tokens, 6, type: :uint32, json_name: "inputTokens"
  field :params, 7, type: Orchard.Cluster.V1.GenerationParams
  field :deadline_unix_ms, 8, type: :uint64, json_name: "deadlineUnixMs"
  field :metadata_json, 9, type: :bytes, json_name: "metadataJson"
end

defmodule Orchard.Cluster.V1.CancelInferenceRequest do
  @moduledoc false

  use Protobuf,
    full_name: "cluster.v1.CancelInferenceRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :request_id, 1, type: :string, json_name: "requestId"
  field :controller_session_id, 2, type: :string, json_name: "controllerSessionId"
end

defmodule Orchard.Cluster.V1.NodeRuntimeService.Service do
  @moduledoc false

  use GRPC.Service, name: "cluster.v1.NodeRuntimeService", protoc_gen_elixir_version: "0.16.0"

  rpc :GetStatus, Orchard.Cluster.V1.StatusRequest, Orchard.Cluster.V1.StatusResponse

  rpc :EnsureModelLoaded,
      Orchard.Cluster.V1.EnsureModelLoadedRequest,
      Orchard.Cluster.V1.EnsureModelLoadedResponse

  rpc :UnloadModel, Orchard.Cluster.V1.UnloadModelRequest, Orchard.Cluster.V1.Ack

  rpc :ExecuteInference,
      Orchard.Cluster.V1.ExecuteInferenceRequest,
      stream(Orchard.Cluster.V1.InferenceEvent)

  rpc :CancelInference, Orchard.Cluster.V1.CancelInferenceRequest, Orchard.Cluster.V1.Ack
end

defmodule Orchard.Cluster.V1.NodeRuntimeService.Stub do
  @moduledoc false

  use GRPC.Stub, service: Orchard.Cluster.V1.NodeRuntimeService.Service
end
