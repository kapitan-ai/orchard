from __future__ import annotations

import argparse
import json
from collections.abc import Sequence
from typing import Any

from orchard_tokenizer import __version__


def build_placeholder_response() -> dict[str, Any]:
    return {
        "component": "orchard_tokenizer",
        "status": "not_implemented",
        "message": "Tokenizer scaffold only; structured prompt rendering lands in R4.",
    }


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="orchard-tokenizer",
        description="Orchard tokenizer scaffold entrypoint.",
    )
    parser.add_argument("--version", action="store_true", help="print the package version and exit")
    args = parser.parse_args(argv)

    if args.version:
        print(__version__)
        return 0

    print(json.dumps(build_placeholder_response()))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
