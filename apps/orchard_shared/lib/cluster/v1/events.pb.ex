defmodule Orchard.Cluster.V1.InferenceEvent do
  @moduledoc false

  use Protobuf,
    full_name: "cluster.v1.InferenceEvent",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  oneof(:event, 0)

  field(:accepted, 1, type: Orchard.Cluster.V1.Accepted, oneof: 0)

  field(:output_text_delta, 2,
    type: Orchard.Cluster.V1.OutputTextDelta,
    json_name: "outputTextDelta",
    oneof: 0
  )

  field(:tool_call_delta, 3,
    type: Orchard.Cluster.V1.ToolCallDelta,
    json_name: "toolCallDelta",
    oneof: 0
  )

  field(:usage, 4, type: Orchard.Cluster.V1.UsageUpdate, oneof: 0)
  field(:completed, 5, type: Orchard.Cluster.V1.Completed, oneof: 0)
  field(:failed, 6, type: Orchard.Cluster.V1.Failed, oneof: 0)
  field(:progress, 7, type: Orchard.Cluster.V1.Progress, oneof: 0)
  field(:token_delta, 8, type: Orchard.Cluster.V1.TokenDelta, json_name: "tokenDelta", oneof: 0)
end

defmodule Orchard.Cluster.V1.Accepted do
  @moduledoc false

  use Protobuf,
    full_name: "cluster.v1.Accepted",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:accepted_at_unix_ms, 1, type: :uint64, json_name: "acceptedAtUnixMs")
end

defmodule Orchard.Cluster.V1.OutputTextDelta do
  @moduledoc false

  use Protobuf,
    full_name: "cluster.v1.OutputTextDelta",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:delta, 1, type: :string)
end

defmodule Orchard.Cluster.V1.TokenDelta do
  @moduledoc false

  use Protobuf,
    full_name: "cluster.v1.TokenDelta",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:token_ids, 1, repeated: true, type: :uint32, json_name: "tokenIds")
  field(:logprobs, 2, repeated: true, type: :float)
end

defmodule Orchard.Cluster.V1.ToolCallDelta do
  @moduledoc false

  use Protobuf,
    full_name: "cluster.v1.ToolCallDelta",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:tool_call_id, 1, type: :string, json_name: "toolCallId")
  field(:delta_json, 2, type: :string, json_name: "deltaJson")
end

defmodule Orchard.Cluster.V1.UsageUpdate do
  @moduledoc false

  use Protobuf,
    full_name: "cluster.v1.UsageUpdate",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:usage, 1, type: Orchard.Cluster.V1.TokenUsage)
end

defmodule Orchard.Cluster.V1.Completed do
  @moduledoc false

  use Protobuf,
    full_name: "cluster.v1.Completed",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:finish_reason, 1,
    type: Orchard.Cluster.V1.FinishReason,
    json_name: "finishReason",
    enum: true
  )

  field(:usage, 2, type: Orchard.Cluster.V1.TokenUsage)
end

defmodule Orchard.Cluster.V1.Failed do
  @moduledoc false

  use Protobuf,
    full_name: "cluster.v1.Failed",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:code, 1, type: :string)
  field(:message, 2, type: :string)
  field(:retryable, 3, type: :bool)
end

defmodule Orchard.Cluster.V1.Progress do
  @moduledoc false

  use Protobuf,
    full_name: "cluster.v1.Progress",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:stage, 1, type: :string)
  field(:message, 2, type: :string)
end
