"""Run the real worker CLI with an in-flight cancellation handshake."""

from __future__ import annotations

import threading
from collections.abc import Iterator
from typing import Any
from unittest.mock import patch

from orchard_worker_mlx.backends import StubBackend
from orchard_worker_mlx.cli import main

_generate = StubBackend.generate


def cancellation_gated_generate(
    backend: StubBackend, request: Any, cancel_event: threading.Event
) -> Iterator[dict[str, Any]]:
    if request.request_id == "req-worker-cancel":
        # Generation cannot finish before the client sends the real Cancel RPC.
        yield {"kind": "output_text_delta", "delta": "cancel-ready"}
        if not cancel_event.wait(timeout=5):
            raise RuntimeError("Cancel RPC did not release the active generation")

    yield from _generate(backend, request, cancel_event)


if __name__ == "__main__":
    with patch.object(StubBackend, "generate", cancellation_gated_generate):
        raise SystemExit(main())
