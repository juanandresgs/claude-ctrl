#!/usr/bin/env python3
"""cc-policy — successor runtime CLI.

All subcommands output JSON to stdout. Errors go to stderr with exit code 1.
Success always exits 0 with {"status": "ok", ...} payload.

@decision DEC-RT-001
Title: Canonical SQLite schema for all shared workflow state
Status: accepted
Rationale: cli.py is the sole external entry point into the runtime. Every
  subcommand opens a connection via db.connect(), calls ensure_schema() so
  the DB is always in a known state, delegates to the relevant domain
  module, and returns JSON. No domain logic lives here — cli.py is purely
  argument parsing + JSON serialization + error handling. This keeps domain
  modules independently testable without subprocess overhead.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Sequence

# Allow running as `python3 runtime/cli.py` from the project root
_HERE = Path(__file__).resolve().parent
_PROJECT_ROOT = _HERE.parent
if str(_PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(_PROJECT_ROOT))

from runtime.core.config import default_db_path
from runtime.core.db import connect
from runtime.schemas import ensure_schema
import runtime.core.proof as proof_mod
import runtime.core.markers as markers_mod
import runtime.core.events as events_mod
import runtime.core.worktrees as worktrees_mod
import runtime.core.dispatch as dispatch_mod
import runtime.core.statusline as statusline_mod


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _ok(payload: dict) -> int:
    payload.setdefault("status", "ok")
    print(json.dumps(payload))
    return 0


def _err(message: str, code: int = 1) -> int:
    print(json.dumps({"status": "error", "message": message}), file=sys.stderr)
    return code


def _get_conn():
    db_path = default_db_path()
    conn = connect(db_path)
    ensure_schema(conn)
    return conn


# ---------------------------------------------------------------------------
# Domain handlers
# ---------------------------------------------------------------------------

def _handle_schema(args) -> int:
    conn = _get_conn()
    conn.close()
    return _ok({"message": "schema ensured"})


def _handle_proof(args) -> int:
    conn = _get_conn()
    try:
        if args.action == "get":
            result = proof_mod.get(conn, args.workflow_id)
            if result is None:
                return _ok({"workflow_id": args.workflow_id, "status": "idle", "found": False})
            result["found"] = True
            return _ok(result)

        elif args.action == "set":
            proof_mod.set_status(conn, args.workflow_id, args.status)
            return _ok({"workflow_id": args.workflow_id, "status": args.status})

        elif args.action == "list":
            rows = proof_mod.list_all(conn)
            return _ok({"items": rows, "count": len(rows)})

    except ValueError as e:
        return _err(str(e))
    finally:
        conn.close()
    return _err(f"unknown proof action: {args.action}")


def _handle_marker(args) -> int:
    conn = _get_conn()
    try:
        if args.action == "set":
            markers_mod.set_active(conn, args.agent_id, args.role)
            return _ok({"agent_id": args.agent_id, "role": args.role})

        elif args.action == "get-active":
            result = markers_mod.get_active(conn)
            if result is None:
                return _ok({"found": False, "active_agent": None})
            result["found"] = True
            return _ok(result)

        elif args.action == "deactivate":
            markers_mod.deactivate(conn, args.agent_id)
            return _ok({"agent_id": args.agent_id})

        elif args.action == "list":
            rows = markers_mod.list_all(conn)
            return _ok({"items": rows, "count": len(rows)})

    finally:
        conn.close()
    return _err(f"unknown marker action: {args.action}")


def _handle_event(args) -> int:
    conn = _get_conn()
    try:
        if args.action == "emit":
            event_id = events_mod.emit(
                conn,
                type=args.type,
                source=getattr(args, "source", None),
                detail=getattr(args, "detail", None),
            )
            return _ok({"id": event_id, "type": args.type})

        elif args.action == "query":
            rows = events_mod.query(
                conn,
                type=getattr(args, "type", None),
                since=getattr(args, "since", None),
                limit=getattr(args, "limit", 50),
            )
            return _ok({"items": rows, "count": len(rows)})

    finally:
        conn.close()
    return _err(f"unknown event action: {args.action}")


def _handle_worktree(args) -> int:
    conn = _get_conn()
    try:
        if args.action == "register":
            worktrees_mod.register(
                conn,
                path=args.path,
                branch=args.branch,
                ticket=getattr(args, "ticket", None),
            )
            return _ok({"path": args.path, "branch": args.branch})

        elif args.action == "remove":
            worktrees_mod.remove(conn, args.path)
            return _ok({"path": args.path})

        elif args.action == "list":
            rows = worktrees_mod.list_active(conn)
            return _ok({"items": rows, "count": len(rows)})

    finally:
        conn.close()
    return _err(f"unknown worktree action: {args.action}")


def _handle_dispatch(args) -> int:
    conn = _get_conn()
    try:
        if args.action == "enqueue":
            qid = dispatch_mod.enqueue(
                conn,
                role=args.role,
                ticket=getattr(args, "ticket", None),
            )
            return _ok({"id": qid, "role": args.role})

        elif args.action == "next":
            result = dispatch_mod.next_pending(conn)
            if result is None:
                return _ok({"found": False, "item": None})
            result["found"] = True
            return _ok(result)

        elif args.action == "start":
            dispatch_mod.start(conn, args.id)
            return _ok({"id": args.id})

        elif args.action == "complete":
            dispatch_mod.complete(conn, args.id)
            return _ok({"id": args.id})

        elif args.action == "cycle-start":
            cid = dispatch_mod.start_cycle(conn, args.initiative)
            return _ok({"id": cid, "initiative": args.initiative})

        elif args.action == "cycle-current":
            result = dispatch_mod.current_cycle(conn)
            if result is None:
                return _ok({"found": False, "cycle": None})
            result["found"] = True
            return _ok(result)

    finally:
        conn.close()
    return _err(f"unknown dispatch action: {args.action}")


def _handle_statusline(args) -> int:
    conn = _get_conn()
    try:
        snap = statusline_mod.snapshot(conn)
        return _ok(snap)
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# Parser
# ---------------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="cc-policy",
        description="Successor runtime CLI — all output is JSON.",
    )
    subparsers = parser.add_subparsers(dest="domain", required=True)

    # schema ensure
    schema_p = subparsers.add_parser("schema", help="Schema management")
    schema_sub = schema_p.add_subparsers(dest="action", required=True)
    schema_sub.add_parser("ensure", help="Create all tables idempotently")

    # init (backward compat with scaffold)
    subparsers.add_parser("init", help="Alias for schema ensure")

    # proof
    proof_p = subparsers.add_parser("proof", help="Proof-of-work lifecycle")
    proof_sub = proof_p.add_subparsers(dest="action", required=True)
    pg = proof_sub.add_parser("get")
    pg.add_argument("workflow_id")
    ps_p = proof_sub.add_parser("set")
    ps_p.add_argument("workflow_id")
    ps_p.add_argument("status", choices=["idle", "pending", "verified"])
    proof_sub.add_parser("list")

    # marker
    marker_p = subparsers.add_parser("marker", help="Agent role markers")
    marker_sub = marker_p.add_subparsers(dest="action", required=True)
    ms = marker_sub.add_parser("set")
    ms.add_argument("agent_id")
    ms.add_argument("role")
    marker_sub.add_parser("get-active")
    md = marker_sub.add_parser("deactivate")
    md.add_argument("agent_id")
    marker_sub.add_parser("list")

    # event
    event_p = subparsers.add_parser("event", help="Audit event store")
    event_sub = event_p.add_subparsers(dest="action", required=True)
    ee = event_sub.add_parser("emit")
    ee.add_argument("type")
    ee.add_argument("--source")
    ee.add_argument("--detail")
    eq = event_sub.add_parser("query")
    eq.add_argument("--type")
    eq.add_argument("--since", type=int)
    eq.add_argument("--limit", type=int, default=50)

    # worktree
    wt_p = subparsers.add_parser("worktree", help="Worktree registry")
    wt_sub = wt_p.add_subparsers(dest="action", required=True)
    wr = wt_sub.add_parser("register")
    wr.add_argument("path")
    wr.add_argument("branch")
    wr.add_argument("--ticket")
    wrm = wt_sub.add_parser("remove")
    wrm.add_argument("path")
    wt_sub.add_parser("list")

    # dispatch
    dp_p = subparsers.add_parser("dispatch", help="Dispatch queue and cycles")
    dp_sub = dp_p.add_subparsers(dest="action", required=True)
    deq = dp_sub.add_parser("enqueue")
    deq.add_argument("role")
    deq.add_argument("--ticket")
    dp_sub.add_parser("next")
    dst = dp_sub.add_parser("start")
    dst.add_argument("id", type=int)
    dco = dp_sub.add_parser("complete")
    dco.add_argument("id", type=int)
    dcs = dp_sub.add_parser("cycle-start")
    dcs.add_argument("initiative")
    dp_sub.add_parser("cycle-current")

    # statusline
    sl_p = subparsers.add_parser("statusline", help="Runtime-backed statusline snapshot")
    sl_sub = sl_p.add_subparsers(dest="action", required=True)
    sl_sub.add_parser("snapshot")

    return parser


# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

def main(argv: Sequence[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    # init is a backward-compat alias for schema ensure
    if args.domain == "init":
        conn = _get_conn()
        conn.close()
        return _ok({"message": "schema ensured"})

    if args.domain == "schema":
        return _handle_schema(args)
    if args.domain == "proof":
        return _handle_proof(args)
    if args.domain == "marker":
        return _handle_marker(args)
    if args.domain == "event":
        return _handle_event(args)
    if args.domain == "worktree":
        return _handle_worktree(args)
    if args.domain == "dispatch":
        return _handle_dispatch(args)
    if args.domain == "statusline":
        return _handle_statusline(args)

    return _err(f"unknown domain: {args.domain}")


if __name__ == "__main__":
    raise SystemExit(main())
