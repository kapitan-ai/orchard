import tomllib
from hashlib import sha256
from pathlib import Path

from google.protobuf import descriptor_pb2

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
EXPECTED_DESCRIPTOR_SET_SHA256 = "6e51e68783dc7e5768d80c559616feaea3df1797ab38a3d5c7c4ef0e94fc27d9"
EXPECTED_DESCRIPTOR_FILES = {
    "cluster/v1/common.proto",
    "cluster/v1/events.proto",
    "cluster/v1/runtime.proto",
    "orchard/worker/v1/worker_runtime.proto",
}

EXPECTED_MESSAGES = {
    "WorkerStatusRequest": [],
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
    ],
    "LoadModelRequest": [
        ("model_id", 1, "TYPE_STRING", False, None),
        ("version", 2, "TYPE_STRING", False, None),
        ("model_path", 3, "TYPE_STRING", False, None),
    ],
}

EXPECTED_RESERVED_RANGES = {message_name: [] for message_name in EXPECTED_MESSAGES} | {
    "WorkerCapabilities": [(8, 9)]
}

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


def _python_worker_status_capabilities_fixture() -> worker_runtime_pb2.WorkerStatusResponse:
    message = _python_worker_status_fixture()
    message.capabilities.CopyFrom(_worker_capabilities_fixture())
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
