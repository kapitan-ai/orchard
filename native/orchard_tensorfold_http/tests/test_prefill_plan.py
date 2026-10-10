"""SPEC §7.2.9: thinking-only startup and pinned 0.6.6 prefill planning, on CPU."""

import importlib.machinery
import importlib.util
import re
import sys
from hashlib import sha256
from pathlib import Path
from types import ModuleType, SimpleNamespace
from unittest.mock import Mock

import pytest
from orchard_worker_mlx.backends import BackendError
from test_native_factory import assembly as assembly
from test_native_factory import bounds as bounds
from test_native_factory import fake_native as fake_native
from test_native_factory import profile as profile

from orchard_tensorfold_http import native_factory
from orchard_tensorfold_http.rendering import bind_chat_template

FIXTURES = Path(__file__).parent / "fixtures/tensorfold_0_6_6"
SOURCES = {
    "server.errors": "7e424274b47d3e4cea1880f8e080e86382d93c84a3823581d971d19f98301dc7",
    "server.messages": "5ec8a7fd07b046587114e69432343310edf3cf31d7b323dfd1827a5c0d704f6c",
    "server.text": "c07b60d17e966e5d568f87dcc7d85e532d553089a23e6580e5982cce8c4c58ad",
    "engine.prefill_plan": "28f917f14f9e33ffa4e88c4ec81267bde99cb1520633e9718f3a14d1d7625c1d",
}


@pytest.fixture
def pinned_prefill(monkeypatch):
    for name in ("tensorfold", "tensorfold.engine", "tensorfold.server"):
        package = ModuleType(name)
        package.__path__ = []
        monkeypatch.setitem(sys.modules, name, package)
    loaded = {}
    for suffix, digest in SOURCES.items():
        name = f"tensorfold.{suffix}"
        path = FIXTURES / f"{suffix.split('.')[-1]}.py.txt"
        assert sha256(path.read_bytes()).hexdigest() == digest
        loader = importlib.machinery.SourceFileLoader(name, str(path))
        spec = importlib.util.spec_from_loader(name, loader)
        module = importlib.util.module_from_spec(spec)
        monkeypatch.setitem(sys.modules, name, module)
        loader.exec_module(module)
        loaded[suffix] = module
    return SimpleNamespace(plan=loaded["engine.prefill_plan"], text=loaded["server.text"])


class TemplateTokenizer:
    """CPU fixture IDs over the exact Qwen template, not native BPE qualification."""

    tokens = {
        "<|im_start|>": 10,
        "assistant": 11,
        "user": 12,
        "system": 13,
        "<|im_end|>": 20,
        "<think>": 21,
        "</think>": 22,
    }
    all_special_ids = (10, 20, 21, 22)
    eos_token_ids = (20,)

    def __init__(self, render):
        self._chat_template = render
        self.calls = []

    def apply_chat_template(self, messages, *, tokenize=True, **options):
        self.calls.append((messages, {"tokenize": tokenize, **options}))
        text = self._chat_template(messages, **options)
        return self.encode(text) if tokenize else text

    def encode(self, text, **_options):
        parts = re.findall("|".join(map(re.escape, self.tokens)) + r"|[\s\S]", text)
        return [self.tokens[p] if p in self.tokens else 1000 + ord(p) for p in parts]

    def decode(self, ids):
        tokens = {value: text for text, value in self.tokens.items()}
        return "".join(tokens[t] if t in tokens else chr(t - 1000) for t in ids)


@pytest.fixture
def qwen_tokenizer(tmp_path):
    template = (
        Path(__file__).resolve().parents[3]
        / "apps/orchard_controller/test/fixtures/tokenizer/qwen3_8_effort/chat_template.jinja"
    )
    assert sha256(template.read_bytes()).hexdigest() == (
        "c3cf9e34abf4f9e36c2d72165aa9c132d3e2a725b6c2586aaa3a8af9d7a81041"
    )
    config = tmp_path / "tokenizer_config.json"
    config.write_text("{}")
    return TemplateTokenizer(
        bind_chat_template(
            template,
            config,
            template_digest=sha256(template.read_bytes()).hexdigest(),
            config_digest=sha256(config.read_bytes()).hexdigest(),
        )
    )


def multi_turn(tokenizer, *, last_user_tokens=1100):
    messages = [
        {"role": "system", "content": "rules " * 100},
        {"role": "user", "content": "x" * 1100},
        {"role": "assistant", "content": "a" * 700},
        {"role": "user", "content": "x" * 1150},
        {"role": "assistant", "content": "a" * 800},
        {"role": "user", "content": "x" * last_user_tokens},
    ]
    history = tokenizer.apply_chat_template(messages, add_generation_prompt=False)
    prompt = tokenizer.apply_chat_template(messages, add_generation_prompt=True)
    assert prompt[: len(history)] == history
    return prompt, len(history)


def test_exact_qwen_template_markers_and_late_system_probe(pinned_prefill, qwen_tokenizer):
    adapter = native_factory._ThinkingOnProbe(qwen_tokenizer)
    assert pinned_prefill.text.template_late_system(adapter) == "user"
    assert pinned_prefill.plan.message_markers(adapter) == ((10,), (10, 11))
    assert any(options["tokenize"] is False for _, options in qwen_tokenizer.calls)
    assert all(
        options["enable_thinking"] is True and options["thinking_mode"] == "thinking"
        for _, options in qwen_tokenizer.calls
    )
    assert adapter.all_special_ids is qwen_tokenizer.all_special_ids
    with pytest.raises(ValueError, match="thinking binding mismatch"):
        qwen_tokenizer.apply_chat_template([], enable_thinking=False)
    with pytest.raises(ValueError, match="thinking mode binding mismatch"):
        qwen_tokenizer.apply_chat_template([], thinking_mode="chat")


@pytest.mark.parametrize("step", [128, 256])
def test_clamped_plan_preserves_plain_grid(pinned_prefill, qwen_tokenizer, step):
    prompt, _history_len = multi_turn(qwen_tokenizer)
    plan = native_factory._prefill_plan(qwen_tokenizer, step)
    assert plan.openers == (10,) and plan.assistant == (10, 11)
    assert plan.min_chunk == step
    assert plan.chunks(prompt).starts == pinned_prefill.plan.PrefillPlan(step).chunks(prompt).starts
    assert plan.chunks(prompt).starts == list(range(0, len(prompt), step))
    assert plan.name == f"grid{step}+msg{step}:10:10.11"


def test_step_2048_cuts_at_replies_and_history_checkpoint(pinned_prefill, qwen_tokenizer):
    prompt, history_len = multi_turn(qwen_tokenizer)
    plan = native_factory._prefill_plan(qwen_tokenizer, 2048)
    chunks = plan.chunks(prompt)
    reply_starts = [i for i in range(len(prompt) - 1) if prompt[i : i + 2] == [10, 11]]
    assert len(reply_starts) == 3 and reply_starts[-1] == history_len
    assert plan.min_chunk == 256
    assert all(start in chunks.starts for start in reply_starts), (reply_starts, chunks.starts)
    assert any(start % 2048 != 0 for start in reply_starts)
    assert max(b - a for a, b in chunks.between(0, len(prompt))) <= 2048
    checkpoint_boundaries = (history_len,)
    assert tuple(chunks.floor(at) for at in checkpoint_boundaries) == checkpoint_boundaries
    assert history_len in chunks


def test_reply_cut_within_256_of_previous_start_is_merged(pinned_prefill, qwen_tokenizer):
    prompt, history_len = multi_turn(qwen_tokenizer, last_user_tokens=1250)
    chunks = native_factory._prefill_plan(qwen_tokenizer, 2048).chunks(prompt)
    assert history_len not in chunks.starts
    assert 0 < history_len - chunks.floor(history_len) < 256


@pytest.mark.parametrize("step", [128, 2048])
@pytest.mark.parametrize("markers", [((), (10, 11)), ((10,), ()), ((), ())])
def test_empty_markers_refuse_native_startup(assembly, fake_native, step, markers):
    assembly.factory.prefill_step = step
    fake_native.markers.return_value = markers
    with pytest.raises(BackendError, match="message markers are not admitted") as error:
        native_factory.NativeFactory._assemble(
            assembly.factory, assembly.path, assembly.profile, Mock(), Mock()
        )
    assert error.value.code == "unsupported_model_profile"
    fake_native.markers.assert_called_once()
    fake_native.plan.assert_not_called()
    fake_native.lane.assert_not_called()
    fake_native.constructor.assert_not_called()


@pytest.mark.parametrize("step", [128, 2048])
def test_real_probe_without_special_tokens_fails_closed(pinned_prefill, qwen_tokenizer, step):
    qwen_tokenizer.all_special_ids = ()
    with pytest.raises(BackendError, match="message markers are not admitted"):
        native_factory._prefill_plan(qwen_tokenizer, step)
    assert qwen_tokenizer.calls


def test_step_too_short_for_assistant_marker_refuses_startup(assembly, fake_native):
    assembly.factory.prefill_step = 1
    with pytest.raises(BackendError, match="prefill step cannot fit assistant marker") as error:
        native_factory.NativeFactory._assemble(
            assembly.factory, assembly.path, assembly.profile, Mock(), Mock()
        )
    assert error.value.code == "unsupported_model_profile"
    fake_native.plan.assert_not_called()
    fake_native.lane.assert_not_called()


def test_error_before_upstream_probe_try_is_profile_refusal(
    pinned_prefill, qwen_tokenizer, monkeypatch
):
    monkeypatch.setattr(
        pinned_prefill.text, "template_late_system", Mock(side_effect=ValueError("probe failure"))
    )
    with pytest.raises(BackendError, match="message marker probe failed") as error:
        native_factory._prefill_plan(qwen_tokenizer, 2048)
    assert error.value.code == "unsupported_model_profile"


@pytest.mark.parametrize("step", [128, 2048])
def test_native_assembly_uses_real_markers_after_binding(
    assembly, fake_native, pinned_prefill, qwen_tokenizer, monkeypatch, step
):
    monkeypatch.setattr(
        sys.modules["tensorfold.families.qwen3_5"],
        "load",
        Mock(return_value=(object(), qwen_tokenizer)),
    )
    render = qwen_tokenizer._chat_template
    qwen_tokenizer._chat_template = Mock(side_effect=AssertionError("not yet bound"))
    assembly.factory.prefill_step = step
    native_factory.NativeFactory._assemble(
        assembly.factory, assembly.path, assembly.profile, render, Mock()
    )
    plan = fake_native.lane.call_args.kwargs["prefill_plan"]
    assert (plan.step, plan.min_chunk, plan.openers, plan.assistant) == (
        step,
        min(256, step),
        (10,),
        (10, 11),
    )
    assert qwen_tokenizer.calls
    assert qwen_tokenizer._chat_template is render
