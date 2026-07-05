"""Import smoke tests for optional MLX runtime dependencies."""

from __future__ import annotations

import json
from pathlib import Path

import pytest


def test_mlx_lm_imports_with_autotokenizer_path(tmp_path: Path) -> None:
    """Issue #57: mlx_lm import must not fail during tokenizer registration."""
    pytest.importorskip("mlx", reason="MLX optional extra is not installed")
    pytest.importorskip("mlx_lm", reason="mlx-lm optional extra is not installed")
    transformers = pytest.importorskip(
        "transformers",
        reason="transformers optional dependency is not installed",
    )
    tokenizers = pytest.importorskip("tokenizers", reason="tokenizers dependency is not installed")

    tokenizer_dir = tmp_path / "tokenizer"
    tokenizer_dir.mkdir()
    tokenizer = tokenizers.Tokenizer(tokenizers.models.WordLevel({"[UNK]": 0}, unk_token="[UNK]"))
    tokenizer.pre_tokenizer = tokenizers.pre_tokenizers.Whitespace()
    tokenizer.save(str(tokenizer_dir / "tokenizer.json"))
    (tokenizer_dir / "config.json").write_text(json.dumps({"model_type": "bert"}))
    (tokenizer_dir / "special_tokens_map.json").write_text(json.dumps({"unk_token": "[UNK]"}))
    (tokenizer_dir / "tokenizer_config.json").write_text(
        json.dumps({"model_max_length": 2048, "unk_token": "[UNK]"})
    )

    loaded = transformers.AutoTokenizer.from_pretrained(tokenizer_dir, local_files_only=True)

    assert loaded.unk_token == "[UNK]"
