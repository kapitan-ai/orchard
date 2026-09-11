"""Chunk-boundary marker splitting shared by this package's streaming consumers.

A framing marker can straddle two streamed chunks, so a trailing fragment that is
a proper prefix of the marker must never be published as visible output. Splitting
returns ``(publishable_text, retained_suffix)``; the caller carries the retained
suffix into the next chunk.
"""

from __future__ import annotations


def split_partial_marker(text: str, marker: str) -> tuple[str, str]:
    if marker == "":
        return text, ""

    max_overlap = min(len(text), len(marker) - 1)
    for overlap in range(max_overlap, 0, -1):
        if text.endswith(marker[:overlap]):
            return text[:-overlap], text[-overlap:]
    return text, ""
