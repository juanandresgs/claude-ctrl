#!/usr/bin/env python3
"""Bootstrap plan discipline helper."""

from __future__ import annotations

import argparse
from pathlib import Path
import re
import sys


REQUIRED_HEADERS = [
    "## Identity",
    "## Architecture",
    "## Original Intent",
    "## Principles",
    "## Decision Log",
    "## Active Initiatives",
    "## Completed Initiatives",
    "## Parked Issues",
]


def validate(path: Path) -> int:
    text = path.read_text()
    missing = [header for header in REQUIRED_HEADERS if header not in text]
    if missing:
        for header in missing:
            print(f"missing: {header}")
        return 1
    return 0


def stamp(path: Path) -> int:
    text = path.read_text()
    stamped = re.sub(
        r"^Last updated: .*$",
        f"Last updated: {Path(path).stat().st_mtime_ns}",
        text,
        flags=re.MULTILINE,
    )
    if stamped == text:
        stamped = f"Last updated: {Path(path).stat().st_mtime_ns}\n\n{text}"
    path.write_text(stamped)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(prog="planctl.py")
    sub = parser.add_subparsers(dest="command", required=True)

    validate_cmd = sub.add_parser("validate")
    validate_cmd.add_argument("path", type=Path)

    stamp_cmd = sub.add_parser("stamp")
    stamp_cmd.add_argument("path", type=Path)

    args = parser.parse_args()
    if args.command == "validate":
        return validate(args.path)
    if args.command == "stamp":
        return stamp(args.path)
    return 1


if __name__ == "__main__":
    sys.exit(main())
