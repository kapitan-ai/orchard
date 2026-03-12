defmodule Orchard.Node.Worker.V1.WorkerStatusRequest do
  @moduledoc false

  use Protobuf,
    full_name: "orchard.worker.v1.WorkerStatusRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3
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
