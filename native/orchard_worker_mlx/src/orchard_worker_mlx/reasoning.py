"""Stateful, content-discarding reasoning framing parser.

This module intentionally has no MLX or provider imports. It accepts decoded
``str`` chunks, emits only final-answer text, and never retains decoded
reasoning content. Retained state is parser bookkeeping, a bounded partial
marker suffix, and pre-open text that only a complete reasoning frame or the
terminal can classify. Final-answer text stays withheld while the negotiated
generation policy is still unsatisfied, so a generation-policy conformance
terminal releases no selected output. Production prompt-opened render mappings
are empty until a qualified render contract is admitted.
"""

from __future__ import annotations

from collections.abc import Iterable
from dataclasses import dataclass

from orchard_worker_mlx.partial_markers import split_partial_marker

TAGGED_PAIR_FAMILY = "tagged_pair"
PROMPT_OPENED_FAMILY = "prompt_opened"
PARSER_VERSION_V1 = "v1"

REASONING_PARSER_CONFORMANCE_FAILED = "reasoning_parser_conformance_failed"
REASONING_POLICY_CONFORMANCE_FAILED = "reasoning_policy_conformance_failed"

PARSER_INCOMPLETE_MARKER = "parser_incomplete_marker"
PARSER_LATE_OPEN_MARKER = "parser_late_open_marker"
PARSER_NESTED_OPEN_MARKER = "parser_nested_open_marker"
PARSER_STRAY_CLOSE_MARKER = "parser_stray_close_marker"
PARSER_UNCLOSED_MARKER = "parser_unclosed_marker"
POLICY_DISABLED_REASONING = "policy_disabled_reasoning"
POLICY_ENABLED_REASONING_MISSING = "policy_enabled_reasoning_missing"

_OPEN_MARKER = "<think>"
_CLOSE_MARKER = "</think>"

# This is deliberately dormant. Exact qualified render contracts can populate
# a future production table without adding a request or wire-level boolean.
_PRODUCTION_PROMPT_OPENED_RENDER_CONTRACTS: frozenset[tuple[str, str]] = frozenset()

_ALLOWED_POLICIES = frozenset({"model_default", "disabled", "enabled"})
_TRUNCATING_TERMINAL = "length"
_CONFORMING_TERMINALS = frozenset({"completed", "stop", _TRUNCATING_TERMINAL})
_PREEMPTING_TERMINALS = frozenset({"cancelled", "deadline", "timed_out"})


def prompt_opened_reasoning(
    render_contract: str,
    render_contract_version: str,
    *,
    synthetic_prompt_opened_render_contracts: Iterable[tuple[str, str]] = (),
) -> bool:
    """Derive prompt-opened framing from an exact closed render-contract table."""
    contracts = _PRODUCTION_PROMPT_OPENED_RENDER_CONTRACTS.union(
        frozenset(synthetic_prompt_opened_render_contracts)
    )
    return (render_contract, render_contract_version) in contracts


@dataclass(frozen=True, slots=True)
class ParserDelta:
    """A parser output delta containing only final-answer text."""

    final_text: str = ""


@dataclass(frozen=True, slots=True)
class ParserTerminal:
    """Terminal conformance result plus any final-answer text held back by framing.

    ``failure_code`` and ``failure_reason`` remain content-free. ``final_text``
    carries only text the terminal has just classified as final-answer output:
    pre-open text no reasoning frame ever claimed, and a retained partial marker
    that a non-truncating terminal proves was ordinary text. A conformance
    failure of either kind carries no text at all.
    """

    failure_code: str | None = None
    failure_reason: str | None = None
    final_text: str = ""

    @property
    def ok(self) -> bool:
        return self.failure_code is None


@dataclass(frozen=True, slots=True)
class ParserState:
    """Non-content snapshot suitable for conformance assertions."""

    phase: str
    saw_reasoning_frame: bool
    saw_reasoning_content: bool
    saw_final_text: bool
    pending_marker: str
    has_unclassified_text: bool
    violation_reason: str | None


class StatefulReasoningParser:
    """Parse one negotiated decoded stream without retaining reasoning text."""

    def __init__(
        self,
        *,
        parser_family: str,
        parser_version: str,
        generation_policy: str,
        render_contract: str,
        render_contract_version: str,
        synthetic_prompt_opened_render_contracts: Iterable[tuple[str, str]] = (),
    ) -> None:
        if generation_policy not in _ALLOWED_POLICIES:
            raise ValueError("unsupported_generation_policy")

        prompt_opened = prompt_opened_reasoning(
            render_contract,
            render_contract_version,
            synthetic_prompt_opened_render_contracts=synthetic_prompt_opened_render_contracts,
        )
        self._validate_contract(parser_family, parser_version, prompt_opened)

        self._generation_policy = generation_policy
        self._phase = "reasoning" if parser_family == PROMPT_OPENED_FAMILY else "initial"
        self._saw_reasoning_frame = parser_family == PROMPT_OPENED_FAMILY
        self._saw_reasoning_content = False
        self._saw_final_text = False
        self._pending_marker = ""
        self._unclassified_parts: list[str] = []
        self._unclassified_has_nonspace = False
        self._violation_reason: str | None = None
        self._finished = False

    @staticmethod
    def _validate_contract(
        parser_family: str,
        parser_version: str,
        prompt_opened: bool,
    ) -> None:
        if parser_version != PARSER_VERSION_V1:
            raise ValueError("unsupported_parser_version")
        if parser_family == TAGGED_PAIR_FAMILY:
            if prompt_opened:
                raise ValueError("parser_family_render_contract_mismatch")
            return
        if parser_family != PROMPT_OPENED_FAMILY:
            raise ValueError("unsupported_parser_family")
        if not prompt_opened:
            raise ValueError("unqualified_prompt_opened_render_contract")

    def push(self, chunk: str) -> ParserDelta:
        """Consume a decoded chunk and return only currently safe final text."""
        if self._finished:
            raise RuntimeError("parser_already_finished")
        if not isinstance(chunk, str):
            raise TypeError("decoded_chunk_must_be_str")
        if self._violation_reason is not None:
            return ParserDelta()

        text, self._pending_marker = self._split_partial_marker(self._pending_marker + chunk)
        emitted: list[str] = []
        cursor = 0

        while cursor < len(text):
            marker_index, marker = self._next_marker(text, cursor)
            if marker_index is None:
                self._consume_text(text[cursor:], emitted)
                break

            self._consume_text(text[cursor:marker_index], emitted)
            self._consume_marker(marker)
            if self._violation_reason is not None:
                self._discard_unclassified_text()
                self._pending_marker = ""
                break
            cursor = marker_index + len(marker)

        return ParserDelta("".join(emitted))

    def finish(self, terminal_kind: str) -> ParserTerminal:
        """Apply terminal conformance after the provider supplies its terminal."""
        if self._finished:
            raise RuntimeError("parser_already_finished")
        if terminal_kind not in _CONFORMING_TERMINALS | _PREEMPTING_TERMINALS:
            raise ValueError("unsupported_parser_terminal")
        self._finished = True

        terminal = self._terminal_result(terminal_kind)
        self._pending_marker = ""
        self._discard_unclassified_text()
        return terminal

    def _terminal_result(self, terminal_kind: str) -> ParserTerminal:
        if terminal_kind in _PREEMPTING_TERMINALS:
            return ParserTerminal()

        if self._violation_reason is not None:
            return self._parser_failure(self._violation_reason)
        if self._pending_marker:
            if terminal_kind == _TRUNCATING_TERMINAL:
                return self._parser_failure(PARSER_INCOMPLETE_MARKER)
            self._absorb_pending_marker()
        if self._phase == "reasoning":
            return self._parser_failure(PARSER_UNCLOSED_MARKER)
        unsatisfied_policy = self._unsatisfied_policy_reason()
        if unsatisfied_policy is not None:
            return self._policy_failure(unsatisfied_policy)
        return ParserTerminal(final_text=self._release_unclassified_text())

    def snapshot(self) -> ParserState:
        """Return bounded parser state without decoded reasoning content."""
        return ParserState(
            phase=self._phase,
            saw_reasoning_frame=self._saw_reasoning_frame,
            saw_reasoning_content=self._saw_reasoning_content,
            saw_final_text=self._saw_final_text,
            pending_marker=self._pending_marker,
            has_unclassified_text=bool(self._unclassified_parts),
            violation_reason=self._violation_reason,
        )

    def _unsatisfied_policy_reason(self) -> str | None:
        """Name the negotiated generation-policy obligation the stream has not met."""
        if self._generation_policy == "disabled" and self._saw_reasoning_frame:
            return POLICY_DISABLED_REASONING
        if self._generation_policy == "enabled" and not self._saw_reasoning_content:
            return POLICY_ENABLED_REASONING_MISSING
        return None

    @staticmethod
    def _split_partial_marker(text: str) -> tuple[str, str]:
        """Retain the longest suffix that can complete either framing marker."""
        best_text = text
        best_suffix = ""
        for marker in (_OPEN_MARKER, _CLOSE_MARKER):
            candidate_text, candidate_suffix = split_partial_marker(text, marker)
            if len(candidate_suffix) > len(best_suffix):
                best_text = candidate_text
                best_suffix = candidate_suffix
        return best_text, best_suffix

    @staticmethod
    def _next_marker(text: str, cursor: int) -> tuple[int | None, str]:
        open_index = text.find(_OPEN_MARKER, cursor)
        close_index = text.find(_CLOSE_MARKER, cursor)
        if open_index == -1 and close_index == -1:
            return None, ""
        if close_index == -1 or (open_index != -1 and open_index < close_index):
            return open_index, _OPEN_MARKER
        return close_index, _CLOSE_MARKER

    def _consume_text(self, text: str, emitted: list[str]) -> None:
        if not text:
            return
        if self._phase == "reasoning":
            self._observe_reasoning_text(text)
            return
        if self._phase == "initial":
            self._append_unclassified(text)
            return
        self._saw_final_text = True
        if self._unsatisfied_policy_reason() is None:
            emitted.append(text)

    def _consume_marker(self, marker: str) -> None:
        if marker == _OPEN_MARKER:
            if self._phase == "reasoning":
                self._violation_reason = PARSER_NESTED_OPEN_MARKER
            elif self._phase == "initial" and not self._unclassified_has_nonspace:
                self._discard_unclassified_text()
                self._phase = "reasoning"
                self._saw_reasoning_frame = True
            else:
                self._violation_reason = PARSER_LATE_OPEN_MARKER
            return

        if self._phase != "reasoning":
            self._violation_reason = PARSER_STRAY_CLOSE_MARKER
            return
        self._phase = "final"

    def _absorb_pending_marker(self) -> None:
        """Reclassify a retained partial marker a non-truncating terminal ended."""
        residual, self._pending_marker = self._pending_marker, ""
        if self._phase == "reasoning":
            self._observe_reasoning_text(residual)
            return
        self._append_unclassified(residual)

    def _observe_reasoning_text(self, text: str) -> None:
        """Count only non-whitespace decoded reasoning text as valid content."""
        if text.strip():
            self._saw_reasoning_content = True

    def _append_unclassified(self, text: str) -> None:
        self._unclassified_parts.append(text)
        if not self._unclassified_has_nonspace and text.strip():
            self._unclassified_has_nonspace = True

    def _discard_unclassified_text(self) -> None:
        self._unclassified_parts.clear()
        self._unclassified_has_nonspace = False

    def _release_unclassified_text(self) -> str:
        released = "".join(self._unclassified_parts)
        self._discard_unclassified_text()
        if released:
            self._saw_final_text = True
        return released

    @staticmethod
    def _parser_failure(reason: str) -> ParserTerminal:
        return ParserTerminal(
            failure_code=REASONING_PARSER_CONFORMANCE_FAILED,
            failure_reason=reason,
        )

    @staticmethod
    def _policy_failure(reason: str) -> ParserTerminal:
        return ParserTerminal(
            failure_code=REASONING_POLICY_CONFORMANCE_FAILED,
            failure_reason=reason,
        )
