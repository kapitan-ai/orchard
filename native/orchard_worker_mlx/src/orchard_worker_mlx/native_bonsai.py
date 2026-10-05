"""Closed, local-only construction of the reviewed native Bonsai text model.

This module is importable without MLX. Numerical modules stay in the pinned
mlx-vlm dependency; artifact Python and native server entrypoints are never used.
"""

from __future__ import annotations

import json
import math
import re
import struct
from importlib import metadata
from pathlib import Path
from typing import Any

MODEL_TYPE = "prism_hadamard_qwen35"
NATIVE_VERSION = "0.7.2"
NATIVE_REVISION = "a74c7de90a344a2c2c7334acb4e48b57a40480e2"
_QUANTIZATION = {"bits": 2, "group_size": 128, "mode": "affine"}
_MAX_JSON_BYTES = 16 * 1024 * 1024
_DTYPE_BYTES = {"F16": 2, "BF16": 2, "F32": 4, "U32": 4}


def _json_object(data: bytes) -> dict[str, Any]:
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError(f"duplicate JSON key: {key}")
            result[key] = value
        return result

    result = json.loads(data, object_pairs_hook=unique)
    if not isinstance(result, dict):
        raise ValueError("expected JSON object")
    return result


def _read_json(path: Path) -> dict[str, Any]:
    if path.is_symlink() or not path.is_file() or path.stat().st_size > _MAX_JSON_BYTES:
        raise ValueError(f"invalid local metadata file: {path.name}")
    return _json_object(path.read_bytes())


def selects_native_bonsai(entrypoint: Path) -> bool:
    """Inspect architecture without importing optional native dependencies."""
    config = entrypoint / "config.json"
    if not config.is_file():
        return False
    try:
        value = json.loads(config.read_bytes())
    except (OSError, ValueError):
        return False
    if not isinstance(value, dict):
        return False
    selected = value.get("model_type") == MODEL_TYPE
    hadamard_marked = (
        "hadamard_config" in value
        or value.get("tensor_namespace") == "mlx-vlm-qwen3_5"
        or (
            "gdn_activation_layout" in value
            and value.get("schema_version") == 2
            and bool(value.get("modules"))
        )
    )
    if not selected and hadamard_marked:
        raise ValueError("Hadamard metadata requires the registered native architecture")
    return selected


def _validate_config(config: dict[str, Any]) -> None:
    expected = {
        "model_type": MODEL_TYPE,
        "schema_version": 2,
        "base_model_type": "qwen3_5",
        "tensor_namespace": "mlx-vlm-qwen3_5",
        "gdn_activation_layout": "grouped",
        "quantization": _QUANTIZATION,
        "components": {"text": True, "vision": True, "mtp": False},
    }
    if any(config.get(key) != value for key, value in expected.items()):
        raise ValueError("unsupported native Bonsai pack profile")
    forbidden = {
        "model_file",
        "auto_map",
        "llm_config",
        "architectures",
        "dflash_config",
        "speculators_config",
        "speculators_model_type",
        "markov_rank",
    }
    if forbidden.intersection(config):
        raise ValueError("executable or alternate native architecture declaration")
    if config.get("quantization_config") not in (None, {}, _QUANTIZATION):
        raise ValueError("alternate native quantization configuration")
    text = config.get("text_config")
    if not isinstance(text, dict) or text.get("ple_storage"):
        raise ValueError("unsupported native text configuration or external storage")
    if text.get("quantization_config") not in (None, {}, _QUANTIZATION):
        raise ValueError("alternate native text quantization configuration")
    if (
        text.get("num_hidden_layers") != 64
        or text.get("hidden_size") != 5120
        or text.get("full_attention_interval") != 4
        or text.get("vocab_size") != 248320
    ):
        raise ValueError("unsupported native Bonsai language dimensions")
    if text.get("mtp_num_hidden_layers", 0) != 0:
        raise ValueError("native MTP is outside the text evaluation profile")
    records = config.get("modules")
    if not isinstance(records, list) or len(records) != 402:
        raise ValueError("native Bonsai requires the complete 402-module pack")
    seen = set()
    expected_paths = {"lm_head", "model.embed_tokens"}
    for index in range(64):
        suffixes = ["mlp.up_proj", "mlp.down_proj", "mlp.gate_proj"]
        suffixes += (
            [f"self_attn.{projection}_proj" for projection in ("q", "k", "v", "o")]
            if (index + 1) % 4 == 0
            else ["linear_attn.out_proj", "linear_attn.in_proj_z", "linear_attn.in_proj_qkv"]
        )
        expected_paths.update(f"model.layers.{index}.{suffix}" for suffix in suffixes)
    for record in records:
        if not isinstance(record, dict):
            raise ValueError("invalid packed module record")
        path = record.get("path")
        if not isinstance(path, str) or not re.fullmatch(
            r"[A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)*", path
        ):
            raise ValueError("invalid packed module path")
        if path in seen:
            raise ValueError("duplicate packed module")
        seen.add(path)
        if path not in expected_paths or record.get("embedding") != (path == "model.embed_tokens"):
            raise ValueError("unknown native packed module or kind")
        if (
            type(record.get("block")) is not int
            or record["block"] != 1024
            or type(record.get("embedding")) is not bool
            or record.get("dtype") != "float16"
        ):
            raise ValueError("unsupported packed module layout")
    if seen != expected_paths:
        raise ValueError("incomplete native packed module paths")


def _tensor_header(path: Path) -> dict[str, Any]:
    """Reject unsupported dtypes before upstream's in-place dtype fallback."""
    if path.is_symlink() or not path.is_file():
        raise ValueError("native weights must be nonsymlink regular files")
    size = path.stat().st_size
    with path.open("rb") as source:
        prefix = source.read(8)
        if len(prefix) != 8:
            raise ValueError("truncated safetensors header")
        length = struct.unpack("<Q", prefix)[0]
        if length < 2 or length > _MAX_JSON_BYTES or length > size - 8:
            raise ValueError("invalid safetensors header length")
        header = _json_object(source.read(length))
    payload_size = size - 8 - length
    tensors = {key: value for key, value in header.items() if key != "__metadata__"}
    ranges = []
    for tensor in tensors.values():
        if not isinstance(tensor, dict) or tensor.get("dtype") not in _DTYPE_BYTES:
            raise ValueError("unsupported safetensors dtype")
        shape = tensor.get("shape")
        offsets = tensor.get("data_offsets")
        if not isinstance(shape, list) or any(type(n) is not int or n < 0 for n in shape):
            raise ValueError("invalid safetensors shape")
        if (
            not isinstance(offsets, list)
            or len(offsets) != 2
            or any(type(n) is not int for n in offsets)
            or not 0 <= offsets[0] <= offsets[1] <= payload_size
            or offsets[1] - offsets[0] != math.prod(shape) * _DTYPE_BYTES[tensor["dtype"]]
        ):
            raise ValueError("invalid safetensors byte range")
        ranges.append(tuple(offsets))
    end = 0
    for start, stop in sorted(ranges):
        if start != end:
            raise ValueError("noncontiguous or overlapping safetensors data")
        end = stop
    if not tensors or end != payload_size:
        raise ValueError("incomplete safetensors payload")
    return tensors


def validate_native_pack(entrypoint: Path) -> dict[str, Any]:
    """Validate immutable local inputs before any native import/allocation."""
    config = _read_json(entrypoint / "config.json")
    _validate_config(config)
    for name in ("offload_index.json", "hf_quant_config.json", "adapter_config.json"):
        if (entrypoint / name).exists() or (entrypoint / name).is_symlink():
            raise ValueError(f"unsupported native loader override: {name}")
    files = set(entrypoint.glob("*.safetensors"))
    if not files or any(path.name == "consolidated.safetensors" for path in files):
        raise ValueError("unsupported or absent native weights")
    index_path = entrypoint / "model.safetensors.index.json"
    weight_map = None
    if index_path.exists() or index_path.is_symlink():
        weight_map = _read_json(index_path).get("weight_map")
        if not isinstance(weight_map, dict) or not weight_map:
            raise ValueError("invalid native weight index")
        shards = set()
        for shard in weight_map.values():
            if (
                not isinstance(shard, str)
                or Path(shard).name != shard
                or not shard.endswith(".safetensors")
            ):
                raise ValueError("unsafe native shard path")
            shards.add(entrypoint / shard)
        if shards != files:
            raise ValueError("native declared shards differ from local weights")
    elif len(files) != 1 or next(iter(files)).name != "model.safetensors":
        raise ValueError("unindexed native weights must be model.safetensors")
    inventory = {}
    for path in sorted(files):
        tensors = _tensor_header(path)
        if inventory.keys() & tensors.keys():
            raise ValueError("duplicate native tensor across shards")
        if weight_map is not None and any(weight_map.get(key) != path.name for key in tensors):
            raise ValueError("native index does not match tensor ownership")
        inventory.update(tensors)
    if weight_map is not None and inventory.keys() != weight_map.keys():
        raise ValueError("native index contains missing tensors")
    if len(inventory) != 2390 or sum(key.startswith("vision_tower.") for key in inventory) != 333:
        raise ValueError("native pack requires complete language and vision tensors")
    for record in config["modules"]:
        prefix = f"language_model.{record['path']}"
        weight = inventory.get(f"{prefix}.weight", {})
        shape = weight.get("shape", [])
        if weight.get("dtype") != "U32" or len(shape) != 2:
            raise ValueError("invalid native packed weight")
        rows, packed_width = shape
        width = packed_width * 16
        if width % 1024:
            raise ValueError("invalid native Hadamard width")
        for suffix, expected_shape, expected_dtype in (
            ("scales", [rows, width // 128], "F16"),
            ("biases", [rows, width // 128], "F16"),
            ("signs", [width], "F32"),
        ):
            tensor = inventory.get(f"{prefix}.{suffix}", {})
            if tensor.get("dtype") != expected_dtype or tensor.get("shape") != expected_shape:
                raise ValueError(f"invalid native packed {suffix}")
    return config


def verify_native_dependency() -> None:
    dist = metadata.distribution("mlx-vlm")
    provenance = _json_object((dist.read_text("direct_url.json") or "{}").encode())
    vcs = provenance.get("vcs_info", {})
    if (
        dist.version != NATIVE_VERSION
        or provenance.get("url") != "https://github.com/Blaizzy/mlx-vlm.git"
        or vcs.get("vcs") != "git"
        or vcs.get("commit_id") != NATIVE_REVISION
    ):
        raise ValueError("native Bonsai dependency does not match reviewed Git source")


def _language_wrapper(language_model: Any, module_type: type, vision_tower: Any = None) -> Any:
    class NativeBonsaiLanguage(module_type):
        def __init__(self):
            super().__init__()
            self.language_model = language_model
            self.vision_tower = vision_tower

        def __call__(self, inputs, cache=None):
            return self.language_model(inputs, cache=cache).logits

        def reset_request_state(self):
            self.language_model._position_ids = None
            self.language_model._rope_deltas = None

        def make_cache(self):
            self.reset_request_state()
            return self.language_model.make_cache()

        @property
        def layers(self):
            return self.language_model.layers

    return NativeBonsaiLanguage()


def load_native_bonsai(entrypoint: Path) -> tuple[Any, Any]:
    """Reuse strict released construction; never execute artifact code."""
    validate_native_pack(entrypoint)
    verify_native_dependency()
    import mlx.nn as nn
    from mlx.utils import tree_flatten
    from mlx_vlm.models.prism_hadamard_qwen35.prism_hadamard_qwen35 import (
        HadamardQuantizedEmbedding,
        HadamardQuantizedLinear,
    )
    from mlx_vlm.utils import load_model

    native = load_model(entrypoint, lazy=True, strict=True)
    inventory = {}
    for path in entrypoint.glob("*.safetensors"):
        inventory.update(_tensor_header(path))
    if {key for key, _ in tree_flatten(native.parameters())} != inventory.keys():
        raise ValueError("native loader changed the complete tensor inventory")
    for _, layer in native.language_model.named_modules():
        if isinstance(layer, (nn.QuantizedLinear, nn.QuantizedEmbedding)) and not isinstance(
            layer, (HadamardQuantizedLinear, HadamardQuantizedEmbedding)
        ):
            raise ValueError("ordinary affine language layer survived native construction")
    return _language_wrapper(native.language_model, nn.Module, native.vision_tower), native.config
