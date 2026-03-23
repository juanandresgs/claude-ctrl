#!/usr/bin/env python3
"""Bootstrap CLI surface for the successor runtime."""

from __future__ import annotations

import argparse
import json
from typing import Sequence


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="cc-policy")
    subparsers = parser.add_subparsers(dest="domain", required=True)

    subparsers.add_parser("init")

    proof = subparsers.add_parser("proof")
    proof_sub = proof.add_subparsers(dest="action", required=True)
    proof_get = proof_sub.add_parser("get")
    proof_get.add_argument("--workflow", required=True)
    proof_set = proof_sub.add_parser("set")
    proof_set.add_argument("--workflow", required=True)
    proof_set.add_argument("--state", required=True)
    proof_set.add_argument("--actor", required=True)
    proof_sub.add_parser("reset-stale")

    for domain, actions in {
        "dispatch": ["create-cycle", "advance", "enqueue", "claim", "ack"],
        "marker": ["create", "query", "clear-stale"],
        "worktree": ["register", "heartbeat", "list", "sweep"],
        "event": ["emit", "query"],
    }.items():
        domain_parser = subparsers.add_parser(domain)
        domain_sub = domain_parser.add_subparsers(dest="action", required=True)
        for action in actions:
            domain_sub.add_parser(action)

    return parser


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    if args.domain == "init":
        print(json.dumps({"status": "bootstrap", "message": "runtime CLI initialized"}))
        return 0

    if args.domain == "proof" and args.action == "get":
        print(json.dumps({"status": "bootstrap", "workflow": args.workflow, "state": "idle"}))
        return 0

    if args.domain == "proof" and args.action == "set":
        print(
            json.dumps(
                {
                    "status": "bootstrap",
                    "workflow": args.workflow,
                    "state": args.state,
                    "actor": args.actor,
                }
            )
        )
        return 0

    print(
        json.dumps(
            {
                "status": "not_implemented",
                "domain": args.domain,
                "action": getattr(args, "action", None),
            }
        )
    )
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
