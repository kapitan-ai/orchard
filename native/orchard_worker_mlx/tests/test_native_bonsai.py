"""Model-free SPEC §6.4 native construction and immutability regressions.

The config fixture is public metadata from prism-ml/Ternary-Bonsai-2-27B-mlx-2bit
at fcba37d2117a7077eac6b613b2668d14d9779edd. Payloads here are synthetic zeros:
they exercise the owned admission boundary, never native numerical correctness.
"""

from __future__ import annotations

import inspect
import json
import struct
import sys
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock

import pytest

from orchard_worker_mlx import native_bonsai as bonsai
from orchard_worker_mlx.generation import _synchronize_then_clear_session_cache


def config_fixture():
    return json.loads((Path(__file__).parent / "fixtures/bonsai/config.json").read_text())


def write_weights(path, tensors):
    offset = 0
    sizes = {"F16": 2, "BF16": 2, "F32": 4, "U32": 4}
    header = {}
    for name, (dtype, shape) in tensors.items():
        count = 1
        for n in shape:
            count *= n
        size = count * sizes.get(dtype, 1)
        header[name] = {"dtype": dtype, "shape": shape, "data_offsets": [offset, offset + size]}
        offset += size
    raw = json.dumps(header).encode()
    path.write_bytes(struct.pack("<Q", len(raw)) + raw + bytes(offset))
    return header


@pytest.fixture
def pack(tmp_path):
    config = config_fixture()
    (tmp_path / "config.json").write_text(json.dumps(config))
    tensors = {}
    for record in config["modules"]:
        prefix = f"language_model.{record['path']}"
        tensors[f"{prefix}.weight"] = ("U32", [1, 64])
        tensors[f"{prefix}.scales"] = ("F16", [1, 8])
        tensors[f"{prefix}.biases"] = ("F16", [1, 8])
        tensors[f"{prefix}.signs"] = ("F32", [1024])
    tensors.update({f"vision_tower.synthetic{i}": ("F16", [1]) for i in range(333)})
    tensors.update({f"language_model.synthetic{i}": ("F32", [1]) for i in range(449)})
    write_weights(tmp_path / "model.safetensors", tensors)
    return tmp_path


def test_complete_pack_admitted_without_native_import(pack, monkeypatch):
    before = (pack / "model.safetensors").read_bytes()
    assert bonsai.selects_native_bonsai(pack)
    assert len(bonsai.validate_native_pack(pack)["modules"]) == 402
    assert (pack / "model.safetensors").read_bytes() == before


def test_mislabeled_hadamard_pack_cannot_fall_back_to_affine(pack):
    config = config_fixture()
    config["model_type"] = "qwen3_5"
    (pack / "config.json").write_text(json.dumps(config))
    with pytest.raises(ValueError, match="requires the registered native"):
        bonsai.selects_native_bonsai(pack)


def test_ordinary_selection_preserves_upstream_config_parsing(tmp_path):
    config = tmp_path / "config.json"
    config.write_text('{"model_type":"other","model_type":"qwen3_5","tensor_namespace":"ordinary"}')
    assert not bonsai.selects_native_bonsai(tmp_path)
    config.rename(tmp_path / "target")
    config.symlink_to(tmp_path / "target")
    assert not bonsai.selects_native_bonsai(tmp_path)
    config.unlink()
    config.write_text("invalid JSON")
    assert not bonsai.selects_native_bonsai(tmp_path)


@pytest.mark.parametrize(
    "field,value",
    [
        ("schema_version", 1),
        ("tensor_namespace", "gguf"),
        ("gdn_activation_layout", "interleaved"),
        ("base_model_type", "qwen3_5_text"),
        ("quantization", {"bits": 4}),
        ("components", {"text": True}),
        ("model_file", "runtime/artifact.py"),
        ("auto_map", {}),
        ("architectures", ["BoundaryExtractor"]),
        ("dflash_config", {}),
        ("speculators_model_type", "other"),
        ("markov_rank", 1),
        ("quantization_config", {"format": "mxfp4-pack-quantized"}),
    ],
)
def test_config_override_rejected_before_construction(field, value):
    config = config_fixture()
    config[field] = value
    with pytest.raises(ValueError):
        bonsai._validate_config(config)


@pytest.mark.parametrize(
    "field,value",
    [("path", "../escape"), ("block", True), ("block", 0), ("dtype", "bfloat16"), ("embedding", 1)],
)
def test_invalid_packed_record_rejected(field, value):
    config = config_fixture()
    config["modules"][0][field] = value
    with pytest.raises(ValueError):
        bonsai._validate_config(config)


def test_incomplete_duplicate_or_external_storage_config_rejected():
    for mutation in ("incomplete", "duplicate", "storage", "text_quantization", "dimensions"):
        config = config_fixture()
        if mutation == "incomplete":
            config["modules"].pop()
        elif mutation == "duplicate":
            config["modules"][0] = config["modules"][1]
        elif mutation == "storage":
            config["text_config"]["ple_storage"] = {"manifest": "../outside"}
        elif mutation == "text_quantization":
            config["text_config"]["quantization_config"] = {"quant_method": "modelopt"}
        else:
            config["text_config"]["hidden_size"] = 12
        with pytest.raises(ValueError):
            bonsai._validate_config(config)


@pytest.mark.parametrize(
    "name", ["offload_index.json", "hf_quant_config.json", "adapter_config.json"]
)
def test_loader_override_rejected(pack, name):
    (pack / name).write_text("{}")
    with pytest.raises(ValueError, match="override"):
        bonsai.validate_native_pack(pack)


@pytest.mark.parametrize(
    "shard", ["../model.safetensors", "/tmp/model.safetensors", "missing.safetensors"]
)
def test_index_cannot_escape_or_drop_missing_shards(pack, shard):
    (pack / "model.safetensors.index.json").write_text(json.dumps({"weight_map": {"x": shard}}))
    with pytest.raises(ValueError):
        bonsai.validate_native_pack(pack)


def test_shard_index_reconciles_all_keys_and_owners(pack):
    tensors = bonsai._tensor_header(pack / "model.safetensors")
    index = {"weight_map": {key: "model.safetensors" for key in tensors}}
    (pack / "model.safetensors.index.json").write_text(json.dumps(index))
    bonsai.validate_native_pack(pack)
    index["weight_map"]["absent"] = "model.safetensors"
    (pack / "model.safetensors.index.json").write_text(json.dumps(index))
    with pytest.raises(ValueError, match="missing tensors"):
        bonsai.validate_native_pack(pack)


def test_malformed_json_and_symlink_weights_fail_closed(pack):
    (pack / "model.safetensors.index.json").write_text('{"weight_map":{},"weight_map":{}}')
    with pytest.raises(ValueError, match="duplicate"):
        bonsai.validate_native_pack(pack)
    (pack / "model.safetensors.index.json").unlink()
    original = pack / "model.safetensors"
    original.rename(pack / "hidden-weights")
    original.symlink_to(pack / "hidden-weights")
    with pytest.raises(ValueError, match="nonsymlink"):
        bonsai.validate_native_pack(pack)


def test_unsupported_dtype_never_reaches_rewriting_loader(tmp_path):
    path = tmp_path / "bad.safetensors"
    write_weights(path, {"unsafe": ("F8_E8M0", [1])})
    before = path.read_bytes()
    with pytest.raises(ValueError, match="dtype"):
        bonsai._tensor_header(path)
    assert path.read_bytes() == before


@pytest.mark.parametrize(
    "header,payload",
    [
        ({"x": {"dtype": "U32", "shape": [1], "data_offsets": [0, 8]}}, bytes(8)),
        ({"x": {"dtype": "U32", "shape": [True], "data_offsets": [0, 4]}}, bytes(4)),
        ({"x": {"dtype": "U32", "shape": [1], "data_offsets": [4, 8]}}, bytes(8)),
        (
            {
                "x": {"dtype": "U32", "shape": [1], "data_offsets": [0, 4]},
                "y": {"dtype": "U32", "shape": [1], "data_offsets": [0, 4]},
            },
            bytes(4),
        ),
        ({"x": {"dtype": "U32", "shape": [1], "data_offsets": [0, 4]}}, bytes(8)),
    ],
)
def test_invalid_tensor_ranges_rejected(tmp_path, header, payload):
    raw = json.dumps(header).encode()
    path = tmp_path / "model.safetensors"
    path.write_bytes(struct.pack("<Q", len(raw)) + raw + payload)
    with pytest.raises(ValueError):
        bonsai._tensor_header(path)


def test_missing_vision_and_wrong_sign_width_rejected(pack):
    tensors = bonsai._tensor_header(pack / "model.safetensors")
    shapes = {name: (tensor["dtype"], tensor["shape"]) for name, tensor in tensors.items()}
    sign = next(name for name in shapes if name.endswith(".signs"))
    shapes[sign] = ("F32", [512])
    write_weights(pack / "model.safetensors", shapes)
    with pytest.raises(ValueError, match="signs"):
        bonsai.validate_native_pack(pack)
    shapes.pop("vision_tower.synthetic0")
    write_weights(pack / "model.safetensors", shapes)
    with pytest.raises(ValueError, match="complete language and vision"):
        bonsai.validate_native_pack(pack)


def test_wrong_sign_dtype_rejected(pack):
    tensors = bonsai._tensor_header(pack / "model.safetensors")
    shapes = {name: (tensor["dtype"], tensor["shape"]) for name, tensor in tensors.items()}
    sign = next(name for name in shapes if name.endswith(".signs"))
    shapes[sign] = ("F16", shapes[sign][1])
    write_weights(pack / "model.safetensors", shapes)
    with pytest.raises(ValueError, match="signs"):
        bonsai.validate_native_pack(pack)


@pytest.mark.parametrize(
    "version,commit,url",
    [
        ("0.7.2", bonsai.NATIVE_REVISION, "https://github.com/Blaizzy/mlx-vlm.git"),
        ("0.7.3", bonsai.NATIVE_REVISION, "https://github.com/Blaizzy/mlx-vlm.git"),
        ("0.7.2", "wrong", "https://github.com/Blaizzy/mlx-vlm.git"),
        ("0.7.2", bonsai.NATIVE_REVISION, "https://example.com/other"),
    ],
)
def test_dependency_provenance(version, commit, url, monkeypatch):
    dist = SimpleNamespace(
        version=version,
        read_text=lambda _: json.dumps(
            {"url": url, "vcs_info": {"vcs": "git", "commit_id": commit}}
        ),
    )
    monkeypatch.setattr(bonsai.metadata, "distribution", lambda _: dist)
    if version == "0.7.2" and commit == bonsai.NATIVE_REVISION and "Blaizzy" in url:
        bonsai.verify_native_dependency()
    else:
        with pytest.raises(ValueError, match="reviewed Git source"):
            bonsai.verify_native_dependency()


def test_wrapper_uses_language_logits_retains_vision_and_resets_each_request():
    language = Mock()
    language.return_value.logits = "logits"
    language.layers = ["layer"]
    language.make_cache.side_effect = [["cache1"], ["cache2"]]
    vision = object()
    wrapper = bonsai._language_wrapper(language, object, vision)
    assert wrapper.language_model is language and wrapper.vision_tower is vision
    assert "input_embeddings" not in inspect.signature(wrapper.__call__).parameters
    for expected in (["cache1"], ["cache2"]):
        language._position_ids, language._rope_deltas = "stale", "stale"
        assert wrapper.make_cache() == expected
        assert language._position_ids is None and language._rope_deltas is None
    assert wrapper([1], cache=["kv"]) == "logits"
    language.assert_called_once_with([1], cache=["kv"])
    assert wrapper.layers == ["layer"]


def test_request_finalization_synchronizes_before_position_reset_and_cache_clear():
    order = []
    session = SimpleNamespace(
        reset_request_state=lambda: order.append("reset"), clear_cache=lambda: order.append("clear")
    )
    _synchronize_then_clear_session_cache(session, lambda: order.append("sync"))
    assert order == ["sync", "reset", "clear"]


def test_failed_synchronize_poisoned_session_still_runs_reset_and_clear(caplog):
    order = []
    session = SimpleNamespace(
        native_settlement_failed=False,
        reset_request_state=lambda: order.append("reset"),
        clear_cache=lambda: order.append("clear"),
    )
    _synchronize_then_clear_session_cache(session, Mock(side_effect=ValueError("sync failure")))
    assert session.native_settlement_failed is True
    assert order == ["reset", "clear"]
    assert "native settlement failed; Worker restart required" in caplog.text


def test_failed_reset_and_cache_cleanup_are_logged_without_poisoning_session(caplog):
    session = SimpleNamespace(native_settlement_failed=False)
    session.reset_request_state = Mock(side_effect=ValueError("reset failure"))
    session.clear_cache = Mock(side_effect=ValueError("clear failure"))
    _synchronize_then_clear_session_cache(session, lambda: None)
    session.clear_cache.assert_called_once()
    assert session.native_settlement_failed is False
    assert "request state reset failed" in caplog.text
    assert "request cache cleanup failed" in caplog.text


def test_native_loading_is_local_strict_and_preserves_inventory(pack, monkeypatch):
    inventory = bonsai._tensor_header(pack / "model.safetensors")
    native = SimpleNamespace(
        language_model=SimpleNamespace(named_modules=lambda: []),
        vision_tower=object(),
        config={"eos_token_id": [248044, 248046]},
        parameters=lambda: inventory,
    )
    loader = Mock(return_value=native)
    monkeypatch.setattr(bonsai, "verify_native_dependency", lambda: None)

    class Quantized:
        pass

    fake_nn = SimpleNamespace(
        Module=object, QuantizedLinear=Quantized, QuantizedEmbedding=Quantized
    )
    for name, module in {
        "mlx": SimpleNamespace(nn=fake_nn),
        "mlx.nn": fake_nn,
        "mlx.utils": SimpleNamespace(tree_flatten=lambda params: list(params.items())),
        "mlx_vlm": SimpleNamespace(),
        "mlx_vlm.utils": SimpleNamespace(load_model=loader),
        "mlx_vlm.models.prism_hadamard_qwen35.prism_hadamard_qwen35": SimpleNamespace(
            HadamardQuantizedEmbedding=type("Embedding", (), {}),
            HadamardQuantizedLinear=type("Linear", (), {}),
        ),
    }.items():
        monkeypatch.setitem(sys.modules, name, module)
    wrapper, config = bonsai.load_native_bonsai(pack)
    assert wrapper.vision_tower is native.vision_tower
    assert config == native.config
    loader.assert_called_once_with(pack, lazy=True, strict=True)
    native.parameters = lambda: {}
    with pytest.raises(ValueError, match="inventory"):
        bonsai.load_native_bonsai(pack)
    native.parameters = lambda: inventory
    native.language_model.named_modules = lambda: [("unsafe", Quantized())]
    with pytest.raises(ValueError, match="ordinary affine"):
        bonsai.load_native_bonsai(pack)
