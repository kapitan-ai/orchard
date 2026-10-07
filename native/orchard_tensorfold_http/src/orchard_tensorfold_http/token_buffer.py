"""Bounded token chunks at TensorFold's ``ChatJob.chunks`` queue seam.

This buffer is not installed on a live scheduler. TensorFold's producer puts
occur outside its engine-step exception handler: overflow must quarantine the
owned child and lead to positive owned reaping, not a normal completion claim.
"""

import math
import queue
import time
from collections import deque
from collections.abc import Callable
from dataclasses import dataclass
from threading import Condition
from typing import NoReturn


class TokenBufferError(RuntimeError):
    """The producer failed the bounded buffer; the incarnation cannot resume."""


def _positive(value: int, name: str) -> int:
    if type(value) is not int or value < 1:
        raise ValueError(f"{name} must be a positive integer")
    return value


@dataclass(frozen=True)
class TokenBufferSnapshot:
    chunks: int
    tokens: int
    terminal_pending: bool
    failed: bool


class TokenChunkBuffer:
    """A finite producer queue with a separately reserved terminal marker.

    Producers never wait for data capacity. An invalid or overflowing put
    freezes the buffer and invokes its failure callback outside the lock once.
    Consumer output is detached; downstream text accumulation needs its own
    limits. The token counts are not a physical process-memory measurement.
    """

    def __init__(
        self,
        *,
        max_chunks: int,
        max_buffered_tokens: int,
        max_chunk_tokens: int,
        vocabulary_size: int,
        on_failure: Callable[[], None],
    ):
        self._max_chunks = _positive(max_chunks, "maximum chunks")
        self._max_tokens = _positive(max_buffered_tokens, "maximum buffered tokens")
        self._max_chunk = _positive(max_chunk_tokens, "maximum chunk tokens")
        self._vocabulary_size = _positive(vocabulary_size, "vocabulary size")
        if not callable(on_failure):
            raise ValueError("a failure callback is required")
        self._on_failure = on_failure
        self._condition = Condition()
        self._chunks: deque[tuple[int, ...]] = deque()
        self._tokens = 0
        self._terminal = False
        self._terminal_delivered = False
        self._failure: str | None = None

    def snapshot(self) -> TokenBufferSnapshot:
        with self._condition:
            return TokenBufferSnapshot(
                chunks=len(self._chunks),
                tokens=self._tokens,
                terminal_pending=self._terminal and not self._terminal_delivered,
                failed=self._failure is not None,
            )

    def _valid_token(self, token: int) -> bool:
        return type(token) is int and 0 <= token < self._vocabulary_size

    def _chunk(self, data: list[int]) -> tuple[int, ...]:
        if type(data) is not list:
            raise TokenBufferError("unsupported token chunk")
        size = len(data)
        if size > self._max_chunk:
            raise TokenBufferError("token chunk limit exceeded")
        if len(self._chunks) >= self._max_chunks or self._tokens + size > self._max_tokens:
            raise TokenBufferError("token buffer capacity exceeded")
        try:
            for index in range(size):
                if not self._valid_token(data[index]):
                    raise TokenBufferError("unsupported token ID")
            # Copy a fixed number of positions; caller growth cannot enlarge it.
            chunk = tuple(data[index] for index in range(size))
        except IndexError as error:
            raise TokenBufferError("token chunk changed during admission") from error
        if len(data) != size or any(not self._valid_token(token) for token in chunk):
            raise TokenBufferError("token chunk changed during admission")
        return chunk

    def put(self, data: list[int] | None) -> None:
        """Publish immediately or permanently fail; terminal needs no data slot."""
        with self._condition:
            if self._failure is not None:
                raise TokenBufferError(self._failure)
            try:
                if self._terminal:
                    raise TokenBufferError("token producer wrote after terminal")
                if data is None:
                    self._terminal = True
                else:
                    chunk = self._chunk(data)
                    self._chunks.append(chunk)
                    self._tokens += len(chunk)
                self._condition.notify_all()
                return
            except BaseException as error:
                failure = (
                    str(error)
                    if isinstance(error, TokenBufferError)
                    else "token buffer admission failed"
                )
                self._freeze(failure)
                cause = error
        self._raise_failure(failure, cause)

    def _freeze(self, reason: str) -> None:
        self._failure = reason
        self._condition.notify_all()

    def _raise_failure(self, reason: str, cause: BaseException) -> NoReturn:
        try:
            self._on_failure()
        except BaseException as error:
            raise TokenBufferError(reason) from error
        raise TokenBufferError(reason) from cause

    def get(self, block: bool = True, timeout: float | None = None) -> list[int] | None:
        """Use ``queue.Empty`` for absent data, including finite consumer timeouts."""
        if timeout is not None and (
            not isinstance(timeout, int | float) or not math.isfinite(timeout) or timeout < 0
        ):
            raise ValueError("timeout must be finite and nonnegative")
        deadline = None if timeout is None else time.monotonic() + timeout
        with self._condition:
            while True:
                if self._failure is not None:
                    raise TokenBufferError(self._failure)
                try:
                    if self._chunks:
                        output = list(self._chunks[0])
                        chunk = self._chunks.popleft()
                        self._tokens -= len(chunk)
                        return output
                    if self._terminal and not self._terminal_delivered:
                        self._terminal_delivered = True
                        return None
                    if not block or self._terminal_delivered:
                        raise queue.Empty
                    remaining = None if deadline is None else deadline - time.monotonic()
                    if remaining is not None and remaining <= 0:
                        raise queue.Empty
                    self._condition.wait(remaining)
                except queue.Empty:
                    raise
                except BaseException as error:
                    failure = "token buffer consumption failed"
                    self._freeze(failure)
                    cause = error
                    break
        self._raise_failure(failure, cause)
