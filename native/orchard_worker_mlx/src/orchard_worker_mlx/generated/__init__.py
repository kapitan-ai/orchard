from __future__ import annotations

import sys
from pathlib import Path

GENERATED_ROOT = Path(__file__).resolve().parent
if str(GENERATED_ROOT) not in sys.path:
    sys.path.insert(0, str(GENERATED_ROOT))