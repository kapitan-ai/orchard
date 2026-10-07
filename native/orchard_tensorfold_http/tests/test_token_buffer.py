"""Model-free bounded producer checks for TensorFold's token queue shape."""

import queue
from collections import deque
from threading import Event, Thread
from types import SimpleNamespace

import pytest

from orchard_tensorfold_http import token_buffer as module
from orchard_tensorfold_http.token_buffer import TokenBufferError, TokenChunkBuffer


@pytest.fixture
def failures():
    return []


@pytest.fixture
def buffer(failures):
    # Synthetic counts exercise limits, not an approved deployment profile.
    return TokenChunkBuffer(
        max_chunks=2,
        max_buffered_tokens=4,
        max_chunk_tokens=3,
        vocabulary_size=10,
        on_failure=lambda: failures.append("quarantine"),
    )


def test_full_buffer_reserves_terminal_and_preserves_chunk_order(buffer):
    buffer.put([0, 1])
    buffer.put([2, 3])
    buffer.put(None)
    assert buffer.snapshot().terminal_pending
    assert (buffer.snapshot().chunks, buffer.snapshot().tokens) == (2, 4)
    assert buffer.get(timeout=0.05) == [0, 1]
    assert buffer.get(timeout=0.05) == [2, 3]
    assert buffer.get(timeout=0.05) is None
    assert not buffer.snapshot().terminal_pending
    assert buffer.snapshot().chunks == buffer.snapshot().tokens == 0
    with pytest.raises(queue.Empty):
        buffer.get()


def test_finish_shape_can_set_done_when_all_data_capacity_is_occupied(buffer):
    job = SimpleNamespace(chunks=buffer, done=Event(), finished_at=0)
    job.chunks.put([1, 2])
    job.chunks.put([3, 4])
    job.chunks.put(None)
    job.done.set()
    assert job.done.is_set()
    assert [job.chunks.get(), job.chunks.get(), job.chunks.get()] == [[1, 2], [3, 4], None]


def test_data_is_snapshotted_and_consumer_output_is_detached(buffer):
    data = [1, 2]
    buffer.put(data)
    data.extend([3, 4, 5])
    data[0] = False
    assert buffer.snapshot().tokens == 2
    output = buffer.get()
    assert output == [1, 2]
    output.append(9)
    assert buffer.snapshot().tokens == 0


@pytest.mark.parametrize("data", [[0, 1, 2, 3], [0, 1], []])
def test_chunk_token_or_slot_overflow_permanently_fails(buffer, failures, data):
    buffer.put([1, 2])
    if data == []:
        buffer.put([])
    before = buffer.snapshot()
    with pytest.raises(TokenBufferError, match="limit exceeded|capacity exceeded"):
        buffer.put(data if data != [0, 1] else [0, 1, 2])
    assert failures == ["quarantine"]
    assert buffer.snapshot().failed
    assert buffer.snapshot().tokens == before.tokens
    assert buffer.snapshot().chunks == before.chunks
    for operation in (
        lambda: buffer.get(block=False),
        lambda: buffer.put(None),
        lambda: buffer.put([1]),
    ):
        with pytest.raises(TokenBufferError):
            operation()
    assert failures == ["quarantine"]


@pytest.mark.parametrize("token", [-1, 10, True, False, 0.0, None, "1"])
def test_unsupported_token_ids_fail_closed_without_content_in_error(buffer, failures, token):
    with pytest.raises(TokenBufferError) as error:
        buffer.put([token])
    assert str(error.value) == "unsupported token ID"
    assert failures == ["quarantine"]
    assert buffer.snapshot().chunks == buffer.snapshot().tokens == 0
    assert buffer.snapshot().failed


@pytest.mark.parametrize("data", [(1, 2), {1, 2}, "private content", iter([1, 2])])
def test_unsupported_chunk_types_fail_before_iteration_or_copy(buffer, failures, data):
    with pytest.raises(TokenBufferError, match="unsupported token chunk"):
        buffer.put(data)
    assert failures == ["quarantine"]
    assert buffer.snapshot().failed


def test_unknown_iterable_never_runs_user_iteration_or_length(buffer):
    class Unknown:
        def __iter__(self):
            raise AssertionError("must not iterate")

        def __len__(self):
            raise AssertionError("must not size")

    with pytest.raises(TokenBufferError, match="unsupported token chunk"):
        buffer.put(Unknown())


@pytest.mark.parametrize("action", [None, [1]])
def test_duplicate_terminal_or_post_terminal_data_permanently_fails(buffer, failures, action):
    buffer.put([1])
    buffer.put(None)
    with pytest.raises(TokenBufferError, match="after terminal"):
        buffer.put(action)
    assert failures == ["quarantine"]
    with pytest.raises(TokenBufferError, match="after terminal"):
        buffer.get()


@pytest.mark.parametrize("mode", [{"block": False}, {"timeout": 0}, {"timeout": 0.001}])
def test_empty_consumer_uses_queue_empty_and_can_later_receive_data(buffer, mode):
    with pytest.raises(queue.Empty):
        buffer.get(**mode)
    assert not buffer.snapshot().failed
    buffer.put([1])
    assert buffer.get(timeout=0.05) == [1]


@pytest.mark.parametrize("timeout", [-1, float("nan"), float("inf"), "unbounded"])
def test_invalid_consumer_timeout_does_not_poison_buffer(buffer, timeout):
    with pytest.raises(ValueError, match="timeout"):
        buffer.get(timeout=timeout)
    assert not buffer.snapshot().failed


@pytest.mark.parametrize(
    "field", ["max_chunks", "max_buffered_tokens", "max_chunk_tokens", "vocabulary_size"]
)
@pytest.mark.parametrize("value", [0, -1, True, None, float("inf")])
def test_configuration_limits_must_be_finite_positive_integers(field, value):
    options = dict(
        max_chunks=1,
        max_buffered_tokens=1,
        max_chunk_tokens=1,
        vocabulary_size=1,
        on_failure=lambda: None,
    )
    options[field] = value
    with pytest.raises(ValueError, match="positive integer"):
        TokenChunkBuffer(**options)


def test_failure_callback_is_required():
    with pytest.raises(ValueError, match="failure callback"):
        TokenChunkBuffer(
            max_chunks=1,
            max_buffered_tokens=1,
            max_chunk_tokens=1,
            vocabulary_size=1,
            on_failure=None,
        )


@pytest.mark.parametrize("mutation", ["grow", "shrink", "replace"])
def test_caller_mutation_during_admission_cannot_increase_copy_bound(buffer, monkeypatch, mutation):
    data = [1, 2]
    original = buffer._valid_token
    calls = []

    def validate(token):
        calls.append(token)
        if len(calls) == 1:
            if mutation == "grow":
                data.extend(range(1000))
            elif mutation == "shrink":
                data.clear()
            else:
                data[0] = False
        return original(token)

    monkeypatch.setattr(buffer, "_valid_token", validate)
    with pytest.raises(TokenBufferError, match="changed during admission"):
        buffer.put(data)
    assert buffer.snapshot().tokens == buffer.snapshot().chunks == 0
    assert buffer.snapshot().failed
    assert len(calls) <= 4


def test_failure_callback_runs_outside_lock_and_failure_survives_callback_error():
    probes = []

    def on_failure():
        worker = Thread(target=lambda: probes.append(buffer.snapshot()))
        worker.start()
        worker.join(1)
        assert not worker.is_alive()
        raise RuntimeError("quarantine callback failed")

    buffer = TokenChunkBuffer(
        max_chunks=1,
        max_buffered_tokens=1,
        max_chunk_tokens=1,
        vocabulary_size=10,
        on_failure=on_failure,
    )
    with pytest.raises(TokenBufferError) as error:
        buffer.put([1, 2])
    assert isinstance(error.value.__cause__, RuntimeError)
    assert probes[0].failed
    with pytest.raises(TokenBufferError):
        buffer.put(None)


@pytest.mark.parametrize("wake", ["data", "terminal", "failure"])
def test_waiting_consumer_wakes_for_data_terminal_or_failure(buffer, wake):
    entered = Event()
    results = []

    def consume():
        entered.set()
        try:
            results.append(buffer.get(timeout=1))
        except TokenBufferError:
            results.append("failed")

    worker = Thread(target=consume)
    worker.start()
    assert entered.wait(1)
    if wake == "data":
        buffer.put([1])
    elif wake == "terminal":
        buffer.put(None)
    else:
        with pytest.raises(TokenBufferError):
            buffer.put([True])
    worker.join(2)
    assert not worker.is_alive()
    assert results == {"data": [[1]], "terminal": [None], "failure": ["failed"]}[wake]


def test_failure_is_visible_before_blocked_callback_finishes():
    callback_entered, callback_finish = Event(), Event()
    errors = []

    def on_failure():
        callback_entered.set()
        assert callback_finish.wait(2)

    buffer = TokenChunkBuffer(
        max_chunks=1,
        max_buffered_tokens=1,
        max_chunk_tokens=1,
        vocabulary_size=10,
        on_failure=on_failure,
    )

    def produce():
        try:
            buffer.put([1, 2])
        except TokenBufferError as error:
            errors.append(str(error))

    worker = Thread(target=produce)
    worker.start()
    try:
        assert callback_entered.wait(1)
        assert buffer.snapshot().failed
        with pytest.raises(TokenBufferError):
            buffer.get(timeout=1)
        with pytest.raises(TokenBufferError):
            buffer.put(None)
    finally:
        callback_finish.set()
        worker.join(2)
    assert not worker.is_alive()
    assert errors == ["token chunk limit exceeded"]


def test_producer_copy_allocation_failure_freezes_buffer_and_keeps_existing_data(
    buffer, failures, monkeypatch
):
    buffer.put([1])

    def cannot_allocate(data):
        raise MemoryError("injected allocation failure")

    monkeypatch.setattr(module, "tuple", cannot_allocate, raising=False)
    with pytest.raises(TokenBufferError, match="admission failed") as error:
        buffer.put([2])
    assert isinstance(error.value.__cause__, MemoryError)
    assert failures == ["quarantine"]
    assert buffer.snapshot().failed
    assert buffer.snapshot().tokens == buffer.snapshot().chunks == 1
    with pytest.raises(TokenBufferError):
        buffer.put(None)
    with pytest.raises(TokenBufferError):
        buffer.get()
    assert failures == ["quarantine"]


@pytest.mark.parametrize("error_type", [MemoryError, RuntimeError])
def test_producer_append_failure_freezes_without_successful_admission(buffer, failures, error_type):
    buffer.put([1])

    class CannotAppend(deque):
        def append(self, chunk):
            raise error_type("injected append failure")

    buffer._chunks = CannotAppend(buffer._chunks)
    with pytest.raises(TokenBufferError, match="admission failed") as error:
        buffer.put([2])
    assert isinstance(error.value.__cause__, error_type)
    assert failures == ["quarantine"]
    assert buffer.snapshot().failed
    assert buffer.snapshot().tokens == buffer.snapshot().chunks == 1


def test_consumer_conversion_failure_retains_data_and_prevents_false_terminal(
    buffer, failures, monkeypatch
):
    buffer.put([1])
    buffer.put(None)

    def cannot_allocate(chunk):
        raise MemoryError("injected consumer conversion failure")

    monkeypatch.setattr(module, "list", cannot_allocate, raising=False)
    with pytest.raises(TokenBufferError, match="consumption failed") as error:
        buffer.get()
    assert isinstance(error.value.__cause__, MemoryError)
    assert failures == ["quarantine"]
    assert buffer.snapshot().failed
    assert buffer.snapshot().terminal_pending
    assert buffer.snapshot().tokens == buffer.snapshot().chunks == 1
    with pytest.raises(TokenBufferError):
        buffer.get()
    assert failures == ["quarantine"]
