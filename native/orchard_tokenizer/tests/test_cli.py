from __future__ import annotations

import json

from orchard_tokenizer import __version__
from orchard_tokenizer.cli import build_placeholder_response, main


def test_build_placeholder_response_identifies_scaffold() -> None:
    payload = build_placeholder_response()

    assert payload["component"] == "orchard_tokenizer"
    assert payload["status"] == "not_implemented"


def test_main_prints_placeholder_json(capsys) -> None:
    assert main([]) == 0

    payload = json.loads(capsys.readouterr().out)
    assert payload["message"].startswith("Tokenizer scaffold only")


def test_main_prints_version(capsys) -> None:
    assert main(["--version"]) == 0
    assert capsys.readouterr().out.strip() == __version__
