"""Import smoke tests for optional MLX runtime dependencies.

The issue #57 regression guard is only exercised when the optional ``mlx`` extra
is installed. Run it with::

    mise exec -- uv run --directory native/orchard_worker_mlx --extra mlx \\
        pytest tests/test_mlx_import_smoke.py

Dependency-refresh validation MUST run this way; the default dev-only environment
lacks the extra and the test skips.
"""

from __future__ import annotations

import importlib
import importlib.util
import json
from pathlib import Path

import pytest

_MLX_STACK = ("mlx", "mlx_lm", "transformers", "tokenizers")
_missing = [name for name in _MLX_STACK if importlib.util.find_spec(name) is None]

pytestmark = pytest.mark.skipif(
    bool(_missing),
    reason=f"MLX optional extra is not installed (missing: {', '.join(_missing)})",
)


def test_mlx_lm_imports_with_autotokenizer_path(tmp_path: Path) -> None:
    """Issue #57: mlx_lm import must not fail during tokenizer registration."""
    importlib.import_module("mlx")
    importlib.import_module("mlx_lm")
    transformers = importlib.import_module("transformers")
    tokenizers = importlib.import_module("tokenizers")

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
