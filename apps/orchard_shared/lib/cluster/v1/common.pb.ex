defmodule Orchard.Cluster.V1.WorkerState do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "cluster.v1.WorkerState",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:WORKER_STATE_UNSPECIFIED, 0)
  field(:WORKER_STATE_STARTING, 1)
  field(:WORKER_STATE_IDLE, 2)
  field(:WORKER_STATE_BUSY, 3)
  field(:WORKER_STATE_STOPPING, 4)
  field(:WORKER_STATE_FAILED, 5)
  field(:WORKER_STATE_STOPPED, 6)
end

defmodule Orchard.Cluster.V1.PlacementState do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "cluster.v1.PlacementState",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:PLACEMENT_STATE_UNSPECIFIED, 0)
  field(:PLACEMENT_STATE_ABSENT, 1)
  field(:PLACEMENT_STATE_DOWNLOADING, 2)
  field(:PLACEMENT_STATE_DOWNLOADED, 3)
  field(:PLACEMENT_STATE_VERIFYING, 4)
  field(:PLACEMENT_STATE_CACHED, 5)
  field(:PLACEMENT_STATE_LOADING, 6)
  field(:PLACEMENT_STATE_LOADED, 7)
  field(:PLACEMENT_STATE_UNLOADING, 8)
  field(:PLACEMENT_STATE_EVICTED, 9)
  field(:PLACEMENT_STATE_FAILED, 10)
end

defmodule Orchard.Cluster.V1.FinishReason do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "cluster.v1.FinishReason",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:FINISH_REASON_UNSPECIFIED, 0)
  field(:FINISH_REASON_STOP, 1)
  field(:FINISH_REASON_LENGTH, 2)
end

defmodule Orchard.Cluster.V1.Ack do
  @moduledoc false

  use Protobuf, full_name: "cluster.v1.Ack", protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field(:ok, 1, type: :bool)
  field(:message, 2, type: :string)
end

defmodule Orchard.Cluster.V1.ModelRef do
  @moduledoc false

  use Protobuf,
    full_name: "cluster.v1.ModelRef",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:model_id, 1, type: :string, json_name: "modelId")
  field(:version, 2, type: :string)
end

defmodule Orchard.Cluster.V1.TokenUsage do
  @moduledoc false

  use Protobuf,
    full_name: "cluster.v1.TokenUsage",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:input_tokens, 1, type: :uint32, json_name: "inputTokens")
  field(:output_tokens, 2, type: :uint32, json_name: "outputTokens")
  field(:total_tokens, 3, type: :uint32, json_name: "totalTokens")
end

defmodule Orchard.Cluster.V1.GenerationParams do
  @moduledoc false

  use Protobuf,
    full_name: "cluster.v1.GenerationParams",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:max_output_tokens, 1, type: :uint32, json_name: "maxOutputTokens")
  field(:temperature, 2, type: :double)
  field(:top_p, 3, type: :double, json_name: "topP")
  field(:stop_sequences, 4, repeated: true, type: :string, json_name: "stopSequences")
end
