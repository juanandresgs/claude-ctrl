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
import runtime.core.traces as traces_mod
import runtime.core.tokens as tokens_mod
import runtime.core.todos as todos_mod
import runtime.core.workflows as workflows_mod
from sidecars.observatory.observe import Observatory
from sidecars.search.search import SearchIndex


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


def _handle_trace(args) -> int:
    conn = _get_conn()
    try:
        if args.action == "start":
            sid = traces_mod.start_trace(
                conn,
                session_id=args.session_id,
                agent_role=getattr(args, "role", None),
                ticket=getattr(args, "ticket", None),
            )
            return _ok({"session_id": sid})

        elif args.action == "end":
            traces_mod.end_trace(
                conn,
                session_id=args.session_id,
                summary=getattr(args, "summary", None),
            )
            return _ok({"session_id": args.session_id})

        elif args.action == "manifest":
            traces_mod.add_manifest_entry(
                conn,
                session_id=args.session_id,
                entry_type=args.entry_type,
                path=getattr(args, "path", None),
                detail=getattr(args, "detail", None),
            )
            return _ok({"session_id": args.session_id, "entry_type": args.entry_type})

        elif args.action == "get":
            result = traces_mod.get_trace(conn, args.session_id)
            if result is None:
                return _ok({"found": False, "session_id": args.session_id})
            result["found"] = True
            return _ok(result)

        elif args.action == "recent":
            limit = getattr(args, "limit", 10)
            rows = traces_mod.recent_traces(conn, limit=limit)
            return _ok({"items": rows, "count": len(rows)})

    finally:
        conn.close()
    return _err(f"unknown trace action: {args.action}")


def _handle_workflow(args) -> int:
    conn = _get_conn()
    try:
        if args.action == "bind":
            workflows_mod.bind_workflow(
                conn,
                workflow_id=args.workflow_id,
                worktree_path=args.worktree_path,
                branch=args.branch,
                base_branch=getattr(args, "base_branch", "main") or "main",
                ticket=getattr(args, "ticket", None),
                initiative=getattr(args, "initiative", None),
            )
            return _ok({
                "workflow_id": args.workflow_id,
                "worktree_path": args.worktree_path,
                "branch": args.branch,
            })

        elif args.action == "get":
            result = workflows_mod.get_binding(conn, args.workflow_id)
            if result is None:
                return _err(f"workflow_id '{args.workflow_id}' not found")
            result["found"] = True
            return _ok(result)

        elif args.action == "scope-set":
            import json as _json
            try:
                allowed = _json.loads(getattr(args, "allowed", "[]") or "[]")
                required = _json.loads(getattr(args, "required", "[]") or "[]")
                forbidden = _json.loads(getattr(args, "forbidden", "[]") or "[]")
                authorities = _json.loads(getattr(args, "authorities", "[]") or "[]")
            except _json.JSONDecodeError as e:
                return _err(f"invalid JSON in scope arguments: {e}")
            workflows_mod.set_scope(
                conn,
                workflow_id=args.workflow_id,
                allowed_paths=allowed,
                required_paths=required,
                forbidden_paths=forbidden,
                authority_domains=authorities,
            )
            return _ok({"workflow_id": args.workflow_id, "action": "scope-set"})

        elif args.action == "scope-get":
            result = workflows_mod.get_scope(conn, args.workflow_id)
            if result is None:
                return _err(f"no scope for workflow_id '{args.workflow_id}'")
            result["found"] = True
            return _ok(result)

        elif args.action == "scope-check":
            import json as _json
            try:
                changed = _json.loads(getattr(args, "changed", "[]") or "[]")
            except _json.JSONDecodeError as e:
                return _err(f"invalid JSON in --changed: {e}")
            result = workflows_mod.check_scope_compliance(conn, args.workflow_id, changed)
            return _ok(result)

        elif args.action == "list":
            rows = workflows_mod.list_bindings(conn)
            return _ok({"items": rows, "count": len(rows)})

    except ValueError as e:
        return _err(str(e))
    finally:
        conn.close()
    return _err(f"unknown workflow action: {args.action}")


# ---------------------------------------------------------------------------
# Sidecar handlers
# ---------------------------------------------------------------------------

# Registry of available sidecars by name, for `cc-policy sidecar list`
_SIDECAR_REGISTRY = {
    "observatory": "Read-only health observer over all runtime state domains",
    "search":      "Read-only text search over traces and manifest entries",
}


def _handle_tokens(args) -> int:
    conn = _get_conn()
    try:
        if args.action == "upsert":
            tokens_mod.upsert(
                conn,
                session_id=args.session_id,
                project_hash=args.project_hash,
                total_tokens=int(args.total_tokens),
            )
            return _ok({"session_id": args.session_id, "project_hash": args.project_hash})

        elif args.action == "lifetime":
            result = tokens_mod.lifetime(conn, args.project_hash)
            return _ok(result)

    finally:
        conn.close()
    return _err(f"unknown tokens action: {args.action}")


def _handle_todos(args) -> int:
    conn = _get_conn()
    try:
        if args.action == "set":
            todos_mod.set_counts(
                conn,
                project_hash=args.project_hash,
                project_count=int(args.project_count),
                global_count=int(args.global_count),
            )
            return _ok({"project_hash": args.project_hash})

        elif args.action == "get":
            result = todos_mod.get_counts(conn, args.project_hash)
            return _ok(result)

    finally:
        conn.close()
    return _err(f"unknown todos action: {args.action}")


def _handle_sidecar(args) -> int:
    """Dispatch to shadow-mode sidecar subcommands.

    Subcommands:
      observatory       Run the observatory and print a JSON health report.
      search <query>    Search traces and manifest entries for <query>.
      list              Print the registry of available sidecars as JSON.

    All sidecar subcommands are read-only: they open a db connection,
    call observe() on the relevant sidecar class, and print JSON to stdout.
    They never write to any canonical table.
    """
    conn = _get_conn()
    try:
        if args.action == "observatory":
            obs = Observatory("observatory", conn)
            obs.observe()
            return _ok(obs.report())

        elif args.action == "search":
            si = SearchIndex("search", conn)
            si.observe()
            results = si.search(args.query, limit=getattr(args, "limit", 10))
            return _ok({
                "query": args.query,
                "count": len(results),
                "results": results,
            })

        elif args.action == "list":
            return _ok({
                "sidecars": [
                    {"name": k, "description": v}
                    for k, v in _SIDECAR_REGISTRY.items()
                ],
                "count": len(_SIDECAR_REGISTRY),
            })

    finally:
        conn.close()
    return _err(f"unknown sidecar action: {args.action}")


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

    # trace
    tr_p = subparsers.add_parser("trace", help="Trace-lite session manifests and summaries")
    tr_sub = tr_p.add_subparsers(dest="action", required=True)

    tr_start = tr_sub.add_parser("start", help="Begin a new trace for a session")
    tr_start.add_argument("session_id")
    tr_start.add_argument("--role", dest="role", default=None,
                          help="Agent role (implementer, tester, planner, ...)")
    tr_start.add_argument("--ticket", default=None,
                          help="Ticket reference (e.g. TKT-013)")

    tr_end = tr_sub.add_parser("end", help="Close a trace with optional summary")
    tr_end.add_argument("session_id")
    tr_end.add_argument("--summary", default=None,
                        help="Human-readable summary of what the session accomplished")

    tr_manifest = tr_sub.add_parser("manifest",
                                    help="Add a manifest entry to a trace")
    tr_manifest.add_argument("session_id")
    tr_manifest.add_argument("entry_type",
                             help="Entry type: file_read, file_write, decision, command, event")
    tr_manifest.add_argument("--path", default=None, help="File path (for file_read/file_write)")
    tr_manifest.add_argument("--detail", default=None, help="Description of the entry")

    tr_get = tr_sub.add_parser("get", help="Get a trace with its manifest")
    tr_get.add_argument("session_id")

    tr_recent = tr_sub.add_parser("recent", help="List recent traces")
    tr_recent.add_argument("--limit", type=int, default=10,
                           help="Maximum number of traces to return (default 10)")

    # tokens
    tok_p = subparsers.add_parser("tokens", help="Session token accumulation")
    tok_sub = tok_p.add_subparsers(dest="action", required=True)

    tok_upsert = tok_sub.add_parser("upsert", help="Write session token total")
    tok_upsert.add_argument("session_id", help="Session identifier (e.g. pid:1234)")
    tok_upsert.add_argument("project_hash", help="8-char project hash")
    tok_upsert.add_argument("total_tokens", type=int, help="Running token total for this session")

    tok_lifetime = tok_sub.add_parser("lifetime", help="Sum tokens across all sessions for a project")
    tok_lifetime.add_argument("project_hash", help="8-char project hash")

    # todos
    td_p = subparsers.add_parser("todos", help="Project-scoped todo counts")
    td_sub = td_p.add_subparsers(dest="action", required=True)

    td_set = td_sub.add_parser("set", help="Write project and global todo counts")
    td_set.add_argument("project_hash", help="8-char project hash")
    td_set.add_argument("project_count", type=int, help="Project-scoped todo count")
    td_set.add_argument("global_count", type=int, help="Global todo count")

    td_get = td_sub.add_parser("get", help="Read todo counts for a project")
    td_get.add_argument("project_hash", help="8-char project hash")

    # workflow
    wf_p = subparsers.add_parser("workflow", help="Workflow binding and scope enforcement")
    wf_sub = wf_p.add_subparsers(dest="action", required=True)

    wf_bind = wf_sub.add_parser("bind", help="Bind workflow_id to worktree/branch")
    wf_bind.add_argument("workflow_id")
    wf_bind.add_argument("worktree_path")
    wf_bind.add_argument("branch")
    wf_bind.add_argument("--base-branch", default="main", dest="base_branch")
    wf_bind.add_argument("--ticket", default=None)
    wf_bind.add_argument("--initiative", default=None)

    wf_get = wf_sub.add_parser("get", help="Get binding for a workflow_id")
    wf_get.add_argument("workflow_id")

    wf_scope_set = wf_sub.add_parser("scope-set", help="Set scope manifest for a workflow")
    wf_scope_set.add_argument("workflow_id")
    wf_scope_set.add_argument("--allowed", default="[]",
                              help="JSON array of allowed path globs")
    wf_scope_set.add_argument("--required", default="[]",
                              help="JSON array of required path globs")
    wf_scope_set.add_argument("--forbidden", default="[]",
                              help="JSON array of forbidden path globs")
    wf_scope_set.add_argument("--authorities", default="[]",
                              help="JSON array of authority domain names")

    wf_scope_get = wf_sub.add_parser("scope-get", help="Get scope manifest for a workflow")
    wf_scope_get.add_argument("workflow_id")

    wf_scope_check = wf_sub.add_parser("scope-check",
                                       help="Check changed files against scope")
    wf_scope_check.add_argument("workflow_id")
    wf_scope_check.add_argument("--changed", default="[]",
                                help="JSON array of changed file paths")

    wf_sub.add_parser("list", help="List all workflow bindings")

    # sidecar
    sc_p = subparsers.add_parser("sidecar", help="Shadow-mode read-only sidecars")
    sc_sub = sc_p.add_subparsers(dest="action", required=True)

    sc_sub.add_parser("observatory", help="Run observatory health report")
    sc_sub.add_parser("list", help="List available sidecars")

    sc_search = sc_sub.add_parser("search", help="Search traces and manifest entries")
    sc_search.add_argument("query", help="Search term (case-insensitive substring)")
    sc_search.add_argument("--limit", type=int, default=10,
                           help="Maximum results to return (default 10)")

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
    if args.domain == "trace":
        return _handle_trace(args)
    if args.domain == "tokens":
        return _handle_tokens(args)
    if args.domain == "todos":
        return _handle_todos(args)
    if args.domain == "workflow":
        return _handle_workflow(args)
    if args.domain == "sidecar":
        return _handle_sidecar(args)

    return _err(f"unknown domain: {args.domain}")


if __name__ == "__main__":
    raise SystemExit(main())
