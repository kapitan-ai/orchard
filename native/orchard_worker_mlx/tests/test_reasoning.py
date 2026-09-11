from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import pytest

from orchard_worker_mlx.reasoning import StatefulReasoningParser, prompt_opened_reasoning

REPO_ROOT = Path(__file__).resolve().parents[3]
CORPUS_DIR = REPO_ROOT / "proto/orchard/worker/v1/fixtures/reasoning"


def load_corpus() -> list[tuple[Path, dict[str, Any]]]:
    documents: list[tuple[Path, dict[str, Any]]] = []
    for path in sorted(CORPUS_DIR.glob("*.json")):
        with path.open(encoding="utf-8") as fixture_file:
            document = json.load(fixture_file)
        assert isinstance(document, dict), f"{path} must contain an object"
        documents.append((path, document))
    return documents


CORPUS = load_corpus()
CASES = [(path, document, case) for path, document in CORPUS for case in document.get("cases", [])]


def case_id(case: dict[str, Any]) -> str:
    return str(case["id"])


@pytest.mark.parametrize(
    ("path", "document", "case"),
    CASES,
    ids=[case_id(case) for _path, _document, case in CASES],
)
def test_reasoning_corpus_cases(
    path: Path,
    document: dict[str, Any],
    case: dict[str, Any],
) -> None:
    assert document["schema_version"] == "reasoning-corpus/v1", path
    parser = StatefulReasoningParser(
        parser_family=document["parser_family"],
        parser_version=document["parser_version"],
        generation_policy=case["generation_policy"],
        render_contract=document["render_contract"],
        render_contract_version=document["render_contract_version"],
        synthetic_prompt_opened_render_contracts=tuple(
            tuple(pair) for pair in document.get("synthetic_prompt_opened_render_contracts", [])
        ),
    )

    output = "".join(parser.push(chunk).final_text for chunk in case["chunks"])
    terminal = parser.finish(case["terminal"])
    expected = case["expected"]

    assert output == expected["final_text"]
    assert terminal.failure_code == expected["failure_code"]
    assert terminal.failure_reason == expected["failure_reason"]

    snapshot = parser.snapshot()
    assert len(snapshot.pending_marker) < len("</think>")
    assert not hasattr(snapshot, "reasoning_text")
    _assert_boundary(case.get("boundary"), output)


def _assert_boundary(boundary: dict[str, str] | None, output: str) -> None:
    if boundary is None:
        return
    assert output == boundary["downstream_input"]
    if boundary["kind"] == "tool":
        return
    assert boundary["kind"] == "stop"
    assert output.split(boundary["sequence"], 1)[0] == boundary["after_stop"]


def test_corpus_matrix_is_complete_and_case_ids_are_unique() -> None:
    assert CORPUS, "the reasoning corpus must contain at least one fixture"
    required_coverage = {
        "policy:model_default",
        "policy:disabled",
        "policy:enabled",
        "split_marker",
        "chunk_boundary",
        "unicode",
        "nested_marker",
        "stray_marker",
        "unclosed_marker",
        "late_open_marker",
        "incomplete_marker",
        "tool_boundary",
        "stop_boundary",
        "terminal:completed",
        "terminal:stop",
        "terminal:length",
        "terminal:cancelled",
        "terminal:deadline",
        "leakage",
        "no_marker",
    }
    ids: set[str] = set()

    for path, document in CORPUS:
        assert document["parser_family"] in {"tagged_pair", "prompt_opened"}, path
        assert document["parser_version"] == "v1", path
        coverage = {label for case in document["cases"] for label in case["coverage"]}
        assert required_coverage <= coverage, path
        for case in document["cases"]:
            assert case_id(case) not in ids
            ids.add(case_id(case))

    assert {document["parser_family"] for _path, document in CORPUS} == {
        "tagged_pair",
        "prompt_opened",
    }


def test_prompt_opened_requires_an_exact_closed_render_mapping() -> None:
    assert not prompt_opened_reasoning("synthetic.prompt_opened", "v1")
    assert prompt_opened_reasoning(
        "synthetic.prompt_opened",
        "v1",
        synthetic_prompt_opened_render_contracts=(("synthetic.prompt_opened", "v1"),),
    )
    with pytest.raises(ValueError, match="unqualified_prompt_opened_render_contract"):
        StatefulReasoningParser(
            parser_family="prompt_opened",
            parser_version="v1",
            generation_policy="model_default",
            render_contract="synthetic.prompt_opened",
            render_contract_version="v1",
        )


def test_reasoning_parser_has_no_mlx_or_provider_imports() -> None:
    source = (
        REPO_ROOT / "native/orchard_worker_mlx/src/orchard_worker_mlx/reasoning.py"
    ).read_text(encoding="utf-8")
    assert "import mlx" not in source
    assert "import mlx_lm" not in source
    assert "from orchard_worker_mlx.generation" not in source
