"""Artifact and assembly admission before any native module import."""

import json
import sys
from dataclasses import replace
from hashlib import sha256
from types import ModuleType, SimpleNamespace
from unittest.mock import Mock

import pytest
from orchard_worker_mlx.backends import BackendError
from orchard_worker_mlx.model_loader import ModelLoaderError
from test_admission import profile as profile
from test_tensorfold_driver import bounds as bounds

from orchard_tensorfold_http import native_factory


def tree_hash(root):
    digest = sha256()
    for path in sorted(p for p in root.rglob("*") if p.is_file()):
        digest.update(path.relative_to(root).as_posix().encode())
        digest.update(path.read_bytes())
    return digest.hexdigest()


def test_artifact_tree_digest_bounded_inventory_and_changes(tmp_path):
    (tmp_path / "nested").mkdir()
    (tmp_path / "nested" / "b").write_bytes(b"b")
    (tmp_path / "a").write_bytes(b"a")
    expected = tree_hash(tmp_path)
    native_factory.verify_artifact(tmp_path, expected, max_files=4, max_bytes=2)
    for limits in [{"max_files": 3, "max_bytes": 2}, {"max_files": 4, "max_bytes": 1}]:
        with pytest.raises(ValueError, match="bound"):
            native_factory.verify_artifact(tmp_path, expected, **limits)
    (tmp_path / "a").write_bytes(b"x")
    with pytest.raises(ValueError, match="identity"):
        native_factory.verify_artifact(tmp_path, expected, max_files=4, max_bytes=2)


def test_artifact_symlink_never_followed(tmp_path):
    (tmp_path / "link").symlink_to("/not/an/admitted/file")
    with pytest.raises(ValueError, match="unsupported"):
        native_factory.verify_artifact(tmp_path, "0" * 64, max_files=3, max_bytes=10)


def test_file_growing_after_inventory_cannot_extend_hashing_bound(tmp_path, monkeypatch):
    path = tmp_path / "asset"
    path.write_bytes(b"a")
    expected = tree_hash(tmp_path)
    fdopen = native_factory.os.fdopen

    class GrowingStream:
        def __init__(self, descriptor, mode):
            self.stream = fdopen(descriptor, mode)

        def __enter__(self):
            return self

        def __exit__(self, *args):
            self.stream.close()

        def fileno(self):
            return self.stream.fileno()

        def read(self, size):
            assert size <= 2
            with path.open("ab") as append:
                append.write(b"grow")
            return self.stream.read(size)

    monkeypatch.setattr(native_factory.os, "fdopen", GrowingStream)
    with pytest.raises(ValueError, match="read exceeds"):
        native_factory.verify_artifact(tmp_path, expected, max_files=2, max_bytes=1)


@pytest.fixture
def assembly(tmp_path, monkeypatch, profile, bounds):
    bounds = native_bounds(bounds)
    template = tmp_path / "template.jinja"
    template.write_text("{{ messages | tojson }}{% if add_generation_prompt %}<think>{% endif %}")
    config = tmp_path / "tokenizer_config.json"
    (tmp_path / "tokenizer.json").write_text("{}")
    config.write_text(json.dumps({"tool_parser_type": "qwen3_coder"}))
    (tmp_path / "config.json").write_text(json.dumps({"model_type": "qwen3_5"}))
    profile = replace(
        profile,
        max_input_tokens=bounds.max_input_tokens,
        vocabulary_size=bounds.vocabulary_size,
        max_output_tokens=bounds.max_output_tokens,
        max_context_tokens=bounds.max_context_tokens,
        max_request_seconds=bounds.request_seconds,
        template_digest=sha256(template.read_bytes()).hexdigest(),
        tokenizer_config_digest=sha256(config.read_bytes()).hexdigest(),
        artifact_digest=tree_hash(tmp_path),
    )
    manifest = SimpleNamespace(
        model_id=profile.model_id,
        version=profile.version,
        format="mlx",
        artifact_layout="directory",
        entrypoint=".",
        runtime_requirements=SimpleNamespace(adapter="mlx_lm"),
        tokenizer=SimpleNamespace(kind="huggingface_tokenizer_json", path="tokenizer.json"),
        chat_template=SimpleNamespace(path=template.name, sha256=profile.template_digest),
    )
    monkeypatch.setattr(native_factory, "version", lambda name: native_factory._TUPLE[name])
    monkeypatch.setattr(native_factory, "load_manifest", lambda _: manifest)
    factory = native_factory.NativeFactory(
        bounds=bounds,
        model_path=tmp_path,
        max_bundle_files=10,
        max_bundle_bytes=10000,
        prefill_step=2,
        cache_limit_bytes=64,
    )
    factory._assemble = Mock(return_value="fake-native-assets")
    return SimpleNamespace(factory=factory, profile=profile, manifest=manifest, path=tmp_path)


def test_exact_identity_assembles_without_native_import(assembly):
    assert assembly.factory(str(assembly.path), assembly.profile, Mock()) == "fake-native-assets"
    assert "mlx.core" not in sys.modules and "tensorfold" not in sys.modules
    assembly.factory._assemble.assert_called_once()
    render = assembly.factory._assemble.call_args.args[2]
    assert render([{"role": "assistant", "content": "opaque</think>\n\n"}]).endswith("<think>")


@pytest.mark.parametrize("layout", ["directory", "different_file"])
def test_tokenizer_declares_exact_loader_file_and_directory(assembly, layout):
    if layout == "directory":
        assembly.manifest.tokenizer.path = "."
    else:
        directory = assembly.path / "other"
        directory.mkdir()
        (directory / "tokenizer.json").write_text("{}")
        assembly.manifest.tokenizer.path = "other/tokenizer.json"
    profile = replace(assembly.profile, artifact_digest=tree_hash(assembly.path))
    with pytest.raises(BackendError, match="tokenizer layout"):
        assembly.factory(str(assembly.path), profile, Mock())
    assembly.factory._assemble.assert_not_called()


@pytest.fixture
def fake_native(monkeypatch):
    # Execute the real assembly function while supplying CPU-only native APIs.
    # This catches the previous dict-sampling/loader-interface mismatch without
    # importing MLX, loading weights or claiming native physical settlement.
    def module(name, **attributes):
        item = ModuleType(name)
        item.__dict__.update(attributes)
        monkeypatch.setitem(sys.modules, name, item)
        return item

    class Array:
        pass

    class Cache:
        def __init__(self):
            self.values = [Array()]

    class Sampling:
        def __init__(self, **values):
            self.__dict__.update(values)

    mx = module(
        "mlx.core",
        array=Array,
        eval=Mock(),
        synchronize=Mock(),
        get_active_memory=Mock(return_value=11),
        get_cache_memory=Mock(return_value=22),
        get_peak_memory=Mock(return_value=33),
        reset_peak_memory=Mock(),
        set_cache_limit=Mock(return_value=0),
    )
    module("mlx", core=mx)
    module("mlx_lm.models.cache", ArraysCache=Cache, KVCache=Cache)
    module("tensorfold.engine.alternating_kv", AlternatingKVCache=Cache)
    seed_for = Mock(return_value=123)
    module("tensorfold.engine.exact_sampling", Sampling=Sampling, seed_for=seed_for)
    lane = Mock(return_value="fake-lane")
    module("tensorfold.engine.lane_engine", LaneEngine=lane)
    plan = Mock(return_value="fake-plan")
    markers = Mock(return_value=((10,), (10, 11)))
    module("tensorfold.engine.prefill_plan", PrefillPlan=plan, message_markers=markers)
    tokenizer = SimpleNamespace(eos_token_ids=[1], encode=Mock(return_value=[2]))
    family = object()
    load_calls = []

    def load(*args, **kwargs):
        load_calls.append(mx.set_cache_limit.call_count)
        return family, tokenizer

    module("tensorfold.families.qwen3_5", load=load)
    module(
        "tensorfold.server.memory_budget",
        cache_nbytes=Mock(return_value=44),
        process_footprint=Mock(return_value=55),
    )
    constructor = Mock(return_value="fake-driver")
    monkeypatch.setattr(native_factory.TensorFoldDriver, "from_tensorfold", constructor)
    return SimpleNamespace(
        mx=mx,
        cache=Cache,
        plan=plan,
        markers=markers,
        lane=lane,
        tokenizer=tokenizer,
        constructor=constructor,
        seed_for=seed_for,
        load_calls=load_calls,
    )


def test_native_assembly_sampling_and_cache_barriers_with_fake_imports(assembly, fake_native):
    assets = native_factory.NativeFactory._assemble(
        assembly.factory, assembly.path, assembly.profile, Mock(), Mock()
    )
    mx, Cache = fake_native.mx, fake_native.cache
    markers, plan, lane = fake_native.markers, fake_native.plan, fake_native.lane
    tokenizer, constructor = fake_native.tokenizer, fake_native.constructor
    seed_for = fake_native.seed_for
    markers.assert_called_once()
    assert markers.call_args.args[0]._tokenizer is tokenizer
    assert tokenizer._chat_template is not None
    plan.assert_called_once_with(2, (10,), 2, (10, 11))
    assert lane.call_args.kwargs["prefill_plan"] == "fake-plan"
    assert assets.make_sampling((1, 2), 0, 0.95) is None
    sampling = assets.make_sampling((1, 2), 0.6, 0.8)
    assert (
        sampling.seed,
        sampling.temperature,
        sampling.top_p,
        sampling.top_k,
        sampling.min_p,
    ) == (123, 0.6, 0.8, 0, 0)
    seed_for.assert_called_once_with((1, 2), salt=0)
    hooks = constructor.call_args.kwargs
    cache = [Cache()]
    assert hooks["copy_bounds"](cache) == (assembly.factory.bounds.working_bytes,) * 2
    with pytest.raises(ValueError, match="not admitted"):
        hooks["copy_bounds"]([object()])
    assert hooks["copy_settlement"](None, cache) is True
    assert hooks["request_settlement"](None) is True
    assert mx.synchronize.call_count == 2 and mx.eval.call_count == 1
    assert assets.encode("text") == [2]
    tokenizer.encode.assert_called_once_with("text", add_special_tokens=False)


@pytest.mark.parametrize("fault", ["path", "tuple", "bounds", "digest", "manifest", "template"])
def test_identity_faults_reject_before_assembly(assembly, monkeypatch, fault):
    path, profile = assembly.path, assembly.profile
    if fault == "path":
        path = path / "other"
    elif fault == "tuple":
        monkeypatch.setattr(native_factory, "version", lambda _name: "other")
    elif fault == "bounds":
        profile = replace(profile, max_context_tokens=profile.max_context_tokens + 1)
    elif fault == "digest":
        profile = replace(profile, artifact_digest="0" * 64)
    elif fault == "manifest":
        assembly.manifest.model_id = "other"
    elif fault == "template":
        assembly.manifest.chat_template.sha256 = "0" * 64
    with pytest.raises((BackendError, ValueError)):
        assembly.factory(str(path), profile, Mock())
    assembly.factory._assemble.assert_not_called()


@pytest.mark.parametrize(
    "filename,change",
    [
        ("config.json", {"model_type": "other"}),
        ("config.json", {"model_type": "qwen3_5", "auto_map": {"x": "remote"}}),
        ("config.json", {"model_type": "qwen3_5", "model_file": "custom.py"}),
        ("tokenizer_config.json", {"tool_parser_type": "other"}),
        ("tokenizer_config.json", {"tool_parser_type": "qwen3_coder", "auto_map": {"x": "remote"}}),
    ],
)
def test_custom_or_other_profile_refused_without_native_load(assembly, filename, change):
    (assembly.path / filename).write_text(json.dumps(change))
    profile = replace(assembly.profile, artifact_digest=tree_hash(assembly.path))
    if filename == "tokenizer_config.json":
        profile = replace(
            profile,
            tokenizer_config_digest=sha256((assembly.path / filename).read_bytes()).hexdigest(),
        )
    with pytest.raises((BackendError, ModelLoaderError)):
        assembly.factory(str(assembly.path), profile, Mock())
    assembly.factory._assemble.assert_not_called()


def native_bounds(bounds, *, leases=None, total=None):
    """Bounds the pinned scheduler's per-request copy peak fits; overrides make them short."""
    leases = (
        native_factory.required_cache_leases(bounds.checkpoint_slots) if leases is None else leases
    )
    working = bounds.working_bytes
    minimum = working + bounds.workspace_bytes + (leases + 1) * working
    return replace(
        bounds, max_cache_leases=leases, total_budget_bytes=minimum if total is None else total
    )


def build_factory(bounds, tmp_path):
    return native_factory.NativeFactory(
        bounds=bounds,
        model_path=tmp_path,
        max_bundle_files=10,
        max_bundle_bytes=10000,
        prefill_step=2,
        cache_limit_bytes=64,
    )


def test_required_cache_leases_covers_the_pinned_per_request_peak():
    # retained slots + borrowed prefix copy + history and stable-prefix snapshots
    # + interrupted-prefill progress copy, under TensorFold 0.6.6 prompt_fill.
    assert native_factory.required_cache_leases(1) == 5
    assert native_factory.required_cache_leases(2) == 6
    assert native_factory.required_cache_leases(2, 1) == 7


def test_factory_accepts_bounds_at_the_custody_minimum(bounds, tmp_path):
    factory = build_factory(native_bounds(bounds), tmp_path)
    assert factory.bounds.max_cache_leases == native_factory.required_cache_leases(1)


def test_factory_refuses_a_lease_bound_below_the_per_request_peak(bounds, tmp_path):
    short = native_bounds(bounds, leases=native_factory.required_cache_leases(1) - 1)
    with pytest.raises(ValueError, match="cache lease bound is below"):
        build_factory(short, tmp_path)


def test_factory_refuses_a_budget_that_cannot_hold_the_lease_bound(bounds, tmp_path):
    full = native_bounds(bounds)
    with pytest.raises(ValueError, match="custody budget cannot hold"):
        build_factory(replace(full, total_budget_bytes=full.total_budget_bytes - 1), tmp_path)


def test_native_assembly_observes_memory_without_other_limits_or_clearing(
    assembly, fake_native, caplog
):
    # MLX counters and TensorFold's footprint and size estimates feed the
    # observer; the configured cache limit is the only allocator setting.
    caplog.set_level("INFO", logger="orchard_tensorfold_http.memory_observation")
    native_factory.NativeFactory._assemble(
        assembly.factory, assembly.path, assembly.profile, Mock(), Mock()
    )
    observer = fake_native.constructor.call_args.kwargs["memory_observer"]
    observer.request_start(SimpleNamespace(leases=0, held_bytes=0), 0)
    observer.copied([object()])
    observer.phase("settled_after_release", SimpleNamespace(leases=1, held_bytes=12), 1)
    observer._writer.join()
    messages = [r.getMessage() for r in caplog.records]
    assert "active=11 cache=22 peak=33 footprint=55" in messages[0]
    assert "copies=1 copy_bytes_est=44" in messages[-1]
    fake_native.mx.reset_peak_memory.assert_called_once()
    for name in ("set_memory_limit", "set_wired_limit", "clear_cache"):
        assert name not in vars(fake_native.mx)
    assert fake_native.mx.synchronize.call_count == 0


def test_native_assembly_bounds_the_mlx_cache_before_weights_load(assembly, fake_native):
    # MLX's default freed-buffer cache limit is close to RAM; without a bound,
    # buffers freed by each long prefill stay held by the Worker.
    native_factory.NativeFactory._assemble(
        assembly.factory, assembly.path, assembly.profile, Mock(), Mock()
    )
    fake_native.mx.set_cache_limit.assert_called_once_with(64)
    assert fake_native.load_calls == [1]


@pytest.mark.parametrize("value", [0, -1, True, 1.5, "64", None])
def test_factory_refuses_a_cache_limit_that_is_not_a_positive_integer(bounds, tmp_path, value):
    with pytest.raises(ValueError, match="MLX cache limit"):
        native_factory.NativeFactory(
            bounds=native_bounds(bounds),
            model_path=tmp_path,
            max_bundle_files=10,
            max_bundle_bytes=10000,
            prefill_step=2,
            cache_limit_bytes=value,
        )
