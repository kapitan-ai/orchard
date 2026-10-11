import tomllib
from hashlib import sha256
from pathlib import Path

from google.protobuf import descriptor_pb2, descriptor_pool, message_factory, unknown_fields

from orchard_worker_mlx.generated.cluster.v1 import (
    common_pb2,
    events_pb2,
    reasoning_pb2,
    runtime_pb2,
)
from orchard_worker_mlx.generated.orchard.worker.v1 import (
    worker_runtime_pb2,
    worker_runtime_pb2_grpc,
)

REPO_ROOT = Path(__file__).resolve().parents[3]
PROTO_ROOT = REPO_ROOT / "proto" / "orchard" / "worker" / "v1"
CANONICAL_PROTO = PROTO_ROOT / "worker_runtime.proto"
LEGACY_PROTO = (
    REPO_ROOT
    / "native"
    / "orchard_worker_mlx"
    / "proto"
    / "orchard"
    / "worker"
    / "v1"
    / "worker_runtime.proto"
)
# N-1 golden: the Worker Runtime descriptor set from the merge base with main
# before negotiated reasoning (126eb1bc). Messages built from it decode across a
# real schema revision rather than the current bindings.
N_MINUS_1_DESCRIPTOR = PROTO_ROOT / "fixtures" / "n_minus_1" / "worker_runtime.descriptor.pb"
N_MINUS_1_DESCRIPTOR_SHA256 = "6e51e68783dc7e5768d80c559616feaea3df1797ab38a3d5c7c4ef0e94fc27d9"
EXPECTED_DESCRIPTOR_SET_SHA256 = "44e5b8e359730a95b343a78077b86b628b8690d012c21f19f070502958c52ca4"
EXPECTED_DESCRIPTOR_FILES = {
    "cluster/v1/common.proto",
    "cluster/v1/events.proto",
    "cluster/v1/reasoning.proto",
    "cluster/v1/runtime.proto",
    "orchard/worker/v1/worker_runtime.proto",
}

EXPECTED_MESSAGES = {
    "WorkerStatusRequest": [
        (
            "reasoning_observation",
            1,
            "TYPE_MESSAGE",
            False,
            ".cluster.v1.ReasoningObservationRequest",
        ),
    ],
    "WorkerMemoryBudgetStatus": [
        ("mode", 1, "TYPE_STRING", False, None),
        ("budget_available", 2, "TYPE_BOOL", False, None),
        ("headroom_available", 3, "TYPE_BOOL", False, None),
        ("status_code", 4, "TYPE_STRING", False, None),
        ("status_message", 5, "TYPE_STRING", False, None),
        ("source", 6, "TYPE_STRING", False, None),
        ("max_recommended_working_set_size_bytes", 7, "TYPE_UINT64", False, None),
        ("utilization", 8, "TYPE_DOUBLE", False, None),
        ("target_working_set_bytes", 9, "TYPE_UINT64", False, None),
        ("overhead_bytes", 10, "TYPE_UINT64", False, None),
        ("resident_memory_bytes", 11, "TYPE_UINT64", False, None),
        ("estimated_headroom_bytes", 12, "TYPE_UINT64", False, None),
        ("kv_cache_bytes_per_token", 13, "TYPE_UINT64", False, None),
        ("prefill_workspace_bytes_per_token", 14, "TYPE_UINT64", False, None),
        ("recommended_context_tokens", 15, "TYPE_UINT64", False, None),
    ],
    "WorkerPrefixCacheStatus": [
        ("implementation", 1, "TYPE_STRING", False, None),
        ("enabled", 2, "TYPE_BOOL", False, None),
        ("entry_count", 3, "TYPE_UINT32", False, None),
        ("total_bytes", 4, "TYPE_UINT64", False, None),
        ("hits", 5, "TYPE_UINT64", False, None),
        ("misses", 6, "TYPE_UINT64", False, None),
        ("failures", 7, "TYPE_UINT64", False, None),
        ("stores", 8, "TYPE_UINT64", False, None),
        ("evictions", 9, "TYPE_UINT64", False, None),
        ("configured_max_entries", 10, "TYPE_UINT32", False, None),
        ("configured_max_bytes", 11, "TYPE_UINT64", False, None),
        ("status_code", 12, "TYPE_STRING", False, None),
        ("status_message", 13, "TYPE_STRING", False, None),
        ("session_started_unix_ms", 14, "TYPE_UINT64", False, None),
        ("prefix_cache_fingerprints", 15, "TYPE_STRING", True, None),
    ],
    "WorkerCapabilityProfile": [
        ("profile_id", 1, "TYPE_STRING", False, None),
        ("artifact_format", 2, "TYPE_STRING", False, None),
        ("acceleration", 3, "TYPE_STRING", False, None),
        ("device_binding", 4, "TYPE_STRING", False, None),
        ("memory_semantics", 5, "TYPE_STRING", False, None),
        ("max_concurrency", 6, "TYPE_UINT32", False, None),
        ("runtime_features", 7, "TYPE_STRING", True, None),
        ("cache_capabilities", 8, "TYPE_STRING", True, None),
    ],
    "WorkerCapabilities": [
        ("protocol_major", 1, "TYPE_UINT32", False, None),
        ("protocol_minor", 2, "TYPE_UINT32", False, None),
        ("provider_id", 3, "TYPE_STRING", False, None),
        ("provider_version", 4, "TYPE_STRING", False, None),
        ("implementation_version", 5, "TYPE_STRING", False, None),
        ("service_incarnation", 6, "TYPE_STRING", False, None),
        (
            "profiles",
            7,
            "TYPE_MESSAGE",
            True,
            ".orchard.worker.v1.WorkerCapabilityProfile",
        ),
        (
            "loaded_binding",
            8,
            "TYPE_MESSAGE",
            False,
            ".cluster.v1.WorkerLoadedBinding",
        ),
        (
            "reasoning_evidence",
            9,
            "TYPE_MESSAGE",
            False,
            ".cluster.v1.ReasoningEvidenceEnvelope",
        ),
    ],
    "WorkerStatusResponse": [
        ("loaded", 1, "TYPE_BOOL", False, None),
        ("active_request_count", 2, "TYPE_UINT32", False, None),
        ("ready", 3, "TYPE_BOOL", False, None),
        ("health_code", 4, "TYPE_STRING", False, None),
        ("health_message", 5, "TYPE_STRING", False, None),
        (
            "memory_budget",
            6,
            "TYPE_MESSAGE",
            False,
            ".orchard.worker.v1.WorkerMemoryBudgetStatus",
        ),
        (
            "prefix_cache",
            7,
            "TYPE_MESSAGE",
            False,
            ".orchard.worker.v1.WorkerPrefixCacheStatus",
        ),
        ("supports_prompt_token_ids", 8, "TYPE_BOOL", False, None),
        ("max_concurrency", 9, "TYPE_UINT32", False, None),
        (
            "capabilities",
            10,
            "TYPE_MESSAGE",
            False,
            ".orchard.worker.v1.WorkerCapabilities",
        ),
        ("tensorfold_profile_admission_json", 11, "TYPE_BYTES", False, None),
    ],
    "LoadModelRequest": [
        ("model_id", 1, "TYPE_STRING", False, None),
        ("version", 2, "TYPE_STRING", False, None),
        ("model_path", 3, "TYPE_STRING", False, None),
    ],
}

EXPECTED_RESERVED_RANGES = {message_name: [] for message_name in EXPECTED_MESSAGES}

EXPECTED_RPCS = [
    (
        "GetStatus",
        ".orchard.worker.v1.WorkerStatusRequest",
        ".orchard.worker.v1.WorkerStatusResponse",
        False,
        False,
    ),
    (
        "LoadModel",
        ".orchard.worker.v1.LoadModelRequest",
        ".cluster.v1.Ack",
        False,
        False,
    ),
    (
        "UnloadModel",
        ".cluster.v1.UnloadModelRequest",
        ".cluster.v1.Ack",
        False,
        False,
    ),
    (
        "Generate",
        ".cluster.v1.ExecuteInferenceRequest",
        ".cluster.v1.InferenceEvent",
        False,
        True,
    ),
    (
        "Cancel",
        ".cluster.v1.CancelInferenceRequest",
        ".cluster.v1.Ack",
        False,
        False,
    ),
    (
        "PrepareInference",
        ".cluster.v1.PrepareInferenceRequest",
        ".cluster.v1.PrepareInferenceResponse",
        False,
        False,
    ),
    (
        "ScorePrefixCache",
        ".cluster.v1.ScorePrefixCacheRequest",
        ".cluster.v1.ScorePrefixCacheResponse",
        False,
        False,
    ),
]


def _field_signature(field: descriptor_pb2.FieldDescriptorProto) -> tuple:
    return (
        field.name,
        field.number,
        descriptor_pb2.FieldDescriptorProto.Type.Name(field.type),
        descriptor_pb2.FieldDescriptorProto.Label.Name(field.label),
        field.type_name or None,
        field.proto3_optional,
        field.oneof_index if field.HasField("oneof_index") else None,
    )


def _descriptor_set() -> descriptor_pb2.FileDescriptorSet:
    return descriptor_pb2.FileDescriptorSet.FromString(
        (PROTO_ROOT / "worker_runtime.descriptor.pb").read_bytes()
    )


def _worker_descriptor(
    descriptor_set: descriptor_pb2.FileDescriptorSet,
) -> descriptor_pb2.FileDescriptorProto:
    return next(
        descriptor
        for descriptor in descriptor_set.file
        if descriptor.name == "orchard/worker/v1/worker_runtime.proto"
    )


def _file_descriptor(
    descriptor_set: descriptor_pb2.FileDescriptorSet, name: str
) -> descriptor_pb2.FileDescriptorProto:
    return next(descriptor for descriptor in descriptor_set.file if descriptor.name == name)


def _message_descriptor(
    descriptor: descriptor_pb2.FileDescriptorProto, name: str
) -> descriptor_pb2.DescriptorProto:
    return next(message for message in descriptor.message_type if message.name == name)


def _python_worker_status_fixture() -> worker_runtime_pb2.WorkerStatusResponse:
    return worker_runtime_pb2.WorkerStatusResponse(
        loaded=True,
        active_request_count=2,
        ready=True,
        health_code="ok",
        health_message="ready",
        memory_budget=worker_runtime_pb2.WorkerMemoryBudgetStatus(
            mode="observe",
            budget_available=True,
            headroom_available=True,
            status_code="ok",
            status_message="within budget",
            source="mlx-device-info",
            max_recommended_working_set_size_bytes=34_359_738_368,
            utilization=0.625,
            target_working_set_bytes=21_474_836_480,
            overhead_bytes=1_073_741_824,
            resident_memory_bytes=17_179_869_184,
            estimated_headroom_bytes=12_884_901_888,
            kv_cache_bytes_per_token=262_144,
            prefill_workspace_bytes_per_token=524_288,
            recommended_context_tokens=32_768,
        ),
        prefix_cache=worker_runtime_pb2.WorkerPrefixCacheStatus(
            implementation="mlx-lm",
            enabled=True,
            entry_count=3,
            total_bytes=4_194_304,
            hits=8,
            misses=2,
            failures=1,
            stores=4,
            evictions=1,
            configured_max_entries=16,
            configured_max_bytes=67_108_864,
            status_code="ok",
            status_message="available",
            session_started_unix_ms=1_788_245_442_000,
            prefix_cache_fingerprints=["sha256:alpha", "sha256:beta"],
        ),
        supports_prompt_token_ids=True,
        max_concurrency=4,
    )


def _worker_capabilities_fixture() -> worker_runtime_pb2.WorkerCapabilities:
    return worker_runtime_pb2.WorkerCapabilities(
        protocol_major=1,
        protocol_minor=1,
        provider_id="mlx",
        provider_version="0.31.2",
        implementation_version="0.1.0",
        service_incarnation="0123456789abcdef0123456789abcdef",
        profiles=[
            worker_runtime_pb2.WorkerCapabilityProfile(
                profile_id="mlx-metal-unified-default",
                artifact_format="safetensors",
                acceleration="metal",
                device_binding="apple_gpu_0",
                memory_semantics="unified",
                max_concurrency=4,
                runtime_features=["prompt_token_ids", "streaming"],
                cache_capabilities=["prefix_cache"],
            ),
            worker_runtime_pb2.WorkerCapabilityProfile(
                profile_id="mlx-metal-unified-serial",
                artifact_format="safetensors",
                acceleration="metal",
                device_binding="apple_gpu_0",
                memory_semantics="unified",
                max_concurrency=1,
                runtime_features=["streaming"],
                cache_capabilities=[],
            ),
        ],
    )


def _reasoning_tuple(
    effort: reasoning_pb2.ReasoningEffortSelection | None = None,
) -> reasoning_pb2.NegotiatedReasoningTuple:
    message = reasoning_pb2.NegotiatedReasoningTuple(
        generation_policy="enabled",
        projection="final_only",
        model_artifact_digest="sha256:artifact",
        chat_template_digest="sha256:template",
        render_contract="orchard_chat",
        render_contract_version="1",
        parser_family="tagged_pair",
        parser_version="1",
        runtime_contract_version="1",
        event_binding_version="1",
    )
    if effort is not None:
        message.reasoning_effort.CopyFrom(effort)
    return message


def _loaded_binding() -> reasoning_pb2.WorkerLoadedBinding:
    return reasoning_pb2.WorkerLoadedBinding(
        model_id="mlx-community/Qwen3-4B",
        model_version="sha256:orchard-fixture",
        artifact_digest="sha256:artifact",
        selected_profile_id="mlx-metal-unified-default",
    )


def _reasoning_capabilities_fixture() -> worker_runtime_pb2.WorkerCapabilities:
    message = _worker_capabilities_fixture()
    message.loaded_binding.CopyFrom(_loaded_binding())
    message.reasoning_evidence.CopyFrom(
        reasoning_pb2.ReasoningEvidenceEnvelope(
            tuples=[
                _reasoning_tuple(
                    reasoning_pb2.ReasoningEffortSelection(
                        effort=reasoning_pb2.REASONING_EFFORT_LOW
                    )
                )
            ],
            loaded_instance_id=bytes(range(16)),
        )
    )
    return message


def _n_minus_1_class(full_name: str) -> type:
    pool = descriptor_pool.DescriptorPool()
    for file in descriptor_pb2.FileDescriptorSet.FromString(N_MINUS_1_DESCRIPTOR.read_bytes()).file:
        pool.Add(file)
    return message_factory.GetMessageClass(pool.FindMessageTypeByName(full_name))


def _unknown(message) -> list[tuple[int, int, bytes]]:
    return [
        (field.field_number, field.wire_type, field.data)
        for field in unknown_fields.UnknownFieldSet(message)
    ]


def _prepare_inference_request() -> reasoning_pb2.PrepareInferenceRequest:
    # Wire coverage only; mirrors scripts/support/worker-runtime-preparation-fixture.exs.
    # It sets return_token_ids and return_logprobs, which negotiated execution
    # rejects, and its cache_affinity_fingerprint is not the hmac-sha256 form.
    # Later slices must not reuse it as a happy-path preparation.
    return reasoning_pb2.PrepareInferenceRequest(
        input=reasoning_pb2.FrozenExecutionInput(
            request_id="request-327",
            controller_session_id="controller-session",
            model_id="mlx-community/Qwen3-4B",
            version="sha256:orchard-fixture",
            rendered_prompt_utf8=b"prompt",
            input_tokens=2,
            params=common_pb2.GenerationParams(
                max_output_tokens=257,
                temperature=0.25,
                top_p=0.875,
                stop_sequences=["<stop-a>", "<stop-b>"],
                tools_json=b'[{"type":"function","name":"lookup"}]',
                tool_choice_json=b'{"type":"function","name":"lookup"}',
            ),
            deadline_unix_ms=1_800_000_000_000,
            metadata_json=b'{"tenant":"fixture"}',
            cache_affinity_fingerprint="sha256:cache-affinity",
            prompt_token_ids=[7, 11, 42],
            return_token_ids=True,
            return_logprobs=True,
        ),
        tuple=_reasoning_tuple(),
        expected_binding=_loaded_binding(),
        expected_service_incarnation="0123456789abcdef0123456789abcdef",
        expected_loaded_instance_id=bytes(range(16)),
    )


def _python_worker_status_capabilities_fixture() -> worker_runtime_pb2.WorkerStatusResponse:
    message = _python_worker_status_fixture()
    message.capabilities.CopyFrom(_worker_capabilities_fixture())
    return message


def _python_worker_status_reasoning_fixture() -> worker_runtime_pb2.WorkerStatusResponse:
    message = _python_worker_status_fixture()
    message.capabilities.CopyFrom(_reasoning_capabilities_fixture())
    return message


def test_provider_neutral_source_is_sole_authority() -> None:
    assert CANONICAL_PROTO.is_file()
    assert not LEGACY_PROTO.exists()


def test_declared_grpc_runtime_supports_the_generated_stub() -> None:
    project = tomllib.loads((REPO_ROOT / "native/orchard_worker_mlx/pyproject.toml").read_text())
    grpc_requirement = next(
        dependency.removeprefix("grpcio>=")
        for dependency in project["project"]["dependencies"]
        if dependency.startswith("grpcio>=")
    )

    assert tuple(map(int, grpc_requirement.split("."))) >= tuple(
        map(int, worker_runtime_pb2_grpc.GRPC_GENERATED_VERSION.split("."))
    )
    assert "protobuf>=6.33.5" in project["project"]["dependencies"]
    assert "protobuf>=6.33.5" not in project["project"]["optional-dependencies"]["mlx"]


def test_python_generator_toolchain_is_provider_neutral_and_pinned() -> None:
    tooling = tomllib.loads((REPO_ROOT / "proto/orchard/worker/tooling/pyproject.toml").read_text())
    provider = tomllib.loads((REPO_ROOT / "native/orchard_worker_mlx/pyproject.toml").read_text())

    assert tooling["project"]["dependencies"] == [
        "grpcio-tools==1.81.1",
        "protobuf==6.33.5",
    ]
    assert all(
        not dependency.startswith("grpcio-tools")
        for dependency in provider["dependency-groups"]["dev"]
    )


def test_descriptor_golden_covers_the_complete_current_wire_contract() -> None:
    descriptor_bytes = (PROTO_ROOT / "worker_runtime.descriptor.pb").read_bytes()
    assert sha256(descriptor_bytes).hexdigest() == EXPECTED_DESCRIPTOR_SET_SHA256

    descriptor_set = _descriptor_set()
    assert {descriptor.name for descriptor in descriptor_set.file} == EXPECTED_DESCRIPTOR_FILES

    descriptor = _worker_descriptor(descriptor_set)

    assert descriptor.package == "orchard.worker.v1"
    assert descriptor.syntax == "proto3"
    assert list(descriptor.dependency) == [
        "cluster/v1/common.proto",
        "cluster/v1/events.proto",
        "cluster/v1/reasoning.proto",
        "cluster/v1/runtime.proto",
    ]
    actual_messages = {
        message.name: [_field_signature(field) for field in message.field]
        for message in descriptor.message_type
    }
    expected_messages = {
        message_name: [
            (
                field_name,
                number,
                field_type,
                "LABEL_REPEATED" if repeated else "LABEL_OPTIONAL",
                type_name,
                False,
                None,
            )
            for field_name, number, field_type, repeated, type_name in fields
        ]
        for message_name, fields in EXPECTED_MESSAGES.items()
    }
    assert actual_messages == expected_messages
    assert {message.name: list(message.oneof_decl) for message in descriptor.message_type} == {
        message_name: [] for message_name in EXPECTED_MESSAGES
    }
    assert {
        message.name: [(reserved.start, reserved.end) for reserved in message.reserved_range]
        for message in descriptor.message_type
    } == EXPECTED_RESERVED_RANGES
    assert {message.name: list(message.reserved_name) for message in descriptor.message_type} == {
        message_name: [] for message_name in EXPECTED_MESSAGES
    }

    assert len(descriptor.service) == 1
    service = descriptor.service[0]
    assert service.name == "WorkerRuntimeService"
    assert [
        (
            method.name,
            method.input_type,
            method.output_type,
            method.client_streaming,
            method.server_streaming,
        )
        for method in service.method
    ] == EXPECTED_RPCS
    generated_descriptor = descriptor_pb2.FileDescriptorProto.FromString(
        worker_runtime_pb2.DESCRIPTOR.serialized_pb
    )
    normalized_golden = descriptor_pb2.FileDescriptorProto()
    normalized_golden.CopyFrom(descriptor)
    for message in normalized_golden.message_type:
        for field in message.field:
            field.ClearField("json_name")

    assert normalized_golden == generated_descriptor


def test_python_decodes_elixir_fixture_with_semantic_equality() -> None:
    fixture = PROTO_ROOT / "fixtures" / "elixir_load_model_request.pb"

    decoded = worker_runtime_pb2.LoadModelRequest.FromString(fixture.read_bytes())

    assert decoded == worker_runtime_pb2.LoadModelRequest(
        model_id="mlx-community/Qwen3-4B",
        version="sha256:orchard-fixture",
        model_path="/var/lib/orchard/models/qwen3-4b",
    )


def test_python_decodes_elixir_capabilities_fixture_with_semantic_equality() -> None:
    fixture = PROTO_ROOT / "fixtures" / "elixir_worker_capabilities.pb"

    decoded = worker_runtime_pb2.WorkerCapabilities.FromString(fixture.read_bytes())

    assert decoded == _worker_capabilities_fixture()


def test_committed_python_fixture_is_produced_by_the_generated_binding() -> None:
    fixture = PROTO_ROOT / "fixtures" / "python_worker_status_response.pb"

    assert fixture.read_bytes() == _python_worker_status_fixture().SerializeToString(
        deterministic=True
    )


def test_previous_revision_python_fixture_decodes_with_capabilities_absent() -> None:
    fixture = PROTO_ROOT / "fixtures" / "python_worker_status_response.pb"

    decoded = worker_runtime_pb2.WorkerStatusResponse.FromString(fixture.read_bytes())

    assert not decoded.HasField("capabilities")
    assert decoded == _python_worker_status_fixture()


def test_committed_python_capabilities_fixture_is_produced_by_the_generated_binding() -> None:
    fixture = PROTO_ROOT / "fixtures" / "python_worker_status_response_capabilities.pb"

    assert fixture.read_bytes() == _python_worker_status_capabilities_fixture().SerializeToString(
        deterministic=True
    )
    assert worker_runtime_pb2.WorkerStatusResponse.FromString(fixture.read_bytes()).HasField(
        "capabilities"
    )


def test_reasoning_schema_uses_the_owner_confirmed_tags_and_presence() -> None:
    assert {
        field.name: field.number
        for field in reasoning_pb2.NegotiatedReasoningTuple.DESCRIPTOR.fields
    } == {
        "generation_policy": 1,
        "projection": 2,
        "reasoning_effort": 3,
        "model_artifact_digest": 4,
        "chat_template_digest": 5,
        "render_contract": 6,
        "render_contract_version": 7,
        "parser_family": 8,
        "parser_version": 9,
        "runtime_contract_version": 10,
        "event_binding_version": 11,
    }
    assert (
        worker_runtime_pb2.WorkerCapabilities.DESCRIPTOR.fields_by_name["loaded_binding"].number
        == 8
    )
    assert (
        worker_runtime_pb2.WorkerCapabilities.DESCRIPTOR.fields_by_name["reasoning_evidence"].number
        == 9
    )
    assert (
        runtime_pb2.ExecuteInferenceRequest.DESCRIPTOR.fields_by_name[
            "preparation_redemption"
        ].number
        == 14
    )
    assert events_pb2.Failed.DESCRIPTOR.fields_by_name["usage"].number == 4

    absent_usage = events_pb2.Failed(code="failed")
    present_zero_usage = events_pb2.Failed(code="failed", usage=common_pb2.TokenUsage())
    assert not absent_usage.HasField("usage")
    assert present_zero_usage.HasField("usage")
    assert absent_usage.SerializeToString() != present_zero_usage.SerializeToString()

    absent_effort = _reasoning_tuple()
    invalid_effort = _reasoning_tuple(
        reasoning_pb2.ReasoningEffortSelection(effort=reasoning_pb2.REASONING_EFFORT_UNSPECIFIED)
    )
    assert not absent_effort.HasField("reasoning_effort")
    assert invalid_effort.HasField("reasoning_effort")
    assert invalid_effort.reasoning_effort.effort == reasoning_pb2.REASONING_EFFORT_UNSPECIFIED
    assert absent_effort.SerializeToString() != invalid_effort.SerializeToString()


def test_frozen_input_descriptor_matches_execution_except_internal_extensions() -> None:
    descriptor_set = _descriptor_set()
    reasoning_descriptor = _file_descriptor(descriptor_set, "cluster/v1/reasoning.proto")
    runtime_descriptor = _file_descriptor(descriptor_set, "cluster/v1/runtime.proto")
    frozen = _message_descriptor(reasoning_descriptor, "FrozenExecutionInput")
    execution = _message_descriptor(runtime_descriptor, "ExecuteInferenceRequest")

    redemption = [field for field in execution.field if field.number == 14]
    execution_input = [field for field in execution.field if field.number not in {14, 15}]
    projection = [field for field in execution.field if field.number == 15]

    assert [_field_signature(field) for field in projection] == [
        (
            "tensorfold_history_projection_json",
            15,
            "TYPE_BYTES",
            "LABEL_OPTIONAL",
            None,
            False,
            None,
        )
    ]

    assert [_field_signature(field) for field in redemption] == [
        (
            "preparation_redemption",
            14,
            "TYPE_MESSAGE",
            "LABEL_OPTIONAL",
            ".cluster.v1.PreparationRedemption",
            False,
            None,
        )
    ]
    assert [_field_signature(field) for field in execution_input] == [
        _field_signature(field) for field in frozen.field
    ]


def test_tensorfold_projection_round_trip_preserves_bytes_and_baseline_wire() -> None:
    projection = b'{"schema_version":1,"messages":[{"content":"opaque\\ntext"}]}'
    request = runtime_pb2.ExecuteInferenceRequest(
        request_id="fixture", tensorfold_history_projection_json=projection
    )
    decoded = runtime_pb2.ExecuteInferenceRequest.FromString(request.SerializeToString())
    assert decoded.tensorfold_history_projection_json == projection
    assert runtime_pb2.ExecuteInferenceRequest(request_id="fixture").SerializeToString() == (
        b"\x0a\x07fixture"
    )


def test_tensorfold_identity_offer_round_trip_preserves_bytes_and_baseline_wire() -> None:
    offer = b'{"schema_version":1,"service_incarnation":"fixture"}'
    status = worker_runtime_pb2.WorkerStatusResponse(
        ready=True, tensorfold_profile_admission_json=offer
    )
    decoded = worker_runtime_pb2.WorkerStatusResponse.FromString(status.SerializeToString())
    assert decoded.tensorfold_profile_admission_json == offer
    assert worker_runtime_pb2.WorkerStatusResponse(ready=True).SerializeToString() == b"\x18\x01"


def test_python_reasoning_fixture_is_produced_by_the_current_binding() -> None:
    fixture = PROTO_ROOT / "fixtures" / "python_worker_status_response_reasoning.pb"
    expected = _python_worker_status_reasoning_fixture()

    assert fixture.read_bytes() == expected.SerializeToString(deterministic=True)
    assert worker_runtime_pb2.WorkerStatusResponse.FromString(fixture.read_bytes()) == expected


def test_preparation_fixture_round_trips_and_frozen_input_maps_onto_current_execution() -> None:
    fixture = PROTO_ROOT / "fixtures" / "elixir_prepare_inference_request.pb"
    expected = _prepare_inference_request()
    decoded = reasoning_pb2.PrepareInferenceRequest.FromString(fixture.read_bytes())

    assert decoded == expected
    assert decoded.SerializeToString(deterministic=True) == fixture.read_bytes()

    frozen_bytes = expected.input.SerializeToString(deterministic=True)
    execution = runtime_pb2.ExecuteInferenceRequest.FromString(frozen_bytes)

    assert not execution.HasField("preparation_redemption")
    assert execution.SerializeToString(deterministic=True) == frozen_bytes
    assert (
        reasoning_pb2.FrozenExecutionInput.FromString(
            execution.SerializeToString(deterministic=True)
        )
        == expected.input
    )


def test_older_and_non_advertising_bindings_receive_only_legacy_fields() -> None:
    legacy_fixture = PROTO_ROOT / "fixtures" / "python_worker_status_response.pb"
    decoded = worker_runtime_pb2.WorkerStatusResponse.FromString(legacy_fixture.read_bytes())

    assert not decoded.HasField("capabilities")
    assert worker_runtime_pb2.WorkerStatusRequest().SerializeToString() == b""
    assert runtime_pb2.StatusRequest().SerializeToString() == b""
    assert runtime_pb2.ExecuteInferenceRequest(request_id="legacy").SerializeToString() == (
        b"\x0a\x06legacy"
    )
    assert (
        "PrepareInference"
        not in runtime_pb2.DESCRIPTOR.services_by_name["NodeRuntimeService"].methods_by_name
    )
    assert {field.name: field.number for field in events_pb2.InferenceEvent.DESCRIPTOR.fields} == {
        "accepted": 1,
        "output_text_delta": 2,
        "tool_call_delta": 3,
        "usage": 4,
        "completed": 5,
        "failed": 6,
        "progress": 7,
        "token_delta": 8,
    }


def test_n_minus_1_golden_is_the_pre_reasoning_merge_base_descriptor() -> None:
    assert sha256(N_MINUS_1_DESCRIPTOR.read_bytes()).hexdigest() == N_MINUS_1_DESCRIPTOR_SHA256

    def numbers(full_name: str) -> list[int]:
        return [field.number for field in _n_minus_1_class(full_name).DESCRIPTOR.fields]

    assert numbers("cluster.v1.ExecuteInferenceRequest") == list(range(1, 14))
    assert numbers("cluster.v1.Failed") == [1, 2, 3]
    assert numbers("cluster.v1.StatusRequest") == []
    assert 14 not in numbers("cluster.v1.StatusResponse")
    assert numbers("orchard.worker.v1.WorkerStatusRequest") == []
    assert numbers("orchard.worker.v1.WorkerCapabilities") == list(range(1, 8))


def test_n_minus_1_execution_decodes_field_14_and_current_decodes_n_minus_1_execution() -> None:
    old_execution = _n_minus_1_class("cluster.v1.ExecuteInferenceRequest")
    frozen = _prepare_inference_request().input
    frozen_bytes = frozen.SerializeToString(deterministic=True)
    redemption = reasoning_pb2.PreparationRedemption(authorization=b"\xa5" * 32)
    current = runtime_pb2.ExecuteInferenceRequest.FromString(frozen_bytes)
    current.preparation_redemption.CopyFrom(redemption)
    current_bytes = current.SerializeToString(deterministic=True)

    old_view = old_execution.FromString(current_bytes)
    assert _unknown(old_view) == [(14, 2, redemption.SerializeToString())]
    assert old_view.SerializeToString(deterministic=True) == current_bytes
    old_view.DiscardUnknownFields()
    assert old_view.SerializeToString(deterministic=True) == frozen_bytes

    frozen_view = reasoning_pb2.FrozenExecutionInput.FromString(current_bytes)
    assert _unknown(frozen_view) == [(14, 2, redemption.SerializeToString())]
    frozen_view.DiscardUnknownFields()
    assert frozen_view == frozen

    old_bytes = old_execution.FromString(frozen_bytes).SerializeToString(deterministic=True)
    assert old_bytes == frozen_bytes
    decoded = runtime_pb2.ExecuteInferenceRequest.FromString(old_bytes)
    assert not decoded.HasField("preparation_redemption")
    assert decoded.params == frozen.params
    assert reasoning_pb2.FrozenExecutionInput.FromString(old_bytes) == frozen


def test_n_minus_1_failed_keeps_usage_unknown_and_current_reads_missing_usage() -> None:
    old_failed = _n_minus_1_class("cluster.v1.Failed")
    present_zero = events_pb2.Failed(code="failed", retryable=True, usage=common_pb2.TokenUsage())

    old_view = old_failed.FromString(present_zero.SerializeToString())
    assert (old_view.code, old_view.retryable) == ("failed", True)
    assert _unknown(old_view) == [(4, 2, b"")]

    old_bytes = old_failed(code="failed", retryable=True).SerializeToString()
    assert not events_pb2.Failed.FromString(old_bytes).HasField("usage")


def test_n_minus_1_capabilities_ignore_fields_8_9_and_current_reads_non_advertising() -> None:
    old_status = _n_minus_1_class("orchard.worker.v1.WorkerStatusResponse")
    reasoning_bytes = (
        PROTO_ROOT / "fixtures" / "python_worker_status_response_reasoning.pb"
    ).read_bytes()

    old_view = old_status.FromString(reasoning_bytes)
    assert [number for number, _wire, _data in _unknown(old_view.capabilities)] == [8, 9]
    old_view.DiscardUnknownFields()
    legacy_bytes = old_view.SerializeToString(deterministic=True)
    assert legacy_bytes == _python_worker_status_capabilities_fixture().SerializeToString(
        deterministic=True
    )

    current_view = worker_runtime_pb2.WorkerStatusResponse.FromString(legacy_bytes)
    assert current_view == _python_worker_status_capabilities_fixture()
    assert not current_view.capabilities.HasField("loaded_binding")
    assert not current_view.capabilities.HasField("reasoning_evidence")


def test_opt_in_observation_selector_and_live_variants_cross_n_and_n_minus_1() -> None:
    selector = reasoning_pb2.ReasoningObservationRequest(
        model_ref=common_pb2.ModelRef(
            model_id="mlx-community/Qwen3-4B", version="sha256:orchard-fixture"
        )
    )
    for current_class, old_name in [
        (worker_runtime_pb2.WorkerStatusRequest, "orchard.worker.v1.WorkerStatusRequest"),
        (runtime_pb2.StatusRequest, "cluster.v1.StatusRequest"),
    ]:
        request_bytes = current_class(reasoning_observation=selector).SerializeToString()
        assert current_class.FromString(request_bytes).reasoning_observation == selector
        old_view = _n_minus_1_class(old_name).FromString(request_bytes)
        assert _unknown(old_view) == [(1, 2, selector.SerializeToString())]
        assert _n_minus_1_class(old_name)().SerializeToString() == b""
        assert not current_class.FromString(b"").HasField("reasoning_observation")

    old_status = _n_minus_1_class("cluster.v1.StatusResponse")
    capabilities = _reasoning_capabilities_fixture()
    variants = {
        "evidence": reasoning_pb2.ReasoningLiveObservation(
            evidence=reasoning_pb2.ReasoningEvidence(
                loaded_binding=capabilities.loaded_binding,
                envelope=capabilities.reasoning_evidence,
                service_incarnation=capabilities.service_incarnation,
                remaining_freshness_ms=1_500,
            )
        ),
        "non_advertising": reasoning_pb2.ReasoningLiveObservation(
            non_advertising=reasoning_pb2.ReasoningNonAdvertising()
        ),
        "unknown": reasoning_pb2.ReasoningLiveObservation(unknown=reasoning_pb2.ReasoningUnknown()),
    }
    encoded = set()
    for variant, observation in variants.items():
        response_bytes = runtime_pb2.StatusResponse(
            max_concurrency=4, reasoning_observation=observation
        ).SerializeToString(deterministic=True)
        decoded = runtime_pb2.StatusResponse.FromString(response_bytes)
        assert decoded.reasoning_observation.WhichOneof("result") == variant
        assert decoded.reasoning_observation == observation

        old_view = old_status.FromString(response_bytes)
        assert old_view.max_concurrency == 4
        assert [number for number, _wire, _data in _unknown(old_view)] == [14]
        encoded.add(response_bytes)

    assert len(encoded) == 3
    old_bytes = old_status(max_concurrency=4).SerializeToString()
    assert not runtime_pb2.StatusResponse.FromString(old_bytes).HasField("reasoning_observation")
