"""Strict-prefix checkpoints against the pinned mlx-lm cache classes.

No model is loaded.  These tests fill real ``KVCache`` and ``ArraysCache``
objects with small arrays to check byte measurement and deep-copy isolation
under MLX's own update semantics.  They need the optional ``mlx`` extra::

    mise exec -- uv run --locked --directory native/orchard_worker_mlx --extra mlx \\
        pytest tests/test_strict_prefix_mlx_cache.py
"""

from __future__ import annotations

import importlib.util
from typing import Any

import pytest

from orchard_worker_mlx.strict_prefix_checkpoints import (
    CAPTURE_STORED,
    LOOKUP_HIT,
    CheckpointIdentity,
    StrictPrefixCheckpointStore,
    measure_snapshot_bytes,
)

_missing = [name for name in ("mlx", "mlx_lm") if importlib.util.find_spec(name) is None]

pytestmark = pytest.mark.skipif(
    bool(_missing),
    reason=f"MLX optional extra is not installed (missing: {', '.join(_missing)})",
)

KEY = [1, 2, 3, 4, 5, 6, 7, 8]
QUERY = [*KEY, 9, 10]


def _hybrid_cache() -> list[Any]:
    import mlx.core as mx
    from mlx_lm.models.cache import ArraysCache, KVCache

    linear = ArraysCache(2)
    linear[0] = mx.arange(24, dtype=mx.float32).reshape(1, 3, 8)
    linear[1] = mx.ones((1, 2, 4, 4), dtype=mx.float32)
    full = KVCache()
    keys = mx.arange(64, dtype=mx.float16).reshape(1, 2, 8, 4)
    full.update_and_fetch(keys, -keys)
    mx.eval([layer.state for layer in (linear, full)])
    return [linear, full]


def _host_state(prompt_cache: list[Any]) -> list[Any]:
    import numpy as np

    linear, full = prompt_cache
    keys, values = full.state
    return [
        np.array(linear[0]),
        np.array(linear[1]),
        np.array(keys),
        np.array(values),
        full.offset,
    ]


def _assert_same(left: list[Any], right: list[Any]) -> None:
    import numpy as np

    assert len(left) == len(right)
    for a, b in zip(left, right, strict=True):
        if isinstance(a, int):
            assert a == b
        else:
            np.testing.assert_array_equal(a, b)


def _store() -> StrictPrefixCheckpointStore:
    import mlx.core as mx

    return StrictPrefixCheckpointStore(
        identity=CheckpointIdentity(
            model_id="test-org/hybrid",
            model_version="v1",
            artifact_sha256=None,
            mlx_version=str(mx.__version__),
            mlx_lm_version="0.31.3",
            prefill_step_size=4,
            layer_types=("ArraysCache", "KVCache"),
        ),
        slots=1,
        slot_bytes=1 << 20,
        reply_marker_ids=(90, 91),
        materialize=mx.eval,
    )


def _advance(prompt_cache: list[Any]) -> None:
    """Mutate the cache the way prefill and decode do: in-place and rebinding."""
    import mlx.core as mx

    linear, full = prompt_cache
    linear[0][..., 0] = 99.0
    linear[1] = linear[1] * 3
    more = mx.full((1, 2, 2, 4), 7.0, dtype=mx.float16)
    full.update_and_fetch(more, more)
    mx.eval([layer.state for layer in prompt_cache])


def test_measured_bytes_cover_the_full_kv_buffer_and_recurrent_state() -> None:
    linear, full = _hybrid_cache()

    measured = measure_snapshot_bytes([linear, full])

    assert full.keys.shape[2] == 256
    assert measured == linear.nbytes + full.nbytes
    assert measured == 24 * 4 + 32 * 4 + 2 * (2 * 256 * 4 * 2)


def _active_bytes() -> int:
    import mlx.core as mx

    mx.synchronize()
    mx.clear_cache()
    return mx.get_active_memory()


def test_pinned_conv_state_storage_does_not_pin_the_chunk_buffer() -> None:
    """Logical nbytes bounds what a checkpoint keeps alive on the pin.

    The pinned qwen3_next and qwen3_5 layers store convolution history as
    ``mx.contiguous(conv_input[:, -n_keep:, :])``.  A plain slice would keep
    the whole prefill-chunk buffer alive; the stored form must not.
    """
    import mlx.core as mx

    shape = (1, 2048 + 3, 4096)
    parent_bytes = 2048 * 4096 * 2

    base = _active_bytes()
    conv_input = mx.ones(shape, dtype=mx.bfloat16)
    view = conv_input[:, -3:, :]
    mx.eval(view)
    del conv_input
    view_retained = _active_bytes() - base
    del view

    base = _active_bytes()
    conv_input = mx.ones(shape, dtype=mx.bfloat16)
    conv_state = mx.contiguous(conv_input[:, -3:, :])
    mx.eval(conv_state)
    del conv_input
    stored_retained = _active_bytes() - base

    assert view_retained >= parent_bytes
    assert stored_retained < 2 * conv_state.nbytes + 16384


def test_mlx_checkpoint_is_isolated_from_working_and_restored_mutation() -> None:
    working = _hybrid_cache()
    expected = _host_state(working)
    store = _store()

    assert store.capture(KEY, working).status == CAPTURE_STORED
    _advance(working)

    first = store.lookup(QUERY)
    assert first.status == LOOKUP_HIT
    _assert_same(_host_state(first.prompt_cache), expected)

    _advance(first.prompt_cache)
    second = store.lookup(QUERY)
    _assert_same(_host_state(second.prompt_cache), expected)
    assert _host_state(working)[4] == 10
