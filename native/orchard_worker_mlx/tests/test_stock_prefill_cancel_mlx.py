"""Stream-mode prefill cancellation through the pinned mlx-lm ``stream_generate``.

A tiny random Llama runs the real prefill loop, so these tests check that the
cancel exception leaves mlx-lm cleanly and that the model still generates
afterwards.  No model weights are downloaded.  They need the optional ``mlx``
extra::

    mise exec -- uv run --locked --directory native/orchard_worker_mlx --extra mlx \\
        pytest tests/test_stock_prefill_cancel_mlx.py
"""

from __future__ import annotations

import dataclasses
import importlib.util
import threading
from collections.abc import Iterator
from types import SimpleNamespace
from typing import Any

import pytest

from orchard_worker_mlx.generation import _default_generation_deps, generate_events

_missing = [
    name
    for name in ("mlx", "mlx_lm", "transformers", "tokenizers")
    if importlib.util.find_spec(name) is None
]

pytestmark = pytest.mark.skipif(
    bool(_missing),
    reason=f"MLX optional extra is not installed (missing: {', '.join(_missing)})",
)

STEP = 8
PROMPT = list(range(3, 3 + 41))


def _tiny_session() -> Any:
    import mlx.core as mx
    import tokenizers
    from mlx_lm.models import llama
    from mlx_lm.tokenizer_utils import TokenizerWrapper
    from transformers import PreTrainedTokenizerFast

    mx.random.seed(0)
    model = llama.Model(
        llama.ModelArgs(
            model_type="llama",
            hidden_size=32,
            num_hidden_layers=2,
            intermediate_size=64,
            num_attention_heads=4,
            num_key_value_heads=4,
            rms_norm_eps=1e-5,
            vocab_size=64,
        )
    )
    mx.eval(model.parameters())
    # Every token needs its own id. When "[UNK]" shared id 0 with "t0", the
    # tokenizer kept one of the two at random per process, and mlx-lm's
    # detokenizer probe failed whenever "[UNK]" was the one dropped.
    vocab = {"[UNK]": 0, **{f"t{i}": i for i in range(1, 64)}}
    # Check before serialization can hide a duplicate by dropping either token.
    assert len(vocab) == len(set(vocab.values())) == 64
    backend = tokenizers.Tokenizer(tokenizers.models.WordLevel(vocab, unk_token="[UNK]"))
    tokenizer = TokenizerWrapper(PreTrainedTokenizerFast(tokenizer_object=backend))
    return SimpleNamespace(
        model=model,
        tokenizer=tokenizer,
        eos_token_ids=(),
        decode_cancel_stride=1,
        prefill_step_size=STEP,
        prefix_cache=None,
        strict_prefix_checkpoints=None,
        clear_cache=mx.clear_cache,
        memory_budget_status=SimpleNamespace(budget_available=False, target_working_set_bytes=0),
        tool_calling={"supported": False, "parser_type": None},
    )


def _request(max_output_tokens: int = 4) -> Any:
    params = SimpleNamespace(
        max_output_tokens=max_output_tokens,
        temperature=0.0,
        top_p=0.0,
        stop_sequences=[],
        tools_json=b"",
        tool_choice_json=b"",
    )
    return SimpleNamespace(
        rendered_prompt_utf8=b"",
        input_tokens=len(PROMPT),
        prompt_token_ids=list(PROMPT),
        return_token_ids=True,
        return_logprobs=False,
        cache_affinity_fingerprint="",
        params=params,
    )


def _deps_cancelling_at(cancel: threading.Event, processed_at: int, seen: list[int]) -> Any:
    deps = _default_generation_deps()
    real_stream = deps.stream_generate

    def stream(model: Any, tokenizer: Any, prompt_ids: list[int], **kwargs: Any) -> Iterator[Any]:
        callback = kwargs["prompt_progress_callback"]

        def observe(processed: int, total: int) -> None:
            seen.append(processed)
            if processed == processed_at:
                cancel.set()
            callback(processed, total)

        kwargs["prompt_progress_callback"] = observe
        yield from real_stream(model, tokenizer, prompt_ids, **kwargs)

    return dataclasses.replace(deps, stream_generate=stream)


def test_duplicate_token_ids_do_not_drop_unk_during_tokenizer_round_trip() -> None:
    tokenizer = _tiny_session().tokenizer
    vocab = tokenizer.get_vocab()

    assert set(vocab) == {"[UNK]", *(f"t{i}" for i in range(1, 64))}
    assert vocab["[UNK]"] == 0
    assert len(set(vocab.values())) == 64
    assert tokenizer.encode("a ,b", add_special_tokens=False) == [0]
    assert tokenizer.decode([0]) == "[UNK]"


def test_real_prefill_stops_at_the_next_chunk_boundary_and_the_model_still_generates() -> None:
    session = _tiny_session()
    cancel = threading.Event()
    seen: list[int] = []

    events = list(
        generate_events(
            session, _request(), cancel, deps=_deps_cancelling_at(cancel, 2 * STEP, seen)
        )
    )

    assert seen == [0, STEP, 2 * STEP]
    assert not [e for e in events if e["kind"] in ("token_delta", "output_text_delta")]
    assert events[-1]["kind"] == "failed"
    assert events[-1]["code"] == "cancelled"

    after = list(generate_events(session, _request(), threading.Event()))
    token_ids = [t for e in after if e["kind"] == "token_delta" for t in e["token_ids"]]
    assert after[-1]["kind"] == "completed"
    assert len(token_ids) == 4
