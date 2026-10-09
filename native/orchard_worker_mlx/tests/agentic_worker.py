"""Model-free corpus backend hosted by the production Worker Runtime service."""

from __future__ import annotations

import argparse
import json
import os
import signal
import threading
import time
from collections.abc import Iterator
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Any

import grpc

from orchard_worker_mlx.backends import StubBackend
from orchard_worker_mlx.generated.orchard.worker.v1 import worker_runtime_pb2_grpc
from orchard_worker_mlx.service import WorkerRuntimeServicer


def decode(event: dict[str, Any]) -> dict[str, Any]:
    if "text" in event:
        return {"kind": "output_text_delta", "delta": event["text"]}
    if "call_id" in event:
        return {
            "kind": "tool_call_delta",
            "tool_call_id": event["call_id"],
            "delta": event["delta"],
        }
    if "fail" in event:
        return {
            "kind": "failed",
            "code": event["fail"],
            "message": "scripted failure",
            "retryable": event["retryable"],
        }
    input_tokens, output_tokens = event.get("tokens", event.get("usage"))
    usage = {
        "input_tokens": input_tokens,
        "output_tokens": output_tokens,
        "total_tokens": input_tokens + output_tokens,
    }
    if "complete" in event:
        return {
            "kind": "completed",
            "finish_reason": "FINISH_REASON_" + event["complete"].upper(),
            "usage": usage,
        }
    return {"kind": "usage", "usage": usage}


class CorpusBackend(StubBackend):
    def __init__(self, script: Path) -> None:
        super().__init__()
        self.script = script

    def generate(self, request: Any, cancel_event: threading.Event) -> Iterator[dict[str, Any]]:
        script = json.loads(self.script.read_text())
        self.script.with_suffix(".request").write_text(
            json.dumps(
                {
                    "rendered_prompt_utf8": request.rendered_prompt_utf8.decode("utf-8"),
                    "cache_affinity_fingerprint": request.cache_affinity_fingerprint,
                    "prompt_token_ids": list(request.prompt_token_ids),
                }
            )
        )
        try:
            for event in script["events"]:
                if event.get("wait_for_cancel"):
                    if not cancel_event.wait(10):
                        raise TimeoutError("corpus cancellation not observed")
                    self.script.with_suffix(".cancelled").write_text("cancelled")
                    deadline = time.monotonic() + 10
                    while not self.script.with_suffix(".release").exists():
                        if time.monotonic() >= deadline:
                            raise TimeoutError("corpus drain gate not released")
                        time.sleep(0.005)
                    self.script.with_suffix(".drained").write_text("drained")
                    yield {
                        "kind": "failed",
                        "code": "cancelled",
                        "message": "cancelled",
                        "retryable": False,
                    }
                    return
                yield decode(event)
        finally:
            self.script.with_suffix(".drained").write_text("drained")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket-path", required=True)
    args, _ = parser.parse_known_args()
    server = grpc.server(ThreadPoolExecutor(max_workers=4))
    backend = CorpusBackend(Path(os.environ["ORCHARD_AGENTIC_SCRIPT"]))
    worker_runtime_pb2_grpc.add_WorkerRuntimeServiceServicer_to_server(
        WorkerRuntimeServicer(backend), server
    )
    server.add_insecure_port(f"unix://{args.socket_path}")
    signal.signal(signal.SIGTERM, lambda *_: server.stop(grace=0))
    signal.signal(signal.SIGINT, lambda *_: server.stop(grace=0))
    server.start()
    server.wait_for_termination()


if __name__ == "__main__":
    main()
