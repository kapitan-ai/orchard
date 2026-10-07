"""Identity-bound Orchard rendering for the provider's tokenizer callable seam."""

import json
from collections.abc import Callable
from hashlib import sha256
from pathlib import Path
from typing import Any

from orchard_tokenizer.cli import (
    _chat_template_environment,
    _discover_template_variables,
    _ensure_required_tokens,
)


def bind_chat_template(
    template_path: Path,
    config_path: Path,
    *,
    template_digest: str,
    config_digest: str,
) -> Callable[..., str]:
    """Snapshot verified assets and retain Orchard's serializer for both history suffixes.

    This first feasibility slice admits only the assessed thinking/medium profile.
    Installation on a live child remains gated on containment and lifecycle work.
    """
    template_bytes = template_path.read_bytes()
    config_bytes = config_path.read_bytes()
    if sha256(template_bytes).hexdigest() != template_digest:
        raise ValueError("template identity mismatch")
    if sha256(config_bytes).hexdigest() != config_digest:
        raise ValueError("tokenizer configuration identity mismatch")
    template_text = template_bytes.decode("utf-8")
    environment = _chat_template_environment()
    variables = _discover_template_variables(template_text, environment)
    required = frozenset(variables & {"bos_token", "eos_token"})
    # Decode the already verified bytes rather than reopening a mutable asset.
    config = json.loads(config_bytes)
    special_tokens = {
        key: value["content"] if isinstance(value, dict) else value
        for key in ("bos_token", "eos_token", "pad_token", "unk_token")
        if (value := config.get(key)) is not None
    }
    _ensure_required_tokens(required, special_tokens)

    def render(messages: list[dict[str, Any]], **options: Any) -> str:
        if any({"reasoning_content", "reasoning", "thinking"}.intersection(m) for m in messages):
            raise ValueError("structured prior reasoning is unsupported")
        unknown = set(options) - {
            "tools",
            "add_generation_prompt",
            "enable_thinking",
            "reasoning_effort",
            "thinking_mode",
        }
        if unknown:
            raise ValueError("unsupported template controls")
        if options.get("enable_thinking", True) is not True:
            raise ValueError("thinking binding mismatch")
        if options.get("reasoning_effort", "medium") != "medium":
            raise ValueError("effort binding mismatch")
        if options.get("thinking_mode", "thinking") != "thinking":
            raise ValueError("thinking mode binding mismatch")
        generation = options.get("add_generation_prompt", True)
        if type(generation) is not bool:
            raise ValueError("generation suffix must be boolean")
        return environment.from_string(template_text).render(
            messages=messages,
            prompt_lines=[],
            add_generation_prompt=generation,
            tools=options.get("tools"),
            tool_choice=None,
            enable_thinking=True,
            reasoning_effort="medium",
            **special_tokens,
        )

    return render
