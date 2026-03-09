from __future__ import annotations

import json

from orchard_worker_mlx import __version__
from orchard_worker_mlx.cli import build_placeholder_response, main


def test_build_placeholder_response_includes_optional_socket_path() -> None:
    payload = build_placeholder_response(socket_path="/tmp/orchard.sock")

    assert payload["component"] == "orchard_worker_mlx"
    assert payload["socket_path"] == "/tmp/orchard.sock"


def test_main_prints_placeholder_json(capsys) -> None:
    assert main(["--socket-path", "/tmp/orchard.sock"]) == 0

    payload = json.loads(capsys.readouterr().out)
    assert payload["status"] == "not_implemented"
    assert payload["socket_path"] == "/tmp/orchard.sock"


def test_main_prints_version(capsys) -> None:
    assert main(["--version"]) == 0
    assert capsys.readouterr().out.strip() == __version__
