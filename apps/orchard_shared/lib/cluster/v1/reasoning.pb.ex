defmodule Orchard.Cluster.V1.ReasoningEffort do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "cluster.v1.ReasoningEffort",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:REASONING_EFFORT_UNSPECIFIED, 0)
  field(:REASONING_EFFORT_LOW, 1)
  field(:REASONING_EFFORT_MEDIUM, 2)
  field(:REASONING_EFFORT_HIGH, 3)
end

defmodule Orchard.Cluster.V1.ReasoningEffortSelection do
  @moduledoc false

  use Protobuf,
    full_name: "cluster.v1.ReasoningEffortSelection",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:effort, 1, type: Orchard.Cluster.V1.ReasoningEffort, enum: true)
end

defmodule Orchard.Cluster.V1.WorkerLoadedBinding do
  @moduledoc false

  use Protobuf,
    full_name: "cluster.v1.WorkerLoadedBinding",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:model_id, 1, type: :string, json_name: "modelId")
  field(:model_version, 2, type: :string, json_name: "modelVersion")
  field(:artifact_digest, 3, type: :string, json_name: "artifactDigest")
  field(:selected_profile_id, 4, type: :string, json_name: "selectedProfileId")
end

defmodule Orchard.Cluster.V1.NegotiatedReasoningTuple do
  @moduledoc false

  use Protobuf,
    full_name: "cluster.v1.NegotiatedReasoningTuple",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:generation_policy, 1, type: :string, json_name: "generationPolicy")
  field(:projection, 2, type: :string)

  field(:reasoning_effort, 3,
    type: Orchard.Cluster.V1.ReasoningEffortSelection,
    json_name: "reasoningEffort"
  )

  field(:model_artifact_digest, 4, type: :string, json_name: "modelArtifactDigest")
  field(:chat_template_digest, 5, type: :string, json_name: "chatTemplateDigest")
  field(:render_contract, 6, type: :string, json_name: "renderContract")
  field(:render_contract_version, 7, type: :string, json_name: "renderContractVersion")
  field(:parser_family, 8, type: :string, json_name: "parserFamily")
  field(:parser_version, 9, type: :string, json_name: "parserVersion")
  field(:runtime_contract_version, 10, type: :string, json_name: "runtimeContractVersion")
  field(:event_binding_version, 11, type: :string, json_name: "eventBindingVersion")
end

defmodule Orchard.Cluster.V1.ReasoningEvidenceEnvelope do
  @moduledoc false

  use Protobuf,
    full_name: "cluster.v1.ReasoningEvidenceEnvelope",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:tuples, 1, repeated: true, type: Orchard.Cluster.V1.NegotiatedReasoningTuple)
  field(:loaded_instance_id, 2, type: :bytes, json_name: "loadedInstanceId")
end

defmodule Orchard.Cluster.V1.ReasoningObservationRequest do
  @moduledoc false

  use Protobuf,
    full_name: "cluster.v1.ReasoningObservationRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:model_ref, 1, type: Orchard.Cluster.V1.ModelRef, json_name: "modelRef")
end

defmodule Orchard.Cluster.V1.ReasoningEvidence do
  @moduledoc false

  use Protobuf,
    full_name: "cluster.v1.ReasoningEvidence",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:loaded_binding, 1,
    type: Orchard.Cluster.V1.WorkerLoadedBinding,
    json_name: "loadedBinding"
  )

  field(:envelope, 2, type: Orchard.Cluster.V1.ReasoningEvidenceEnvelope)
  field(:service_incarnation, 3, type: :string, json_name: "serviceIncarnation")
  field(:remaining_freshness_ms, 4, type: :uint64, json_name: "remainingFreshnessMs")
end

defmodule Orchard.Cluster.V1.ReasoningNonAdvertising do
  @moduledoc false

  use Protobuf,
    full_name: "cluster.v1.ReasoningNonAdvertising",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3
end

defmodule Orchard.Cluster.V1.ReasoningUnknown do
  @moduledoc false

  use Protobuf,
    full_name: "cluster.v1.ReasoningUnknown",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3
end

defmodule Orchard.Cluster.V1.ReasoningLiveObservation do
  @moduledoc false

  use Protobuf,
    full_name: "cluster.v1.ReasoningLiveObservation",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  oneof(:result, 0)

  field(:evidence, 1, type: Orchard.Cluster.V1.ReasoningEvidence, oneof: 0)

  field(:non_advertising, 2,
    type: Orchard.Cluster.V1.ReasoningNonAdvertising,
    json_name: "nonAdvertising",
    oneof: 0
  )

  field(:unknown, 3, type: Orchard.Cluster.V1.ReasoningUnknown, oneof: 0)
end

defmodule Orchard.Cluster.V1.FrozenExecutionInput do
  @moduledoc false

  use Protobuf,
    full_name: "cluster.v1.FrozenExecutionInput",
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
  field(:cache_affinity_fingerprint, 10, type: :string, json_name: "cacheAffinityFingerprint")
  field(:prompt_token_ids, 11, repeated: true, type: :uint32, json_name: "promptTokenIds")
  field(:return_token_ids, 12, type: :bool, json_name: "returnTokenIds")
  field(:return_logprobs, 13, type: :bool, json_name: "returnLogprobs")
end

defmodule Orchard.Cluster.V1.PrepareInferenceRequest do
  @moduledoc false

  use Protobuf,
    full_name: "cluster.v1.PrepareInferenceRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:input, 1, type: Orchard.Cluster.V1.FrozenExecutionInput)
  field(:tuple, 2, type: Orchard.Cluster.V1.NegotiatedReasoningTuple)

  field(:expected_binding, 3,
    type: Orchard.Cluster.V1.WorkerLoadedBinding,
    json_name: "expectedBinding"
  )

  field(:expected_service_incarnation, 4, type: :string, json_name: "expectedServiceIncarnation")
  field(:expected_loaded_instance_id, 5, type: :bytes, json_name: "expectedLoadedInstanceId")
end

defmodule Orchard.Cluster.V1.PrepareInferenceProof do
  @moduledoc false

  use Protobuf,
    full_name: "cluster.v1.PrepareInferenceProof",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:request_id, 1, type: :string, json_name: "requestId")
  field(:controller_session_id, 2, type: :string, json_name: "controllerSessionId")
  field(:tuple, 3, type: Orchard.Cluster.V1.NegotiatedReasoningTuple)

  field(:actual_binding, 4,
    type: Orchard.Cluster.V1.WorkerLoadedBinding,
    json_name: "actualBinding"
  )

  field(:service_incarnation, 5, type: :string, json_name: "serviceIncarnation")
  field(:loaded_instance_id, 6, type: :bytes, json_name: "loadedInstanceId")
end

defmodule Orchard.Cluster.V1.PreparationRedemption do
  @moduledoc false

  use Protobuf,
    full_name: "cluster.v1.PreparationRedemption",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:authorization, 1, type: :bytes)
end

defmodule Orchard.Cluster.V1.PrepareInferenceResponse do
  @moduledoc false

  use Protobuf,
    full_name: "cluster.v1.PrepareInferenceResponse",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:proof, 1, type: Orchard.Cluster.V1.PrepareInferenceProof)
  field(:authorization, 2, type: :bytes)
  field(:authorization_ttl_ms, 3, type: :uint64, json_name: "authorizationTtlMs")
end
