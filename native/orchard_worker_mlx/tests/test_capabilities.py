"""Capability envelope conformance on GetStatus (SPEC.md §4.10, design D1/D2/D6/D11).

The servicer copies the backend envelope verbatim; malformed and duplicate
variants must reach the wire unchanged so the Node Agent can classify them.
"""

from __future__ import annotations

import re
from typing import Any

import pytest

from orchard_worker_mlx import __version__, capabilities, service
from orchard_worker_mlx.backends import MLXBackend, StubBackend
from orchard_worker_mlx.capabilities import (
    SERVICE_INCARNATION,
    BackendCapabilities,
    BackendCapabilityProfile,
    installed_distribution_version,
    mlx_capabilities,
    mlx_capability_profile,
)
from orchard_worker_mlx.generated.orchard.worker.v1 import worker_runtime_pb2
from orchard_worker_mlx.model_loader import PrefixCacheLoadConfig
from orchard_worker_mlx.service import WorkerRuntimeServicer

_TOKEN_RE = re.compile(r"^[a-z0-9][a-z0-9_.-]{0,63}$")
_INCARNATION_RE = re.compile(r"^[0-9a-f]{32}$")
_FIXTURE_INCARNATION = "0123456789abcdef0123456789abcdef"
# Present envelope with the required protocol_major left at 0: malformed per
# the WorkerCapabilities proto grammar, never confusable with omission.
_MALFORMED_SENTINEL = worker_runtime_pb2.WorkerCapabilities(protocol_major=0)


def _profile(**overrides: Any) -> BackendCapabilityProfile:
    profile = BackendCapabilityProfile(
        profile_id="mlx-metal-unified",
        artifact_format="safetensors",
        acceleration="metal",
        device_binding="apple_gpu_0",
        memory_semantics="unified",
        max_concurrency=1,
        runtime_features=["prompt_token_ids", "streaming"],
        cache_capabilities=["prefix_cache"],
    )
    profile.update(overrides)  # type: ignore[typeddict-item]
    return profile


def _envelope(
    profiles: list[BackendCapabilityProfile] | None = None, **overrides: Any
) -> BackendCapabilities:
    envelope = BackendCapabilities(
        protocol_major=1,
        protocol_minor=1,
        provider_id="mlx",
        provider_version="0.31.2",
        implementation_version=__version__,
        service_incarnation=_FIXTURE_INCARNATION,
        profiles=[_profile()] if profiles is None else profiles,
    )
    envelope.update(overrides)  # type: ignore[typeddict-item]
    return envelope


def _wire(envelope: BackendCapabilities) -> worker_runtime_pb2.WorkerCapabilities:
    return worker_runtime_pb2.WorkerCapabilities(
        protocol_major=envelope["protocol_major"],
        protocol_minor=envelope["protocol_minor"],
        provider_id=envelope["provider_id"],
        provider_version=envelope["provider_version"],
        implementation_version=envelope["implementation_version"],
        service_incarnation=envelope["service_incarnation"],
        profiles=[worker_runtime_pb2.WorkerCapabilityProfile(**p) for p in envelope["profiles"]],
    )


def _get_status(backend: Any) -> worker_runtime_pb2.WorkerStatusResponse:
    return WorkerRuntimeServicer(backend).GetStatus(worker_runtime_pb2.WorkerStatusRequest(), None)


def _mlx_backend(prefix_cache_config: PrefixCacheLoadConfig | None = None) -> MLXBackend:
    return MLXBackend(
        session_loader=lambda **kwargs: None,
        session_unloader=lambda session: None,
        prefix_cache_config=prefix_cache_config,
    )


# -- Servicer pass-through via StubBackend -----------------------------------


def test_get_status_publishes_injected_populated_envelope() -> None:
    envelope = _envelope()

    response = _get_status(StubBackend(capabilities=envelope))

    assert response.HasField("capabilities")
    assert response.capabilities == _wire(envelope)


def test_get_status_omits_envelope_when_backend_has_none() -> None:
    response = _get_status(StubBackend())

    assert not response.HasField("capabilities")


def test_get_status_publishes_empty_profiles_as_present_envelope() -> None:
    envelope = _envelope(profiles=[])

    response = _get_status(StubBackend(capabilities=envelope))

    assert response.HasField("capabilities")
    assert list(response.capabilities.profiles) == []


@pytest.mark.parametrize(
    ("label", "envelope"),
    [
        ("protocol_major_zero", _envelope(protocol_major=0)),
        ("empty_provider_id", _envelope(provider_id="")),
        ("empty_provider_version", _envelope(provider_version="")),
        ("empty_implementation_version", _envelope(implementation_version="")),
        ("empty_service_incarnation", _envelope(service_incarnation="")),
        ("uppercase_provider_id", _envelope(provider_id="MLX")),
        ("uppercase_profile_token", _envelope(profiles=[_profile(acceleration="Metal")])),
        ("zero_max_concurrency", _envelope(profiles=[_profile(max_concurrency=0)])),
        ("unsorted_runtime_features", _envelope(profiles=[_profile(runtime_features=["b", "a"])])),
    ],
)
def test_get_status_passes_malformed_envelope_through_unchanged(
    label: str, envelope: BackendCapabilities
) -> None:
    response = _get_status(StubBackend(capabilities=envelope))

    assert response.HasField("capabilities"), label
    assert response.capabilities == _wire(envelope), label


def test_get_status_passes_duplicate_profile_id_through_unchanged() -> None:
    envelope = _envelope(profiles=[_profile(max_concurrency=1), _profile(max_concurrency=4)])

    response = _get_status(StubBackend(capabilities=envelope))

    assert [p.profile_id for p in response.capabilities.profiles] == [
        "mlx-metal-unified",
        "mlx-metal-unified",
    ]
    assert response.capabilities == _wire(envelope)


def test_get_status_passes_duplicate_canonical_tuple_through_unchanged() -> None:
    envelope = _envelope(
        profiles=[_profile(profile_id="mlx-a"), _profile(profile_id="mlx-b")],
    )

    response = _get_status(StubBackend(capabilities=envelope))

    assert len(response.capabilities.profiles) == 2
    assert response.capabilities == _wire(envelope)


def test_get_status_protocol_minor_zero_is_preserved() -> None:
    envelope = _envelope(protocol_minor=0)

    response = _get_status(StubBackend(capabilities=envelope))

    assert response.capabilities.protocol_minor == 0
    assert response.capabilities == _wire(envelope)


def _raw_capabilities_backend(raw: Any) -> StubBackend:
    """StubBackend whose ``status()["capabilities"]`` is the raw value ``raw``."""

    class RawCapabilitiesBackend(StubBackend):
        def status(self) -> Any:
            status = dict(super().status())
            status["capabilities"] = raw
            return status

    return RawCapabilitiesBackend()


def _assert_malformed_sentinel(response: worker_runtime_pb2.WorkerStatusResponse) -> None:
    assert response.HasField("capabilities")
    assert response.capabilities == _MALFORMED_SENTINEL
    assert response.capabilities.protocol_major == 0


def _assert_legacy_status_intact(response: worker_runtime_pb2.WorkerStatusResponse) -> None:
    stub = StubBackend()
    assert response.ready is bool(stub.health()["ready"])
    assert response.loaded is bool(stub.status()["loaded"])
    assert response.max_concurrency == stub.status()["max_concurrency"]


# -- Malformed payloads are preserved as present malformed evidence -----------


def test_get_status_omits_envelope_when_capabilities_key_is_none() -> None:
    response = _get_status(_raw_capabilities_backend(None))

    assert not response.HasField("capabilities")


@pytest.mark.parametrize(
    "raw",
    ["not-a-dict", ["not", "a", "dict"], 7],
    ids=["string", "list", "int"],
)
def test_get_status_publishes_non_dict_capabilities_as_malformed_sentinel(raw: Any) -> None:
    response = _get_status(_raw_capabilities_backend(raw))

    _assert_malformed_sentinel(response)
    _assert_legacy_status_intact(response)


@pytest.mark.parametrize(
    ("label", "envelope"),
    [
        ("profiles_not_a_list", _envelope(profiles="mlx-metal-unified")),
        ("profiles_is_dict", _envelope(profiles={"profile_id": "mlx-metal-unified"})),
        ("profile_entry_not_a_dict", _envelope(profiles=[_profile(), "mlx-metal-unified"])),
        ("profile_entry_none", _envelope(profiles=[None])),
        ("runtime_features_not_a_list", _envelope(profiles=[_profile(runtime_features="a")])),
        ("runtime_feature_non_str", _envelope(profiles=[_profile(runtime_features=["a", 1])])),
        ("cache_capability_non_str", _envelope(profiles=[_profile(cache_capabilities=[None])])),
    ],
)
def test_get_status_publishes_unrepresentable_shapes_as_malformed_sentinel(
    label: str, envelope: BackendCapabilities
) -> None:
    response = _get_status(StubBackend(capabilities=envelope))

    _assert_malformed_sentinel(response)
    _assert_legacy_status_intact(response)


@pytest.mark.parametrize(
    ("label", "max_concurrency"),
    [
        ("oversized", 2**40),
        ("uint32_max_plus_one", 2**32),
        ("negative", -1),
        ("bool", True),
        ("float", 1.0),
        ("string", "4"),
    ],
)
def test_get_status_does_not_clamp_invalid_max_concurrency(
    label: str, max_concurrency: Any
) -> None:
    envelope = _envelope(profiles=[_profile(max_concurrency=max_concurrency)])

    response = _get_status(StubBackend(capabilities=envelope))

    assert response.HasField("capabilities"), label
    assert response.capabilities.protocol_major == 1, label
    assert response.capabilities.profiles[0].max_concurrency == 0, label


@pytest.mark.parametrize(
    ("label", "protocol_minor"),
    [
        ("oversized", 2**40),
        ("negative", -1),
        ("bool", True),
        ("string", "1"),
        ("none", None),
    ],
)
def test_get_status_does_not_launder_invalid_protocol_minor_to_zero(
    label: str, protocol_minor: Any
) -> None:
    envelope = dict(_envelope())
    envelope["protocol_minor"] = protocol_minor

    response = _get_status(_raw_capabilities_backend(envelope))

    _assert_malformed_sentinel(response)
    _assert_legacy_status_intact(response)


def test_get_status_does_not_clamp_oversized_protocol_major() -> None:
    response = _get_status(StubBackend(capabilities=_envelope(protocol_major=2**32)))

    assert response.HasField("capabilities")
    assert response.capabilities.protocol_major == 0


def test_get_status_does_not_clamp_uint32_boundary_downwards() -> None:
    envelope = _envelope(protocol_major=2**32 - 1)

    response = _get_status(StubBackend(capabilities=envelope))

    assert response.capabilities.protocol_major == 2**32 - 1


@pytest.mark.parametrize(
    ("label", "envelope"),
    [
        ("non_str_provider_id", _envelope(provider_id=3)),
        ("non_str_profile_id", _envelope(profiles=[_profile(profile_id=None)])),
    ],
)
def test_get_status_publishes_non_string_scalars_as_empty(
    label: str, envelope: BackendCapabilities
) -> None:
    response = _get_status(StubBackend(capabilities=envelope))

    assert response.HasField("capabilities"), label
    assert response.capabilities.protocol_major == 1, label
    assert response.capabilities.provider_id == ("" if label == "non_str_provider_id" else "mlx")
    if label == "non_str_profile_id":
        assert response.capabilities.profiles[0].profile_id == ""


@pytest.mark.parametrize(
    ("label", "envelope"),
    [
        ("surrogate_provider_version", _envelope(provider_version="0.31\udc80")),
        ("surrogate_runtime_feature", _envelope(profiles=[_profile(runtime_features=["\udc80"])])),
    ],
)
def test_get_status_survives_unpaired_surrogates_with_malformed_sentinel(
    label: str, envelope: BackendCapabilities
) -> None:
    # protobuf raises on strings that cannot be UTF-8 encoded; GetStatus must
    # still return every legacy field and publish present malformed evidence.
    response = _get_status(StubBackend(capabilities=envelope))

    _assert_malformed_sentinel(response)
    _assert_legacy_status_intact(response)
    assert response.health_code == StubBackend().health()["code"]


def test_get_status_substitutes_sentinel_when_projection_raises_unexpectedly(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    def explode(_: Any) -> Any:
        raise RuntimeError("boom")

    monkeypatch.setattr(service, "_capabilities_status_response", explode)

    response = _get_status(StubBackend(capabilities=_envelope()))

    _assert_malformed_sentinel(response)
    _assert_legacy_status_intact(response)


# -- Service incarnation -----------------------------------------------------


def test_service_incarnation_is_32_lowercase_hex_chars() -> None:
    assert _INCARNATION_RE.fullmatch(SERVICE_INCARNATION)
    assert _TOKEN_RE.fullmatch(SERVICE_INCARNATION)


def test_service_incarnation_is_stable_across_get_status_calls() -> None:
    backend = _mlx_backend()
    servicer = WorkerRuntimeServicer(backend)

    first = servicer.GetStatus(worker_runtime_pb2.WorkerStatusRequest(), None)
    second = servicer.GetStatus(worker_runtime_pb2.WorkerStatusRequest(), None)

    assert first.capabilities.service_incarnation == SERVICE_INCARNATION
    assert second.capabilities.service_incarnation == SERVICE_INCARNATION


def test_service_incarnation_is_shared_process_wide_across_backend_instances() -> None:
    # Module-level: one incarnation per worker process start, regardless of
    # how many servicer/backend objects that process constructs.
    first = _get_status(_mlx_backend()).capabilities.service_incarnation
    second = _get_status(_mlx_backend()).capabilities.service_incarnation

    assert first == second == SERVICE_INCARNATION


# -- MLX envelope content ----------------------------------------------------


def test_mlx_backend_status_publishes_exact_profile() -> None:
    response = _get_status(_mlx_backend())
    envelope = response.capabilities

    assert envelope.protocol_major == 1
    assert envelope.protocol_minor == 1
    assert envelope.provider_id == "mlx"
    assert envelope.provider_version == installed_distribution_version("mlx")
    assert envelope.provider_version
    assert len(envelope.provider_version.encode()) <= 128
    assert envelope.provider_version.isascii() and envelope.provider_version.isprintable()
    assert envelope.implementation_version == __version__
    assert envelope.service_incarnation == SERVICE_INCARNATION
    assert len(envelope.profiles) == 1

    profile = envelope.profiles[0]
    assert profile.profile_id == "mlx-metal-unified"
    assert profile.artifact_format == "safetensors"
    assert profile.acceleration == "metal"
    assert profile.device_binding == "apple_gpu_0"
    assert profile.memory_semantics == "unified"
    assert profile.max_concurrency == response.max_concurrency == 1
    assert list(profile.runtime_features) == ["prompt_token_ids", "streaming"]
    assert list(profile.cache_capabilities) == ["prefix_cache"]

    for token in (
        envelope.provider_id,
        profile.profile_id,
        profile.artifact_format,
        profile.acceleration,
        profile.device_binding,
        profile.memory_semantics,
        *profile.runtime_features,
        *profile.cache_capabilities,
    ):
        assert _TOKEN_RE.fullmatch(token), token


def test_mlx_backend_omits_prefix_cache_capability_when_disabled() -> None:
    response = _get_status(_mlx_backend(PrefixCacheLoadConfig(mode="disabled")))

    assert list(response.capabilities.profiles[0].cache_capabilities) == []


def test_mlx_capabilities_defaults_to_installed_mlx_version() -> None:
    envelope = mlx_capabilities(max_concurrency=2, prefix_cache_enabled=True)

    assert envelope["provider_version"] == installed_distribution_version("mlx")
    assert envelope["profiles"][0]["max_concurrency"] == 2


def test_mlx_capability_profile_clamps_max_concurrency_to_at_least_one() -> None:
    assert (
        mlx_capability_profile(max_concurrency=0, prefix_cache_enabled=False)["max_concurrency"]
        == 1
    )


def test_installed_distribution_version_falls_back_to_unknown(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    def missing(_: str) -> str:
        raise capabilities.metadata.PackageNotFoundError("mlx")

    monkeypatch.setattr(capabilities.metadata, "version", missing)

    assert installed_distribution_version("mlx") == "unknown"


@pytest.mark.parametrize(
    "error",
    [OSError("unreadable metadata"), ValueError("malformed METADATA"), RuntimeError("boom")],
    ids=["os_error", "value_error", "runtime_error"],
)
def test_installed_distribution_version_falls_back_to_unknown_on_any_error(
    monkeypatch: pytest.MonkeyPatch, error: Exception
) -> None:
    def broken(_: str) -> str:
        raise error

    monkeypatch.setattr(capabilities.metadata, "version", broken)

    assert installed_distribution_version("mlx") == "unknown"


def test_installed_distribution_version_does_not_swallow_keyboard_interrupt(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    def interrupted(_: str) -> str:
        raise KeyboardInterrupt

    monkeypatch.setattr(capabilities.metadata, "version", interrupted)

    with pytest.raises(KeyboardInterrupt):
        installed_distribution_version("mlx")


def test_mlx_backend_constructs_and_reports_status_when_metadata_lookup_raises(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Provider-version discovery is diagnostic only; it must never gate backend
    # construction or the legacy GetStatus fields (proto: non-gating envelope).
    def broken(_: str) -> str:
        raise OSError("unreadable metadata")

    monkeypatch.setattr(capabilities.metadata, "version", broken)

    backend = _mlx_backend()
    response = _get_status(backend)

    assert response.ready is True
    assert response.max_concurrency == 1
    assert response.HasField("capabilities")
    assert response.capabilities.protocol_major == 1
    assert response.capabilities.provider_version == "unknown"
