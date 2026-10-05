"""Import and remote-code guards for the optional MLX runtime dependencies.

These guards are only exercised when the optional ``mlx`` extra is installed.
Run them with::

    mise exec -- uv run --locked --directory native/orchard_worker_mlx --extra mlx \\
        pytest tests/test_mlx_import_smoke.py

Dependency-refresh validation MUST run this way; the default dev-only environment
lacks the extra and the tests skip. See ``../README.md`` for the MLX-LM security
baseline these guards protect.
"""

from __future__ import annotations

import importlib
import importlib.metadata
import importlib.util
import inspect
import json
from pathlib import Path
from types import SimpleNamespace

import pytest

from orchard_worker_mlx.model_loader import ModelLoaderError, _default_mlx_deps

_MLX_STACK = ("mlx", "mlx_lm", "transformers", "tokenizers")
_MLX_LM_COMMIT = "ab1806e8f5d6aa035973af194a1b9198ab4754dc"
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


def _save_bpe_tokenizer(path: Path) -> None:
    tokenizers = importlib.import_module("tokenizers")
    transformers = importlib.import_module("transformers")
    backend = tokenizers.Tokenizer(
        tokenizers.models.BPE(
            {
                "[UNK]": 0,
                "a": 1,
                "<": 2,
                "n": 3,
                ">": 4,
                "b": 5,
                "a<": 6,
                "a<n": 7,
                "a<n>": 8,
                "a<n>b": 9,
                "[EOS]": 10,
            },
            merges=[("a", "<"), ("a<", "n"), ("a<n", ">"), ("a<n>", "b")],
            unk_token="[UNK]",
        )
    )
    tokenizer = transformers.TokenizersBackend(
        tokenizer_object=backend, unk_token="[UNK]", eos_token="[EOS]"
    )
    tokenizer.save_pretrained(path)


def test_production_loader_preserves_local_token_ids_and_eos(tmp_path: Path) -> None:
    """SPEC §6.4: production loading preserves local tokenizer IDs and stop tokens."""
    _save_bpe_tokenizer(tmp_path)

    loaded = _default_mlx_deps().load_tokenizer(tmp_path / "tokenizer.json")

    assert loaded.encode("a<n>b", add_special_tokens=False) == [9]
    assert loaded.decode([9]) == "a<n>b"
    assert loaded.eos_token_ids == {10}
    assert loaded.encode("[EOS]", add_special_tokens=False) == [10]


def test_registered_newline_tokenizer_preserves_preloaded_backend(tmp_path: Path) -> None:
    """Issue #57: the registered class still supports its explicit backend path."""
    _save_bpe_tokenizer(tmp_path)
    tokenizer_utils = importlib.import_module("mlx_lm.tokenizer_utils")
    tokenizer = tokenizer_utils.NewlineTokenizer(
        tokenizer_file=str(tmp_path / "tokenizer.json"), unk_token="[UNK]", eos_token="[EOS]"
    )

    assert tokenizer.encode("a\nb", add_special_tokens=False) == [9]
    assert tokenizer.decode([9]) == "a\nb"
    assert tokenizer.eos_token_id == 10


def test_production_tokenizer_rejects_custom_code_without_execution(tmp_path: Path) -> None:
    """SPEC §6.4: tokenizer metadata must not enable artifact-shipped Python."""
    _save_bpe_tokenizer(tmp_path)
    side_effect = tmp_path / "custom-tokenizer-code-executed"
    (tmp_path / "tokenization_custom.py").write_text(
        "from pathlib import Path\n"
        "from transformers import PreTrainedTokenizerFast\n"
        f"Path({str(side_effect)!r}).write_text('executed', encoding='utf-8')\n"
        "class CustomTokenizer(PreTrainedTokenizerFast):\n"
        "    pass\n",
        encoding="utf-8",
    )
    config_path = tmp_path / "tokenizer_config.json"
    config = json.loads(config_path.read_text(encoding="utf-8"))
    config["tokenizer_class"] = "CustomTokenizer"
    config["auto_map"] = {
        "AutoTokenizer": [
            "tokenization_custom.CustomTokenizer",
            "tokenization_custom.CustomTokenizer",
        ]
    }
    config_path.write_text(json.dumps(config), encoding="utf-8")

    with pytest.raises(ValueError, match="trust_remote_code"):
        _default_mlx_deps().load_tokenizer(tmp_path / "tokenizer.json")

    assert not side_effect.exists()


def test_mlx_lm_install_and_loader_signatures_match_the_approved_commit() -> None:
    """Issue #98: the resolved runtime exposes the audited default-off gates."""
    distribution = importlib.metadata.distribution("mlx-lm")
    direct_url = json.loads(distribution.read_text("direct_url.json") or "{}")

    assert direct_url["url"] == "https://github.com/ml-explore/mlx-lm.git"
    assert direct_url["vcs_info"] == {
        "vcs": "git",
        "commit_id": _MLX_LM_COMMIT,
        "requested_revision": _MLX_LM_COMMIT,
    }

    mlx_lm_utils = importlib.import_module("mlx_lm.utils")
    for function_name in ("load_model", "load", "sharded_load"):
        signature = inspect.signature(getattr(mlx_lm_utils, function_name))
        parameter = signature.parameters["trust_remote_code"]
        assert parameter.default is False

    sharded_signature = inspect.signature(mlx_lm_utils.sharded_load)
    assert sharded_signature.parameters["tokenizer_config"].default is None

    mlx_lm_tokenizer_utils = importlib.import_module("mlx_lm.tokenizer_utils")
    tokenizer_signature = inspect.signature(mlx_lm_tokenizer_utils.load)
    tokenizer_extra = tokenizer_signature.parameters["tokenizer_config_extra"]
    assert tokenizer_extra.default is None
    assert tokenizer_extra.kind is inspect.Parameter.POSITIONAL_OR_KEYWORD


def test_orchard_rejects_model_file_without_executing_it(tmp_path: Path) -> None:
    """Issue #98: production dependency wiring rejects custom model code."""
    side_effect = tmp_path / "custom-model-code-executed"
    model_file = tmp_path / "modeling_custom.py"
    model_file.write_text(
        "from pathlib import Path\n"
        f"Path({str(side_effect)!r}).write_text('executed', encoding='utf-8')\n",
        encoding="utf-8",
    )
    (tmp_path / "config.json").write_text(
        json.dumps(
            {
                "model_file": model_file.name,
                "model_type": "custom_mlx_arch",
            }
        ),
        encoding="utf-8",
    )

    mlx_lm_utils = importlib.import_module("mlx_lm.utils")
    with pytest.raises(ValueError, match="trust_remote_code=True"):
        mlx_lm_utils.load_model(tmp_path, lazy=True, strict=False)

    assert not side_effect.exists()

    deps = _default_mlx_deps()
    with pytest.raises(ModelLoaderError, match="model_file"):
        deps.load_model(tmp_path, lazy=True, strict=False)

    assert not side_effect.exists()


def test_sharded_load_propagates_explicit_remote_code_distrust(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    """Issue #98: safe sharded loading keeps both trust controls disabled."""
    mlx_lm_utils = importlib.import_module("mlx_lm.utils")
    tensor_group = object()
    model_calls: list[dict] = []
    tokenizer_calls: list[dict] = []

    class FakeModel:
        def parameters(self) -> dict:
            return {}

        def shard(self, group: object) -> None:
            assert group is tensor_group

    def fake_load_model(model_path: Path, **kwargs):
        assert model_path == tmp_path
        model_calls.append(kwargs)
        return FakeModel(), {"eos_token_id": 2}

    def fake_load_tokenizer(model_path: Path, tokenizer_config: dict, **kwargs):
        assert model_path == tmp_path
        tokenizer_calls.append(
            {
                "tokenizer_config": tokenizer_config,
                **kwargs,
            }
        )
        return object()

    fake_mx = SimpleNamespace(
        array=lambda value: value,
        cpu=object(),
        distributed=SimpleNamespace(all_sum=lambda value, stream: value),
        eval=lambda value: None,
    )
    monkeypatch.setattr(mlx_lm_utils, "_download", lambda *args, **kwargs: tmp_path)
    monkeypatch.setattr(mlx_lm_utils, "load_model", fake_load_model)
    monkeypatch.setattr(mlx_lm_utils, "load_tokenizer", fake_load_tokenizer)
    monkeypatch.setattr(mlx_lm_utils, "mx", fake_mx)

    mlx_lm_utils.sharded_load(
        "local-model",
        tensor_group=tensor_group,
        tokenizer_config={"trust_remote_code": False},
        trust_remote_code=False,
    )

    assert model_calls == [
        {"lazy": True, "strict": False, "trust_remote_code": False},
        {"lazy": True, "strict": False, "trust_remote_code": False},
    ]
    assert tokenizer_calls == [
        {
            "tokenizer_config": {"trust_remote_code": False},
            "eos_token_ids": 2,
        }
    ]
