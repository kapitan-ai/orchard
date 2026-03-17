from __future__ import annotations

import argparse
import json
import sys
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Final

import sentencepiece as sentencepiece
from jinja2 import Environment, TemplateError, Undefined, meta as jinja_meta
from tokenizers import Tokenizer

from orchard_tokenizer import __version__

# Prompt-shaping tokens that must be resolved when referenced by a template.
# If a template uses {{ bos_token }} or {{ eos_token }}, the value MUST come
# from tokenizer_config.json; silent empty-string fallback corrupts the prompt.
_REQUIRED_SPECIAL_TOKENS: Final[frozenset[str]] = frozenset({"bos_token", "eos_token"})

# All special-token keys we attempt to extract from tokenizer_config.json.
_EXTRACTABLE_SPECIAL_TOKENS: Final[frozenset[str]] = frozenset({
    "bos_token", "eos_token", "pad_token", "unk_token",
})

CONTRACT_VERSION: Final[int] = 1
HF_TOKENIZER_KINDS: Final[set[str]] = {"huggingface_tokenizer_json", "tokenizer_json"}
SENTENCEPIECE_KINDS: Final[set[str]] = {
    "sentencepiece_model",
    "sentencepiece_tokenizer_model",
}


@dataclass(slots=True)
class TokenizerCliError(Exception):
    category: str
    message: str
    exit_code: int

    def __str__(self) -> str:
        return self.message


def build_success_response(rendered_prompt: str, input_token_count: int) -> dict[str, Any]:
    return {
        "contract_version": CONTRACT_VERSION,
        "ok": True,
        "result": {
            "rendered_prompt": rendered_prompt,
            "input_token_count": input_token_count,
        },
    }


def build_error_response(category: str, message: str) -> dict[str, Any]:
    return {
        "contract_version": CONTRACT_VERSION,
        "ok": False,
        "error": {
            "category": category,
            "message": message,
        },
    }


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="orchard-tokenizer",
        description="Orchard exact prompt rendering and token counting helper.",
    )
    parser.add_argument("--request-json", help="structured tokenization request payload")
    parser.add_argument("--version", action="store_true", help="print the package version and exit")
    args = parser.parse_args(argv)

    if args.version:
        print(__version__)
        return 0

    try:
        payload = load_payload(args.request_json)
        result = execute_contract(payload)
        print(json.dumps(build_success_response(**result), ensure_ascii=False))
        return 0
    except TokenizerCliError as exc:
        print(json.dumps(build_error_response(exc.category, exc.message), ensure_ascii=False))
        return exc.exit_code
    except Exception:
        print(
            json.dumps(
                build_error_response("internal_error", "unexpected tokenizer failure"),
                ensure_ascii=False,
            )
        )
        return 1


def load_payload(request_json: str | None) -> dict[str, Any]:
    payload_text = request_json if request_json is not None else sys.stdin.read()

    if payload_text.strip() == "":
        raise TokenizerCliError("invalid_input", "request JSON is required", 2)

    try:
        payload = json.loads(payload_text)
    except json.JSONDecodeError as exc:
        raise TokenizerCliError("invalid_input", f"request JSON is invalid: {exc.msg}", 2) from exc

    if not isinstance(payload, dict):
        raise TokenizerCliError("invalid_input", "request JSON must decode to an object", 2)

    return payload


def execute_contract(payload: dict[str, Any]) -> dict[str, Any]:
    contract_version = payload.get("contract_version")
    command = payload.get("command")

    if contract_version != CONTRACT_VERSION:
        raise TokenizerCliError(
            "invalid_input",
            f"unsupported contract_version: {contract_version!r}",
            2,
        )

    if command != "render_and_count":
        raise TokenizerCliError("invalid_input", f"unsupported command: {command!r}", 2)

    assets = require_mapping(payload, "assets")
    request = require_mapping(payload, "request")

    tokenizer_kind = require_non_empty_string(assets, "tokenizer_kind", category="invalid_input")
    tokenizer_path = Path(
        require_non_empty_string(assets, "tokenizer_path", category="missing_assets")
    )
    chat_template_path = Path(
        require_non_empty_string(assets, "chat_template_path", category="missing_assets")
    )

    messages = normalize_messages(request)
    prompt_lines = [f"{message['role']} {message['content']}" for message in messages]
    # Derive tokenizer_config.json path from the tokenizer directory
    tokenizer_config_path = tokenizer_path.parent / "tokenizer_config.json"
    rendered_prompt = render_prompt(
        messages, prompt_lines, chat_template_path, tokenizer_config_path
    )
    input_token_count = count_tokens(rendered_prompt, tokenizer_kind, tokenizer_path)

    return {
        "rendered_prompt": rendered_prompt,
        "input_token_count": input_token_count,
    }


def require_mapping(payload: dict[str, Any], field_name: str) -> dict[str, Any]:
    value = payload.get(field_name)

    if isinstance(value, dict):
        return value

    raise TokenizerCliError(
        "invalid_input",
        f"{field_name} must be an object, got: {value!r}",
        2,
    )


def require_non_empty_string(payload: dict[str, Any], field_name: str, *, category: str) -> str:
    value = payload.get(field_name)

    if isinstance(value, str) and value != "":
        return value

    raise TokenizerCliError(
        category,
        f"{field_name} must be a non-empty string",
        3 if category == "missing_assets" else 2,
    )


def normalize_messages(request: dict[str, Any]) -> list[dict[str, str]]:
    input_items = request.get("input_items")

    if not isinstance(input_items, list):
        raise TokenizerCliError(
            "invalid_input",
            f"request.input_items must be a list, got: {input_items!r}",
            2,
        )

    messages: list[dict[str, str]] = []

    for index, item in enumerate(input_items):
        if not isinstance(item, dict):
            raise TokenizerCliError(
                "invalid_input",
                f"request.input_items[{index}] must be an object, got: {item!r}",
                2,
            )

        role = item.get("role")
        if not isinstance(role, str) or role == "":
            raise TokenizerCliError(
                "invalid_input",
                f"request.input_items[{index}].role must be a non-empty string",
                2,
            )

        messages.append({"role": role, "content": normalize_content(item.get("content"), index)})

    return messages


def normalize_content(content: Any, item_index: int) -> str:
    if isinstance(content, str):
        return content

    if isinstance(content, list):
        parts: list[str] = []

        for part_index, part in enumerate(content):
            if not isinstance(part, dict):
                raise TokenizerCliError(
                    "invalid_input",
                    f"request.input_items[{item_index}].content[{part_index}] must be an object",
                    2,
                )

            part_type = part.get("type")
            text = part.get("text")

            if part_type != "text" or not isinstance(text, str):
                raise TokenizerCliError(
                    "invalid_input",
                    f"request.input_items[{item_index}].content[{part_index}] must be a text part",
                    2,
                )

            parts.append(text)

        return "".join(parts)

    raise TokenizerCliError(
        "invalid_input",
        f"request.input_items[{item_index}].content must be a string or text-part list",
        2,
    )


def render_prompt(
    messages: list[dict[str, str]],
    prompt_lines: list[str],
    chat_template_path: Path,
    tokenizer_config_path: Path | None = None,
) -> str:
    if not chat_template_path.is_file():
        raise TokenizerCliError(
            "missing_assets",
            f"chat template asset is missing: {chat_template_path}",
            3,
        )

    try:
        template_text = chat_template_path.read_text(encoding="utf-8")
    except OSError as exc:
        raise TokenizerCliError(
            "missing_assets",
            f"failed to read chat template asset: {chat_template_path}",
            3,
        ) from exc

    environment = Environment(
        autoescape=False, lstrip_blocks=True, trim_blocks=True, undefined=Undefined
    )

    # Discover which variables the template references via AST introspection.
    referenced_vars = _discover_template_variables(template_text, environment)

    # Determine which prompt-shaping tokens this template requires.
    required_tokens = referenced_vars & _REQUIRED_SPECIAL_TOKENS

    # Load special tokens — strict when required tokens are referenced,
    # best-effort otherwise.
    special_tokens = _load_special_tokens(tokenizer_config_path, required=required_tokens)

    # Fail deterministically if any required prompt-shaping token is unresolved.
    _ensure_required_tokens(required_tokens, special_tokens)

    try:
        template = environment.from_string(template_text)
        return template.render(
            messages=messages,
            prompt_lines=prompt_lines,
            add_generation_prompt=True,
            **special_tokens,
        )
    except TemplateError as exc:
        raise TokenizerCliError(
            "missing_assets",
            f"chat template asset is invalid: {exc}",
            3,
        ) from exc


def _discover_template_variables(template_text: str, environment: Environment) -> set[str]:
    """Return undeclared variable names referenced by a Jinja template."""
    try:
        ast = environment.parse(template_text)
        return jinja_meta.find_undeclared_variables(ast)
    except TemplateError:
        # Let the main render call produce the user-facing error.
        return set()


def _load_special_tokens(
    tokenizer_config_path: Path | None,
    *,
    required: frozenset[str],
) -> dict[str, str]:
    """Extract special-token values from tokenizer_config.json.

    When *required* is non-empty AND the config file is missing/unreadable,
    raises a deterministic ``TokenizerCliError``.  When *required* is empty,
    failures are silently tolerated (best-effort extraction).
    """
    if tokenizer_config_path is None or not tokenizer_config_path.is_file():
        if required:
            raise TokenizerCliError(
                "missing_assets",
                f"chat template requires special tokens {sorted(required)} "
                f"but tokenizer_config.json is missing at {tokenizer_config_path}",
                3,
            )
        return {}

    try:
        tc = json.loads(tokenizer_config_path.read_text(encoding="utf-8"))
    except Exception as exc:
        if required:
            raise TokenizerCliError(
                "missing_assets",
                f"chat template requires special tokens {sorted(required)} "
                f"but tokenizer_config.json could not be read: {exc}",
                3,
            ) from exc
        return {}

    tokens: dict[str, str] = {}
    for key in _EXTRACTABLE_SPECIAL_TOKENS:
        val = tc.get(key)
        if isinstance(val, str) and val:
            tokens[key] = val
        elif isinstance(val, dict):
            content = val.get("content", "")
            if isinstance(content, str) and content:
                tokens[key] = content
    return tokens


def _ensure_required_tokens(
    required: frozenset[str],
    resolved: dict[str, str],
) -> None:
    """Raise if any required prompt-shaping token is unresolved."""
    missing = sorted(required - resolved.keys())
    if missing:
        raise TokenizerCliError(
            "missing_assets",
            f"chat template requires unresolved special tokens: {', '.join(missing)}",
            3,
        )


def count_tokens(rendered_prompt: str, tokenizer_kind: str, tokenizer_path: Path) -> int:
    if not tokenizer_path.is_file():
        raise TokenizerCliError(
            "missing_assets",
            f"tokenizer asset is missing: {tokenizer_path}",
            3,
        )

    if tokenizer_kind in HF_TOKENIZER_KINDS:
        return count_huggingface_tokens(rendered_prompt, tokenizer_path)

    if tokenizer_kind in SENTENCEPIECE_KINDS:
        return count_sentencepiece_tokens(rendered_prompt, tokenizer_path)

    raise TokenizerCliError(
        "unsupported_tokenizer",
        f"unsupported tokenizer_kind: {tokenizer_kind}",
        4,
    )


def count_huggingface_tokens(rendered_prompt: str, tokenizer_path: Path) -> int:
    try:
        tokenizer = Tokenizer.from_file(str(tokenizer_path))
        return len(tokenizer.encode(rendered_prompt).ids)
    except Exception as exc:
        raise TokenizerCliError(
            "missing_assets",
            f"tokenizer asset is invalid: {tokenizer_path}",
            3,
        ) from exc


def count_sentencepiece_tokens(rendered_prompt: str, tokenizer_path: Path) -> int:
    try:
        processor = sentencepiece.SentencePieceProcessor()
        processor.Load(str(tokenizer_path))
        return len(processor.EncodeAsIds(rendered_prompt))
    except Exception as exc:
        raise TokenizerCliError(
            "missing_assets",
            f"tokenizer asset is invalid: {tokenizer_path}",
            3,
        ) from exc


if __name__ == "__main__":
    raise SystemExit(main())
