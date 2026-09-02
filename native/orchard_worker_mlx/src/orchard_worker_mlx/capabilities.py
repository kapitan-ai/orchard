"""Capability envelope values published on ``GetStatus`` (design D1/D6/D11).

``SERVICE_INCARNATION`` is generated once per worker process start from 16
random bytes. It is not derived from any secret or configuration and is safe
to log; the Node Agent uses a change in it to invalidate retained snapshots.
"""

from __future__ import annotations

import secrets
from importlib import metadata
from typing import TypedDict

from orchard_worker_mlx import __version__

CAPABILITY_PROTOCOL_MAJOR = 1
CAPABILITY_PROTOCOL_MINOR = 1
MLX_PROVIDER_ID = "mlx"
MLX_PROFILE_ID = "mlx-metal-unified"
MLX_ARTIFACT_FORMAT = "safetensors"
MLX_ACCELERATION = "metal"
MLX_DEVICE_BINDING = "apple_gpu_0"
MLX_MEMORY_SEMANTICS = "unified"
MLX_RUNTIME_FEATURES = ("prompt_token_ids", "streaming")
PREFIX_CACHE_CAPABILITY = "prefix_cache"
_UNKNOWN_VERSION = "unknown"

SERVICE_INCARNATION = secrets.token_hex(16)


class BackendCapabilityProfile(TypedDict):
    profile_id: str
    artifact_format: str
    acceleration: str
    device_binding: str
    memory_semantics: str
    max_concurrency: int
    runtime_features: list[str]
    cache_capabilities: list[str]


class BackendCapabilities(TypedDict):
    protocol_major: int
    protocol_minor: int
    provider_id: str
    provider_version: str
    implementation_version: str
    service_incarnation: str
    profiles: list[BackendCapabilityProfile]


def installed_distribution_version(distribution: str) -> str:
    try:
        return metadata.version(distribution) or _UNKNOWN_VERSION
    except metadata.PackageNotFoundError:
        return _UNKNOWN_VERSION


def mlx_capability_profile(
    *, max_concurrency: int, prefix_cache_enabled: bool
) -> BackendCapabilityProfile:
    return BackendCapabilityProfile(
        profile_id=MLX_PROFILE_ID,
        artifact_format=MLX_ARTIFACT_FORMAT,
        acceleration=MLX_ACCELERATION,
        device_binding=MLX_DEVICE_BINDING,
        memory_semantics=MLX_MEMORY_SEMANTICS,
        max_concurrency=max(1, max_concurrency),
        runtime_features=sorted(set(MLX_RUNTIME_FEATURES)),
        cache_capabilities=[PREFIX_CACHE_CAPABILITY] if prefix_cache_enabled else [],
    )


def mlx_capabilities(
    *,
    max_concurrency: int,
    prefix_cache_enabled: bool,
    provider_version: str | None = None,
    service_incarnation: str = SERVICE_INCARNATION,
) -> BackendCapabilities:
    return BackendCapabilities(
        protocol_major=CAPABILITY_PROTOCOL_MAJOR,
        protocol_minor=CAPABILITY_PROTOCOL_MINOR,
        provider_id=MLX_PROVIDER_ID,
        provider_version=(
            provider_version
            if provider_version is not None
            else installed_distribution_version(MLX_PROVIDER_ID)
        ),
        implementation_version=__version__,
        service_incarnation=service_incarnation,
        profiles=[
            mlx_capability_profile(
                max_concurrency=max_concurrency,
                prefix_cache_enabled=prefix_cache_enabled,
            )
        ],
    )
