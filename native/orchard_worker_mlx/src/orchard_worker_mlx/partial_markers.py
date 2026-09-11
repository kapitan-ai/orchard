from __future__ import annotations


def split_partial_marker(text: str, marker: str) -> tuple[str, str]:
    if marker == "":
        return text, ""

    max_overlap = min(len(text), len(marker) - 1)
    for overlap in range(max_overlap, 0, -1):
        if text.endswith(marker[:overlap]):
            return text[:-overlap], text[-overlap:]
    return text, ""
