defmodule Orchard.Cluster.V1.HostEvidenceState do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "cluster.v1.HostEvidenceState",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:HOST_EVIDENCE_STATE_UNSPECIFIED, 0)
  field(:HOST_EVIDENCE_STATE_OBSERVED, 1)
  field(:HOST_EVIDENCE_STATE_ABSENT, 2)
  field(:HOST_EVIDENCE_STATE_PARTIAL, 3)
  field(:HOST_EVIDENCE_STATE_ERROR, 4)
end

defmodule Orchard.Cluster.V1.HostInventoryAuthority do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "cluster.v1.HostInventoryAuthority",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:HOST_INVENTORY_AUTHORITY_UNSPECIFIED, 0)
  field(:HOST_INVENTORY_AUTHORITY_OBSERVATION_ONLY, 1)
end

defmodule Orchard.Cluster.V1.AcceleratorVendor do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "cluster.v1.AcceleratorVendor",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:ACCELERATOR_VENDOR_UNSPECIFIED, 0)
  field(:ACCELERATOR_VENDOR_NVIDIA, 1)
  field(:ACCELERATOR_VENDOR_AMD, 2)
end

defmodule Orchard.Cluster.V1.StatusRequest do
  @moduledoc false

  use Protobuf,
    full_name: "cluster.v1.StatusRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:reasoning_observation, 1,
    type: Orchard.Cluster.V1.ReasoningObservationRequest,
    json_name: "reasoningObservation"
  )
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

defmodule Orchard.Cluster.V1.RuntimeMemoryBudget do
  @moduledoc false

  use Protobuf,
    full_name: "cluster.v1.RuntimeMemoryBudget",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:model_ref, 1, type: Orchard.Cluster.V1.ModelRef, json_name: "modelRef")
  field(:mode, 2, type: :string)
  field(:budget_available, 3, type: :bool, json_name: "budgetAvailable")
  field(:headroom_available, 4, type: :bool, json_name: "headroomAvailable")
  field(:status_code, 5, type: :string, json_name: "statusCode")
  field(:status_message, 6, type: :string, json_name: "statusMessage")
  field(:source, 7, type: :string)

  field(:max_recommended_working_set_size_bytes, 8,
    type: :uint64,
    json_name: "maxRecommendedWorkingSetSizeBytes"
  )

  field(:utilization, 9, type: :double)
  field(:target_working_set_bytes, 10, type: :uint64, json_name: "targetWorkingSetBytes")
  field(:overhead_bytes, 11, type: :uint64, json_name: "overheadBytes")
  field(:resident_memory_bytes, 12, type: :uint64, json_name: "residentMemoryBytes")
  field(:estimated_headroom_bytes, 13, type: :uint64, json_name: "estimatedHeadroomBytes")
  field(:kv_cache_bytes_per_token, 14, type: :uint64, json_name: "kvCacheBytesPerToken")

  field(:prefill_workspace_bytes_per_token, 15,
    type: :uint64,
    json_name: "prefillWorkspaceBytesPerToken"
  )

  field(:recommended_context_tokens, 16, type: :uint64, json_name: "recommendedContextTokens")
end

defmodule Orchard.Cluster.V1.RuntimePrefixCacheStatus do
  @moduledoc false

  use Protobuf,
    full_name: "cluster.v1.RuntimePrefixCacheStatus",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:model_ref, 1, type: Orchard.Cluster.V1.ModelRef, json_name: "modelRef")
  field(:implementation, 2, type: :string)
  field(:enabled, 3, type: :bool)
  field(:entry_count, 4, type: :uint32, json_name: "entryCount")
  field(:total_bytes, 5, type: :uint64, json_name: "totalBytes")
  field(:hits, 6, type: :uint64)
  field(:misses, 7, type: :uint64)
  field(:failures, 8, type: :uint64)
  field(:stores, 9, type: :uint64)
  field(:evictions, 10, type: :uint64)
  field(:configured_max_entries, 11, type: :uint32, json_name: "configuredMaxEntries")
  field(:configured_max_bytes, 12, type: :uint64, json_name: "configuredMaxBytes")
  field(:status_code, 13, type: :string, json_name: "statusCode")
  field(:status_message, 14, type: :string, json_name: "statusMessage")
  field(:session_started_unix_ms, 15, type: :uint64, json_name: "sessionStartedUnixMs")

  field(:prefix_cache_fingerprints, 16,
    repeated: true,
    type: :string,
    json_name: "prefixCacheFingerprints"
  )
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

defmodule Orchard.Cluster.V1.RuntimeModelPlacement do
  @moduledoc false

  use Protobuf,
    full_name: "cluster.v1.RuntimeModelPlacement",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:model_ref, 1, type: Orchard.Cluster.V1.ModelRef, json_name: "modelRef")
  field(:active_request_count, 2, type: :uint32, json_name: "activeRequestCount")
  field(:max_concurrency, 3, type: :uint32, json_name: "maxConcurrency")
end

defmodule Orchard.Cluster.V1.WorkerCrashCounter do
  @moduledoc false

  use Protobuf,
    full_name: "cluster.v1.WorkerCrashCounter",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:model_id, 1, type: :string, json_name: "modelId")
  field(:count, 2, type: :uint64)
  field(:counter_version, 3, type: :string, json_name: "counterVersion")
end

defmodule Orchard.Cluster.V1.HostEvidence do
  @moduledoc false

  use Protobuf,
    full_name: "cluster.v1.HostEvidence",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:state, 1, type: Orchard.Cluster.V1.HostEvidenceState, enum: true)
  field(:source, 2, type: :string)
  field(:observed_at_unix_ms, 3, type: :uint64, json_name: "observedAtUnixMs")
  field(:error_code, 4, type: :string, json_name: "errorCode")
end

defmodule Orchard.Cluster.V1.HostCpuObservation do
  @moduledoc false

  use Protobuf,
    full_name: "cluster.v1.HostCpuObservation",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:evidence, 1, type: Orchard.Cluster.V1.HostEvidence)
  field(:architecture, 2, type: :string)
  field(:logical_processor_count, 3, type: :uint32, json_name: "logicalProcessorCount")
  field(:core_count, 4, type: :uint32, json_name: "coreCount")
  field(:socket_count, 5, type: :uint32, json_name: "socketCount")
  field(:vendor_id, 6, type: :string, json_name: "vendorId")
  field(:model_name, 7, type: :string, json_name: "modelName")
end

defmodule Orchard.Cluster.V1.HostMemoryObservation do
  @moduledoc false

  use Protobuf,
    full_name: "cluster.v1.HostMemoryObservation",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:evidence, 1, type: Orchard.Cluster.V1.HostEvidence)
  field(:physical_bytes, 2, type: :uint64, json_name: "physicalBytes")
  field(:available_bytes, 3, type: :uint64, json_name: "availableBytes")
  field(:swap_total_bytes, 4, type: :uint64, json_name: "swapTotalBytes")
  field(:swap_free_bytes, 5, type: :uint64, json_name: "swapFreeBytes")
end

defmodule Orchard.Cluster.V1.HostDiskObservation do
  @moduledoc false

  use Protobuf,
    full_name: "cluster.v1.HostDiskObservation",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:evidence, 1, type: Orchard.Cluster.V1.HostEvidence)
  field(:mount_point, 2, type: :string, json_name: "mountPoint")
  field(:filesystem, 3, type: :string)
  field(:total_bytes, 4, type: :uint64, json_name: "totalBytes")
  field(:available_bytes, 5, type: :uint64, json_name: "availableBytes")
end

defmodule Orchard.Cluster.V1.HostPlatformObservation do
  @moduledoc false

  use Protobuf,
    full_name: "cluster.v1.HostPlatformObservation",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:evidence, 1, type: Orchard.Cluster.V1.HostEvidence)
  field(:os_id, 2, type: :string, json_name: "osId")
  field(:os_name, 3, type: :string, json_name: "osName")
  field(:os_version, 4, type: :string, json_name: "osVersion")
  field(:kernel_release, 5, type: :string, json_name: "kernelRelease")
  field(:architecture, 6, type: :string)
  field(:libc_name, 7, type: :string, json_name: "libcName")
  field(:libc_version, 8, type: :string, json_name: "libcVersion")
  field(:systemd_version, 9, type: :string, json_name: "systemdVersion")
  field(:cgroup_mode, 10, type: :string, json_name: "cgroupMode")
end

defmodule Orchard.Cluster.V1.HostNetworkAddressObservation do
  @moduledoc false

  use Protobuf,
    full_name: "cluster.v1.HostNetworkAddressObservation",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:family, 1, type: :string)
  field(:address, 2, type: :string)
  field(:prefix_length, 3, type: :uint32, json_name: "prefixLength")
  field(:scope, 4, type: :string)
end

defmodule Orchard.Cluster.V1.HostNetworkInterfaceObservation do
  @moduledoc false

  use Protobuf,
    full_name: "cluster.v1.HostNetworkInterfaceObservation",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:name, 1, type: :string)
  field(:index, 2, type: :uint32)
  field(:oper_state, 3, type: :string, json_name: "operState")
  field(:mtu, 4, type: :uint32)
  field(:link_type, 5, type: :string, json_name: "linkType")
  field(:hardware_address, 6, type: :string, json_name: "hardwareAddress")
  field(:addresses, 7, repeated: true, type: Orchard.Cluster.V1.HostNetworkAddressObservation)
end

defmodule Orchard.Cluster.V1.HostNetworkObservation do
  @moduledoc false

  use Protobuf,
    full_name: "cluster.v1.HostNetworkObservation",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:evidence, 1, type: Orchard.Cluster.V1.HostEvidence)
  field(:interfaces, 2, repeated: true, type: Orchard.Cluster.V1.HostNetworkInterfaceObservation)
end

defmodule Orchard.Cluster.V1.AcceleratorObservation do
  @moduledoc false

  use Protobuf,
    full_name: "cluster.v1.AcceleratorObservation",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:evidence, 1, type: Orchard.Cluster.V1.HostEvidence)
  field(:vendor, 2, type: Orchard.Cluster.V1.AcceleratorVendor, enum: true)
  field(:stable_id, 3, type: :string, json_name: "stableId")
  field(:identity_kind, 4, type: :string, json_name: "identityKind")
  field(:device_ordinal, 5, type: :uint32, json_name: "deviceOrdinal")
  field(:pci_address, 6, type: :string, json_name: "pciAddress")
  field(:numa_node, 7, type: :string, json_name: "numaNode")
  field(:model_name, 8, type: :string, json_name: "modelName")
  field(:memory_total_bytes, 9, type: :uint64, json_name: "memoryTotalBytes")
  field(:driver_version, 10, type: :string, json_name: "driverVersion")
end

defmodule Orchard.Cluster.V1.AcceleratorRuntimeObservation do
  @moduledoc false

  use Protobuf,
    full_name: "cluster.v1.AcceleratorRuntimeObservation",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:evidence, 1, type: Orchard.Cluster.V1.HostEvidence)
  field(:name, 2, type: :string)
  field(:version, 3, type: :string)
end

defmodule Orchard.Cluster.V1.AcceleratorProviderObservation do
  @moduledoc false

  use Protobuf,
    full_name: "cluster.v1.AcceleratorProviderObservation",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:evidence, 1, type: Orchard.Cluster.V1.HostEvidence)
  field(:vendor, 2, type: Orchard.Cluster.V1.AcceleratorVendor, enum: true)
  field(:devices, 3, repeated: true, type: Orchard.Cluster.V1.AcceleratorObservation)
  field(:visibility_filter, 4, type: :string, json_name: "visibilityFilter")
  field(:runtime, 5, type: Orchard.Cluster.V1.AcceleratorRuntimeObservation)
end

defmodule Orchard.Cluster.V1.HostInventoryObservation do
  @moduledoc false

  use Protobuf,
    full_name: "cluster.v1.HostInventoryObservation",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:schema_version, 1, type: :uint32, json_name: "schemaVersion")
  field(:observed_at_unix_ms, 2, type: :uint64, json_name: "observedAtUnixMs")
  field(:authority, 3, type: Orchard.Cluster.V1.HostInventoryAuthority, enum: true)
  field(:cpu, 4, type: Orchard.Cluster.V1.HostCpuObservation)
  field(:memory, 5, type: Orchard.Cluster.V1.HostMemoryObservation)
  field(:disk, 6, type: Orchard.Cluster.V1.HostDiskObservation)
  field(:platform, 7, type: Orchard.Cluster.V1.HostPlatformObservation)
  field(:network, 8, type: Orchard.Cluster.V1.HostNetworkObservation)

  field(:accelerator_providers, 9,
    repeated: true,
    type: Orchard.Cluster.V1.AcceleratorProviderObservation,
    json_name: "acceleratorProviders"
  )
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

  field(:runtime_memory_budgets, 8,
    repeated: true,
    type: Orchard.Cluster.V1.RuntimeMemoryBudget,
    json_name: "runtimeMemoryBudgets"
  )

  field(:runtime_prefix_cache_statuses, 9,
    repeated: true,
    type: Orchard.Cluster.V1.RuntimePrefixCacheStatus,
    json_name: "runtimePrefixCacheStatuses"
  )

  field(:supports_prompt_token_ids, 10, type: :bool, json_name: "supportsPromptTokenIds")

  field(:runtime_model_placements, 11,
    repeated: true,
    type: Orchard.Cluster.V1.RuntimeModelPlacement,
    json_name: "runtimeModelPlacements"
  )

  field(:max_concurrency, 12, type: :uint32, json_name: "maxConcurrency")

  field(:worker_crash_counters, 13,
    repeated: true,
    type: Orchard.Cluster.V1.WorkerCrashCounter,
    json_name: "workerCrashCounters"
  )

  field(:reasoning_observation, 14,
    type: Orchard.Cluster.V1.ReasoningLiveObservation,
    json_name: "reasoningObservation"
  )

  field(:host_inventory, 15,
    type: Orchard.Cluster.V1.HostInventoryObservation,
    json_name: "hostInventory"
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

  field(:worker_supports_prompt_token_ids, 6,
    type: :bool,
    json_name: "workerSupportsPromptTokenIds"
  )

  field(:placement_capacity, 7,
    proto3_optional: true,
    type: Orchard.Cluster.V1.RuntimeModelPlacement,
    json_name: "placementCapacity"
  )
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

defmodule Orchard.Cluster.V1.ScorePrefixCacheRequest do
  @moduledoc false

  use Protobuf,
    full_name: "cluster.v1.ScorePrefixCacheRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:request_id, 1, type: :string, json_name: "requestId")
  field(:controller_session_id, 2, type: :string, json_name: "controllerSessionId")
  field(:model_ref, 3, type: Orchard.Cluster.V1.ModelRef, json_name: "modelRef")
  field(:cache_affinity_fingerprint, 4, type: :string, json_name: "cacheAffinityFingerprint")
  field(:deadline_unix_ms, 5, type: :uint64, json_name: "deadlineUnixMs")
end

defmodule Orchard.Cluster.V1.ScorePrefixCacheResponse do
  @moduledoc false

  use Protobuf,
    full_name: "cluster.v1.ScorePrefixCacheResponse",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:status_code, 1, type: :string, json_name: "statusCode")
  field(:status_message, 2, type: :string, json_name: "statusMessage")
  field(:resident_fingerprint_match, 3, type: :bool, json_name: "residentFingerprintMatch")
  field(:score_tier, 4, type: :string, json_name: "scoreTier")
  field(:session_started_unix_ms, 5, type: :uint64, json_name: "sessionStartedUnixMs")
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
  field(:cache_affinity_fingerprint, 10, type: :string, json_name: "cacheAffinityFingerprint")
  field(:prompt_token_ids, 11, repeated: true, type: :uint32, json_name: "promptTokenIds")
  field(:return_token_ids, 12, type: :bool, json_name: "returnTokenIds")
  field(:return_logprobs, 13, type: :bool, json_name: "returnLogprobs")

  field(:preparation_redemption, 14,
    type: Orchard.Cluster.V1.PreparationRedemption,
    json_name: "preparationRedemption"
  )

  field(:tensorfold_history_projection_json, 15,
    type: :bytes,
    json_name: "tensorfoldHistoryProjectionJson"
  )
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

  rpc(
    :ScorePrefixCache,
    Orchard.Cluster.V1.ScorePrefixCacheRequest,
    Orchard.Cluster.V1.ScorePrefixCacheResponse
  )
end

defmodule Orchard.Cluster.V1.NodeRuntimeService.Stub do
  @moduledoc false

  use GRPC.Stub, service: Orchard.Cluster.V1.NodeRuntimeService.Service
end
