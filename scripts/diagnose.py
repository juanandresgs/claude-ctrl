#!/usr/bin/env python3
"""Bootstrap diagnostics helper."""

from __future__ import annotations

import json
from pathlib import Path


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    payload = {
        "root": str(root),
        "has_settings": (root / "settings.json").exists(),
        "has_master_plan": (root / "MASTER_PLAN.md").exists(),
        "has_runtime_cli": (root / "runtime" / "cli.py").exists(),
        "has_hooks": (root / "hooks").exists(),
    }
    print(json.dumps(payload, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
