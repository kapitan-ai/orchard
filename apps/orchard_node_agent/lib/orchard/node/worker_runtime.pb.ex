defmodule Orchard.Node.Worker.V1.WorkerStatusRequest do
  @moduledoc false

  use Protobuf,
    full_name: "orchard.worker.v1.WorkerStatusRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3
end

defmodule Orchard.Node.Worker.V1.WorkerMemoryBudgetStatus do
  @moduledoc false

  use Protobuf,
    full_name: "orchard.worker.v1.WorkerMemoryBudgetStatus",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:mode, 1, type: :string)
  field(:budget_available, 2, type: :bool, json_name: "budgetAvailable")
  field(:headroom_available, 3, type: :bool, json_name: "headroomAvailable")
  field(:status_code, 4, type: :string, json_name: "statusCode")
  field(:status_message, 5, type: :string, json_name: "statusMessage")
  field(:source, 6, type: :string)

  field(:max_recommended_working_set_size_bytes, 7,
    type: :uint64,
    json_name: "maxRecommendedWorkingSetSizeBytes"
  )

  field(:utilization, 8, type: :double)
  field(:target_working_set_bytes, 9, type: :uint64, json_name: "targetWorkingSetBytes")
  field(:overhead_bytes, 10, type: :uint64, json_name: "overheadBytes")
  field(:resident_memory_bytes, 11, type: :uint64, json_name: "residentMemoryBytes")

  field(:estimated_headroom_bytes, 12,
    type: :uint64,
    json_name: "estimatedHeadroomBytes"
  )

  field(:kv_cache_bytes_per_token, 13, type: :uint64, json_name: "kvCacheBytesPerToken")

  field(:prefill_workspace_bytes_per_token, 14,
    type: :uint64,
    json_name: "prefillWorkspaceBytesPerToken"
  )
end

defmodule Orchard.Node.Worker.V1.WorkerStatusResponse do
  @moduledoc false

  use Protobuf,
    full_name: "orchard.worker.v1.WorkerStatusResponse",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:loaded, 1, type: :bool)
  field(:active_request_count, 2, type: :uint32, json_name: "activeRequestCount")
  field(:ready, 3, type: :bool)
  field(:health_code, 4, type: :string, json_name: "healthCode")
  field(:health_message, 5, type: :string, json_name: "healthMessage")

  field(:memory_budget, 6,
    type: Orchard.Node.Worker.V1.WorkerMemoryBudgetStatus,
    json_name: "memoryBudget"
  )
end

defmodule Orchard.Node.Worker.V1.LoadModelRequest do
  @moduledoc false

  use Protobuf,
    full_name: "orchard.worker.v1.LoadModelRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:model_id, 1, type: :string, json_name: "modelId")
  field(:version, 2, type: :string)
  field(:model_path, 3, type: :string, json_name: "modelPath")
end

defmodule Orchard.Node.Worker.V1.WorkerRuntimeService.Service do
  @moduledoc false

  use GRPC.Service,
    name: "orchard.worker.v1.WorkerRuntimeService",
    protoc_gen_elixir_version: "0.16.0"

  rpc(
    :GetStatus,
    Orchard.Node.Worker.V1.WorkerStatusRequest,
    Orchard.Node.Worker.V1.WorkerStatusResponse
  )

  rpc(:LoadModel, Orchard.Node.Worker.V1.LoadModelRequest, Orchard.Cluster.V1.Ack)

  rpc(:UnloadModel, Orchard.Cluster.V1.UnloadModelRequest, Orchard.Cluster.V1.Ack)

  rpc(
    :Generate,
    Orchard.Cluster.V1.ExecuteInferenceRequest,
    stream(Orchard.Cluster.V1.InferenceEvent)
  )

  rpc(:Cancel, Orchard.Cluster.V1.CancelInferenceRequest, Orchard.Cluster.V1.Ack)
end

defmodule Orchard.Node.Worker.V1.WorkerRuntimeService.Stub do
  @moduledoc false

  use GRPC.Stub, service: Orchard.Node.Worker.V1.WorkerRuntimeService.Service
end
