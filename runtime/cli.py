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

import runtime.core.approvals as approvals_mod
import runtime.core.bugs as bugs_mod
import runtime.core.completions as completions_mod
import runtime.core.dispatch as dispatch_mod
import runtime.core.evaluation as evaluation_mod
import runtime.core.events as events_mod
import runtime.core.leases as leases_mod
import runtime.core.markers as markers_mod
import runtime.core.policy_engine as policy_engine_mod
import runtime.core.proof as proof_mod
import runtime.core.statusline as statusline_mod
import runtime.core.todos as todos_mod
import runtime.core.tokens as tokens_mod
import runtime.core.traces as traces_mod
import runtime.core.workflows as workflows_mod
import runtime.core.worktrees as worktrees_mod
from runtime.core.config import default_db_path
from runtime.core.db import connect
from runtime.schemas import ensure_schema
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


def _handle_evaluation(args) -> int:
    conn = _get_conn()
    try:
        if args.action == "get":
            result = evaluation_mod.get(conn, args.workflow_id)
            if result is None:
                return _ok(
                    {
                        "workflow_id": args.workflow_id,
                        "status": "idle",
                        "head_sha": None,
                        "blockers": 0,
                        "major": 0,
                        "minor": 0,
                        "found": False,
                    }
                )
            result["found"] = True
            return _ok(result)

        elif args.action == "set":
            evaluation_mod.set_status(
                conn,
                args.workflow_id,
                args.status,
                head_sha=getattr(args, "head_sha", None) or None,
                blockers=int(getattr(args, "blockers", 0) or 0),
                major=int(getattr(args, "major", 0) or 0),
                minor=int(getattr(args, "minor", 0) or 0),
            )
            return _ok({"workflow_id": args.workflow_id, "status": args.status})

        elif args.action == "list":
            rows = evaluation_mod.list_all(conn)
            return _ok({"items": rows, "count": len(rows)})

        elif args.action == "invalidate":
            invalidated = evaluation_mod.invalidate_if_ready(conn, args.workflow_id)
            return _ok({"workflow_id": args.workflow_id, "invalidated": invalidated})

    except ValueError as e:
        return _err(str(e))
    finally:
        conn.close()
    return _err(f"unknown evaluation action: {args.action}")


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

        elif args.action == "expire-stale":
            count = markers_mod.expire_stale(conn)
            return _ok({"expired_count": count})

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
            return _ok(
                {
                    "workflow_id": args.workflow_id,
                    "worktree_path": args.worktree_path,
                    "branch": args.branch,
                }
            )

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


def _handle_approval(args) -> int:
    conn = _get_conn()
    try:
        if args.action == "grant":
            row_id = approvals_mod.grant(
                conn,
                args.workflow_id,
                args.op_type,
                granted_by=getattr(args, "granted_by", "user") or "user",
            )
            return _ok({"id": row_id, "workflow_id": args.workflow_id, "op_type": args.op_type})
        elif args.action == "check":
            consumed = approvals_mod.check_and_consume(conn, args.workflow_id, args.op_type)
            return _ok(
                {"workflow_id": args.workflow_id, "op_type": args.op_type, "approved": consumed}
            )
        elif args.action == "list":
            wf = getattr(args, "workflow_id", None)
            rows = approvals_mod.list_pending(conn, workflow_id=wf)
            return _ok({"items": rows, "count": len(rows)})
    except ValueError as e:
        return _err(str(e))
    finally:
        conn.close()
    return _err(f"unknown approval action: {args.action}")


# ---------------------------------------------------------------------------
# Lease handler
# ---------------------------------------------------------------------------


def _handle_lease(args) -> int:
    """Handle all ``cc-policy lease`` subcommands.

    Subcommands:
      issue-for-dispatch <role>   Issue a new lease at dispatch time.
      claim <agent_id>            Claim an active lease by agent_id.
      get <lease_id>              Look up lease by ID.
      current                     Resolve active lease by any identity field.
      validate-op <command>       Composite validation of a git command.
      list                        List leases with optional filters.
      release <lease_id>          active → released.
      revoke <lease_id>           active → revoked.
      expire-stale                Expire all past-TTL active leases.
      summary                     Compact read model for a worktree/workflow.
    """
    import json as _json

    conn = _get_conn()
    try:
        if args.action == "issue-for-dispatch":
            allowed_ops = None
            blocked_ops = None
            metadata = None
            try:
                if getattr(args, "allowed_ops", None):
                    allowed_ops = _json.loads(args.allowed_ops)
                if getattr(args, "blocked_ops", None):
                    blocked_ops = _json.loads(args.blocked_ops)
                if getattr(args, "metadata", None):
                    metadata = _json.loads(args.metadata)
            except _json.JSONDecodeError as e:
                return _err(f"invalid JSON argument: {e}")
            requires_eval = not bool(getattr(args, "no_eval", False))
            lease = leases_mod.issue(
                conn,
                role=args.role,
                worktree_path=getattr(args, "worktree_path", None),
                workflow_id=getattr(args, "workflow_id", None),
                branch=getattr(args, "branch", None),
                allowed_ops=allowed_ops,
                blocked_ops=blocked_ops,
                requires_eval=requires_eval,
                head_sha=getattr(args, "head_sha", None),
                next_step=getattr(args, "next_step", None),
                ttl=int(getattr(args, "ttl", 7200) or 7200),
                metadata=metadata,
            )
            startup_contract = leases_mod.render_startup_contract(lease)
            return _ok({"lease": lease, "startup_contract": startup_contract})

        elif args.action == "claim":
            claimed = leases_mod.claim(
                conn,
                agent_id=args.agent_id,
                lease_id=getattr(args, "lease_id", None),
                worktree_path=getattr(args, "worktree_path", None),
                expected_role=getattr(args, "expected_role", None),
            )
            if claimed is None:
                reason = "role_mismatch" if getattr(args, "expected_role", None) else "not_found"
                return _ok({"claimed": False, "reason": reason})
            return _ok({"claimed": True, "lease": claimed})

        elif args.action == "get":
            lease = leases_mod.get(conn, args.lease_id)
            if lease is None:
                return _ok({"found": False})
            lease["found"] = True
            return _ok(lease)

        elif args.action == "current":
            lease = leases_mod.get_current(
                conn,
                lease_id=getattr(args, "lease_id", None),
                worktree_path=getattr(args, "worktree_path", None),
                agent_id=getattr(args, "agent_id", None),
                workflow_id=getattr(args, "workflow_id", None),
            )
            if lease is None:
                return _ok({"found": False})
            lease["found"] = True
            return _ok(lease)

        elif args.action == "validate-op":
            result = leases_mod.validate_op(
                conn,
                command=args.command,
                lease_id=getattr(args, "lease_id", None),
                worktree_path=getattr(args, "worktree_path", None),
                agent_id=getattr(args, "agent_id", None),
                workflow_id=getattr(args, "workflow_id", None),
            )
            return _ok(result)

        elif args.action == "list":
            rows = leases_mod.list_leases(
                conn,
                status=getattr(args, "status", None),
                workflow_id=getattr(args, "workflow_id", None),
                role=getattr(args, "role", None),
                worktree_path=getattr(args, "worktree_path", None),
            )
            return _ok({"items": rows, "count": len(rows)})

        elif args.action == "release":
            released = leases_mod.release(conn, args.lease_id)
            return _ok({"released": released})

        elif args.action == "revoke":
            revoked = leases_mod.revoke(conn, args.lease_id)
            return _ok({"revoked": revoked})

        elif args.action == "expire-stale":
            count = leases_mod.expire_stale(conn)
            return _ok({"expired_count": count})

        elif args.action == "summary":
            result = leases_mod.summary(
                conn,
                worktree_path=getattr(args, "worktree_path", None),
                workflow_id=getattr(args, "workflow_id", None),
            )
            return _ok(result)

    except ValueError as e:
        return _err(str(e))
    finally:
        conn.close()
    return _err(f"unknown lease action: {args.action}")


# ---------------------------------------------------------------------------
# Completion handler
# ---------------------------------------------------------------------------


def _handle_completion(args) -> int:
    """Handle all ``cc-policy completion`` subcommands.

    Subcommands:
      submit     Validate and record a role completion payload.
      latest     Return the most recent completion record.
      list       List completion records with optional filters.
    """
    import json as _json

    conn = _get_conn()
    try:
        if args.action == "submit":
            try:
                payload = _json.loads(args.payload)
            except _json.JSONDecodeError as e:
                return _err(f"invalid JSON payload: {e}")
            result = completions_mod.submit(
                conn,
                lease_id=args.lease_id,
                workflow_id=args.workflow_id,
                role=args.role,
                payload=payload,
            )
            return _ok(result)

        elif args.action == "latest":
            record = completions_mod.latest(
                conn,
                lease_id=getattr(args, "lease_id", None),
                workflow_id=getattr(args, "workflow_id", None),
            )
            if record is None:
                return _ok({"found": False})
            return _ok(record)

        elif args.action == "list":
            rows = completions_mod.list_completions(
                conn,
                lease_id=getattr(args, "lease_id", None),
                workflow_id=getattr(args, "workflow_id", None),
                role=getattr(args, "role", None),
                valid_only=bool(getattr(args, "valid_only", False)),
            )
            return _ok({"items": rows, "count": len(rows)})

        elif args.action == "route":
            # Deterministic routing: (role, verdict) → next_role.
            # Returns {"next_role": "guardian"|"implementer"|"planner"|null}.
            # next_role is null for cycle-complete terminal states (e.g. guardian merged).
            # This is the single authoritative routing call — post-task.sh must use this
            # instead of duplicating the case statement (DEC-COMPLETION-001).
            next_role = completions_mod.determine_next_role(args.role, args.verdict)
            return _ok({"next_role": next_role})

    except ValueError as e:
        return _err(str(e))
    finally:
        conn.close()
    return _err(f"unknown completion action: {args.action}")


# ---------------------------------------------------------------------------
# Bug pipeline handler
# ---------------------------------------------------------------------------


def _handle_bug(args) -> int:
    """Handle all ``cc-policy bug`` subcommands.

    Subcommands:
      qualify '<json>'        Dry-run qualification check — returns disposition.
      file '<json>'           Full pipeline: qualify -> fingerprint -> SQLite -> todo.sh.
      list [--disposition=X]  List tracked bugs, optionally filtered by disposition.
      retry-failed            Retry all bugs with disposition='failed_to_file'.

    JSON payload for ``file`` and ``qualify``:
      {"bug_type":"...","title":"...","body":"...","scope":"global",
       "source_component":"...","file_path":"...","evidence":"...","fixed_now":false}

    All output is JSON. Errors write to stderr with exit code 1.
    """
    import json as _json

    conn = _get_conn()
    try:
        if args.action == "qualify":
            try:
                payload = _json.loads(args.json_payload)
            except _json.JSONDecodeError as e:
                return _err(f"invalid JSON payload: {e}")
            disposition = bugs_mod.qualify(
                bug_type=payload.get("bug_type", ""),
                title=payload.get("title", ""),
                evidence=payload.get("evidence", ""),
                fixed_now=bool(payload.get("fixed_now", False)),
            )
            return _ok({"disposition": disposition})

        elif args.action == "file":
            try:
                payload = _json.loads(args.json_payload)
            except _json.JSONDecodeError as e:
                return _err(f"invalid JSON payload: {e}")
            result = bugs_mod.file_bug(
                conn,
                bug_type=payload.get("bug_type", ""),
                title=payload.get("title", ""),
                body=payload.get("body", ""),
                scope=payload.get("scope", "global"),
                source_component=payload.get("source_component", ""),
                file_path=payload.get("file_path", ""),
                evidence=payload.get("evidence", ""),
                fixed_now=bool(payload.get("fixed_now", False)),
            )
            return _ok(result)

        elif args.action == "list":
            disposition = getattr(args, "disposition", None) or None
            limit = getattr(args, "limit", 50) or 50
            rows = bugs_mod.list_bugs(conn, disposition=disposition, limit=int(limit))
            return _ok({"items": rows, "count": len(rows)})

        elif args.action == "retry-failed":
            results = bugs_mod.retry_failed(conn)
            return _ok({"items": results, "count": len(results)})

    except Exception as e:
        return _err(f"bug command error: {e}")
    finally:
        conn.close()
    return _err(f"unknown bug action: {args.action}")


# ---------------------------------------------------------------------------
# Sidecar handlers
# ---------------------------------------------------------------------------

# Registry of available sidecars by name, for `cc-policy sidecar list`
_SIDECAR_REGISTRY = {
    "observatory": "Read-only health observer over all runtime state domains",
    "search": "Read-only text search over traces and manifest entries",
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
            return _ok(
                {
                    "query": args.query,
                    "count": len(results),
                    "results": results,
                }
            )

        elif args.action == "list":
            return _ok(
                {
                    "sidecars": [
                        {"name": k, "description": v} for k, v in _SIDECAR_REGISTRY.items()
                    ],
                    "count": len(_SIDECAR_REGISTRY),
                }
            )

    finally:
        conn.close()
    return _err(f"unknown sidecar action: {args.action}")


# ---------------------------------------------------------------------------
# Policy engine handlers (PE-W1)
# ---------------------------------------------------------------------------


def _handle_evaluate(args) -> int:
    """Handle ``cc-policy evaluate`` — read JSON from stdin, return PolicyDecision.

    Input JSON (from stdin):
      {"event_type": "PreToolUse", "tool_name": "Write",
       "tool_input": {...}, "cwd": "/project",
       "actor_role": "implementer", "actor_id": "agent-123"}

    Output JSON:
      {"status": "ok", "action": "allow"|"deny"|"feedback",
       "reason": "...", "policy_name": "...",
       "hookSpecificOutput": {...}}

    hookSpecificOutput format matches Claude hook contract:
      deny     → {"permissionDecision": "deny", "permissionDecisionReason": "...",
                   "blockingHook": "<policy_name>"}
      allow    → {"permissionDecision": "allow"}
      feedback → {"additionalContext": "<reason>"}
    """
    import json as _json
    import os as _os
    import subprocess as _subprocess

    raw = sys.stdin.read()
    if not raw or not raw.strip():
        return _err("evaluate: empty input — refusing to allow (fail-closed)")

    try:
        payload = _json.loads(raw)
    except _json.JSONDecodeError as e:
        return _err(f"invalid JSON on stdin: {e}")

    event_type = payload.get("event_type", "")
    tool_name = payload.get("tool_name", "")
    tool_input = payload.get("tool_input", {})
    cwd = payload.get("cwd", "")
    actor_role = payload.get("actor_role", "")
    actor_id = payload.get("actor_id", "")

    # --- Target-aware context resolution (DEC-PE-W3-CTX-001) ---
    # When the command targets a different repo than the session cwd (e.g.
    # ``git -C /other-repo commit`` or ``cd /other-repo && git commit``),
    # the hook extracts the target directory and passes it as ``target_cwd``.
    # We resolve the git project root from target_cwd so that all downstream
    # state lookups (lease, scope, eval_state, test_state) use the target
    # repo's context, not the session repo's.
    #
    # Resolution order:
    #   1. target_cwd present and is a real directory → resolve git root from it
    #   2. target_cwd absent or not a directory → use cwd as before
    resolved_project_root = ""
    target_cwd = payload.get("target_cwd", "")
    if target_cwd and _os.path.isdir(target_cwd):
        try:
            r = _subprocess.run(
                ["git", "-C", target_cwd, "rev-parse", "--show-toplevel"],
                capture_output=True,
                text=True,
                timeout=5,
            )
            if r.returncode == 0:
                candidate = r.stdout.strip()
                if candidate and _os.path.isdir(candidate):
                    resolved_project_root = candidate
        except Exception:
            pass
        # If git root resolution failed (non-git dir), use target_cwd directly
        if not resolved_project_root:
            resolved_project_root = target_cwd

    conn = _get_conn()
    try:
        ctx = policy_engine_mod.build_context(
            conn,
            cwd=target_cwd if resolved_project_root else cwd,
            actor_role=actor_role,
            actor_id=actor_id,
            project_root=resolved_project_root,
        )

        request = policy_engine_mod.PolicyRequest(
            event_type=event_type,
            tool_name=tool_name,
            tool_input=tool_input,
            context=ctx,
            cwd=cwd,
        )

        decision = policy_engine_mod.default_registry().evaluate(request)

        # Apply stateful effects declared by policy functions.
        # Policies are pure functions — they cannot perform DB writes.
        # Effects are processed here, once, after the decision is reached.
        #
        # Supported effects:
        #   expire_stale_leases: bool
        #     → call leases_mod.expire_stale(conn) to flush timed-out leases.
        #   check_and_consume_approval: {"workflow_id": str, "op_type": str}
        #     → attempt to consume a one-shot approval token. If consumed,
        #       override the deny decision to allow (the token grants the op).
        #       If not consumed, leave the deny in place.
        effects = decision.effects or {}

        if effects.get("expire_stale_leases"):
            try:
                leases_mod.expire_stale(conn)
            except Exception:
                pass  # Non-fatal: stale cleanup is best-effort

        approval_effect = effects.get("check_and_consume_approval")
        if approval_effect and decision.action == "deny":
            wf_id = approval_effect.get("workflow_id", "")
            op_type = approval_effect.get("op_type", "")
            if wf_id and op_type:
                try:
                    consumed = approvals_mod.check_and_consume(conn, wf_id, op_type)
                    if consumed:
                        # Token consumed — override the deny to allow.
                        decision = policy_engine_mod.PolicyDecision(
                            action="allow",
                            reason=f"Approval token consumed for '{op_type}' on workflow '{wf_id}'.",
                            policy_name=decision.policy_name,
                        )
                except Exception:
                    pass  # Non-fatal: denial stands if consumption fails
    finally:
        conn.close()

    # Build hookSpecificOutput per Claude hook contract
    if decision.action == "deny":
        hook_output = {
            "permissionDecision": "deny",
            "permissionDecisionReason": decision.reason,
            "blockingHook": decision.policy_name,
        }
    elif decision.action == "feedback":
        hook_output = {"additionalContext": decision.reason}
    else:
        hook_output = {"permissionDecision": "allow"}

    return _ok(
        {
            "action": decision.action,
            "reason": decision.reason,
            "policy_name": decision.policy_name,
            "hookSpecificOutput": hook_output,
        }
    )


def _handle_policy(args) -> int:
    """Handle ``cc-policy policy`` subcommands.

    Subcommands:
      list     — return registered policies as JSON array
      explain  — read JSON from stdin, return full evaluation trace
    """
    import json as _json

    if args.action == "list":
        reg = policy_engine_mod.default_registry()
        policies = [
            {
                "name": p.name,
                "priority": p.priority,
                "event_types": p.event_types,
                "enabled": p.enabled,
            }
            for p in reg.list_policies()
        ]
        return _ok({"policies": policies, "count": len(policies)})

    elif args.action == "explain":
        raw = sys.stdin.read()
        try:
            payload = _json.loads(raw)
        except _json.JSONDecodeError as e:
            return _err(f"invalid JSON on stdin: {e}")

        event_type = payload.get("event_type", "")
        tool_name = payload.get("tool_name", "")
        tool_input = payload.get("tool_input", {})
        cwd = payload.get("cwd", "")
        actor_role = payload.get("actor_role", "")
        actor_id = payload.get("actor_id", "")

        conn = _get_conn()
        try:
            ctx = policy_engine_mod.build_context(
                conn, cwd=cwd, actor_role=actor_role, actor_id=actor_id
            )
        finally:
            conn.close()

        request = policy_engine_mod.PolicyRequest(
            event_type=event_type,
            tool_name=tool_name,
            tool_input=tool_input,
            context=ctx,
            cwd=cwd,
        )

        evals = policy_engine_mod.default_registry().explain(request)
        trace = [
            {
                "policy_name": e.policy_name,
                "result": e.result,
                "reason": e.reason,
            }
            for e in evals
        ]
        return _ok({"trace": trace, "count": len(trace)})

    return _err(f"unknown policy action: {args.action}")


# ---------------------------------------------------------------------------
# test-state: SQLite-backed authority (WS3 — replaces flat-file bridge)
# ---------------------------------------------------------------------------

import runtime.core.test_state as ts_mod


def _resolve_project_root(args) -> str:
    """Resolve project_root from args, env, or git root. Returns '' on failure."""
    project_root = getattr(args, "project_root", None) or ""
    if not project_root:
        import os

        project_root = os.environ.get("CLAUDE_PROJECT_DIR", "")
    if not project_root:
        import subprocess

        result = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True,
            text=True,
        )
        project_root = result.stdout.strip() if result.returncode == 0 else ""
    return project_root


def _handle_test_state(args) -> int:
    """Read/write test state via the SQLite test_state table.

    Replaces the TKT-STAB-A4 flat-file bridge. The flat-file
    .claude/.test-status is no longer read by this handler — test_state
    is the canonical authority. test-runner.sh may still WRITE the flat-file
    for backward compatibility (session-init.sh clears it), but no
    enforcement hook reads it.

    @decision DEC-WS3-001
    Title: test-state subcommand reads/writes SQLite, not flat-file
    Status: accepted
    Rationale: DEC-STAB-A4-003 described the flat-file bridge as temporary.
      WS3 completes the migration: _handle_test_state now delegates to
      runtime.core.test_state which owns the test_state SQLite table.
      get returns the row dict; set upserts it. The flat-file is not
      consulted. Guard hooks updated in WS3 call rt_test_state_get (via
      runtime-bridge.sh) which calls this CLI endpoint.
    """
    if args.action == "get":
        project_root = _resolve_project_root(args)
        if not project_root:
            return _ok({"found": False, "status": "unknown", "fail_count": 0})
        conn = _get_conn()
        result = ts_mod.get_status(conn, project_root)
        conn.close()
        return _ok(result)

    if args.action == "set":
        project_root = _resolve_project_root(args)
        if not project_root:
            return _err("test-state set requires --project-root or CLAUDE_PROJECT_DIR")
        conn = _get_conn()
        ts_mod.set_status(
            conn,
            project_root,
            args.status,
            head_sha=getattr(args, "head_sha", None),
            pass_count=getattr(args, "passed", 0) or 0,
            fail_count=getattr(args, "failed", 0) or 0,
            total_count=getattr(args, "total", 0) or 0,
        )
        conn.close()
        return _ok({"project_root": project_root, "status": args.status})

    return _err(f"unknown test-state action: {args.action}")


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

    # evaluation
    eval_p = subparsers.add_parser("evaluation", help="Evaluator-state readiness authority")
    eval_sub = eval_p.add_subparsers(dest="action", required=True)
    eg = eval_sub.add_parser("get")
    eg.add_argument("workflow_id")
    es_p = eval_sub.add_parser("set")
    es_p.add_argument("workflow_id")
    es_p.add_argument(
        "status",
        choices=["idle", "pending", "needs_changes", "ready_for_guardian", "blocked_by_plan"],
    )
    es_p.add_argument("--head-sha", dest="head_sha", default=None)
    es_p.add_argument("--blockers", type=int, default=0)
    es_p.add_argument("--major", type=int, default=0)
    es_p.add_argument("--minor", type=int, default=0)
    eval_sub.add_parser("list")
    ei = eval_sub.add_parser("invalidate")
    ei.add_argument("workflow_id")

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
    marker_sub.add_parser("expire-stale")

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
    tr_start.add_argument(
        "--role", dest="role", default=None, help="Agent role (implementer, tester, planner, ...)"
    )
    tr_start.add_argument("--ticket", default=None, help="Ticket reference (e.g. TKT-013)")

    tr_end = tr_sub.add_parser("end", help="Close a trace with optional summary")
    tr_end.add_argument("session_id")
    tr_end.add_argument(
        "--summary", default=None, help="Human-readable summary of what the session accomplished"
    )

    tr_manifest = tr_sub.add_parser("manifest", help="Add a manifest entry to a trace")
    tr_manifest.add_argument("session_id")
    tr_manifest.add_argument(
        "entry_type", help="Entry type: file_read, file_write, decision, command, event"
    )
    tr_manifest.add_argument("--path", default=None, help="File path (for file_read/file_write)")
    tr_manifest.add_argument("--detail", default=None, help="Description of the entry")

    tr_get = tr_sub.add_parser("get", help="Get a trace with its manifest")
    tr_get.add_argument("session_id")

    tr_recent = tr_sub.add_parser("recent", help="List recent traces")
    tr_recent.add_argument(
        "--limit", type=int, default=10, help="Maximum number of traces to return (default 10)"
    )

    # tokens
    tok_p = subparsers.add_parser("tokens", help="Session token accumulation")
    tok_sub = tok_p.add_subparsers(dest="action", required=True)

    tok_upsert = tok_sub.add_parser("upsert", help="Write session token total")
    tok_upsert.add_argument("session_id", help="Session identifier (e.g. pid:1234)")
    tok_upsert.add_argument("project_hash", help="8-char project hash")
    tok_upsert.add_argument("total_tokens", type=int, help="Running token total for this session")

    tok_lifetime = tok_sub.add_parser(
        "lifetime", help="Sum tokens across all sessions for a project"
    )
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
    wf_scope_set.add_argument("--allowed", default="[]", help="JSON array of allowed path globs")
    wf_scope_set.add_argument("--required", default="[]", help="JSON array of required path globs")
    wf_scope_set.add_argument(
        "--forbidden", default="[]", help="JSON array of forbidden path globs"
    )
    wf_scope_set.add_argument(
        "--authorities", default="[]", help="JSON array of authority domain names"
    )

    wf_scope_get = wf_sub.add_parser("scope-get", help="Get scope manifest for a workflow")
    wf_scope_get.add_argument("workflow_id")

    wf_scope_check = wf_sub.add_parser("scope-check", help="Check changed files against scope")
    wf_scope_check.add_argument("workflow_id")
    wf_scope_check.add_argument("--changed", default="[]", help="JSON array of changed file paths")

    wf_sub.add_parser("list", help="List all workflow bindings")

    # bug pipeline
    bug_p = subparsers.add_parser("bug", help="Canonical bug-filing pipeline")
    bug_sub = bug_p.add_subparsers(dest="action", required=True)

    bug_qualify = bug_sub.add_parser("qualify", help="Dry-run qualification check")
    bug_qualify.add_argument(
        "json_payload",
        metavar="JSON",
        help="JSON payload with bug_type, title, evidence, [fixed_now]",
    )

    bug_file = bug_sub.add_parser("file", help="Full pipeline: qualify, dedup, file to GitHub")
    bug_file.add_argument(
        "json_payload",
        metavar="JSON",
        help="JSON payload with bug_type, title, body, scope, "
        "source_component, file_path, evidence, [fixed_now]",
    )

    bug_list = bug_sub.add_parser("list", help="List tracked bugs")
    bug_list.add_argument(
        "--disposition",
        default=None,
        help="Filter by disposition (filed, duplicate, failed_to_file, ...)",
    )
    bug_list.add_argument(
        "--limit", type=int, default=50, help="Maximum rows to return (default 50)"
    )

    bug_sub.add_parser("retry-failed", help="Retry all failed_to_file bugs")

    # approval
    ap_p = subparsers.add_parser("approval", help="One-shot approval tokens for high-risk git ops")
    ap_sub = ap_p.add_subparsers(dest="action", required=True)

    ap_grant = ap_sub.add_parser("grant", help="Grant one-shot approval for a high-risk op")
    ap_grant.add_argument("workflow_id")
    ap_grant.add_argument(
        "op_type",
        # Derive choices from the canonical APPROVAL_OP_TYPES constant so the
        # CLI and the domain layer stay in sync automatically (DEC-LEASE-002).
        choices=sorted(approvals_mod.VALID_OP_TYPES),
    )
    ap_grant.add_argument("--granted-by", dest="granted_by", default="user")

    ap_check = ap_sub.add_parser("check", help="Check and consume an approval token")
    ap_check.add_argument("workflow_id")
    ap_check.add_argument("op_type")

    ap_list = ap_sub.add_parser("list", help="List pending (unconsumed) approvals")
    ap_list.add_argument("--workflow-id", dest="workflow_id", default=None)

    # lease
    ls_p = subparsers.add_parser("lease", help="Dispatch lease lifecycle")
    ls_sub = ls_p.add_subparsers(dest="action", required=True)

    ls_issue = ls_sub.add_parser("issue-for-dispatch", help="Issue a new dispatch lease")
    ls_issue.add_argument("role", help="Agent role (implementer, tester, guardian, planner)")
    ls_issue.add_argument("--workflow-id", dest="workflow_id", default=None)
    ls_issue.add_argument("--worktree-path", dest="worktree_path", default=None)
    ls_issue.add_argument("--branch", default=None)
    ls_issue.add_argument("--allowed-ops", dest="allowed_ops", default=None, help="JSON array")
    ls_issue.add_argument("--blocked-ops", dest="blocked_ops", default=None, help="JSON array")
    ls_issue.add_argument("--head-sha", dest="head_sha", default=None)
    ls_issue.add_argument("--next-step", dest="next_step", default=None)
    ls_issue.add_argument("--ttl", type=int, default=7200, help="Seconds (default 7200)")
    ls_issue.add_argument("--metadata", default=None, help="JSON object")
    ls_issue.add_argument(
        "--no-eval",
        dest="no_eval",
        action="store_true",
        default=False,
        help="Set requires_eval=False",
    )

    ls_claim = ls_sub.add_parser("claim", help="Claim an active lease for an agent")
    ls_claim.add_argument("agent_id")
    ls_claim.add_argument("--lease-id", dest="lease_id", default=None)
    ls_claim.add_argument("--worktree-path", dest="worktree_path", default=None)
    ls_claim.add_argument(
        "--expected-role",
        dest="expected_role",
        default=None,
        help="If set, claim fails unless lease role matches (DEC-LEASE-003)",
    )

    ls_get = ls_sub.add_parser("get", help="Look up lease by lease_id")
    ls_get.add_argument("lease_id")

    ls_current = ls_sub.add_parser("current", help="Resolve active lease by identity fields")
    ls_current.add_argument("--lease-id", dest="lease_id", default=None)
    ls_current.add_argument("--worktree-path", dest="worktree_path", default=None)
    ls_current.add_argument("--agent-id", dest="agent_id", default=None)
    ls_current.add_argument("--workflow-id", dest="workflow_id", default=None)

    ls_vop = ls_sub.add_parser("validate-op", help="Composite validation of a git command")
    ls_vop.add_argument("command", help="Full git command string to validate")
    ls_vop.add_argument("--lease-id", dest="lease_id", default=None)
    ls_vop.add_argument("--worktree-path", dest="worktree_path", default=None)
    ls_vop.add_argument("--agent-id", dest="agent_id", default=None)
    ls_vop.add_argument("--workflow-id", dest="workflow_id", default=None)

    ls_list = ls_sub.add_parser("list", help="List leases with optional filters")
    ls_list.add_argument("--status", default=None)
    ls_list.add_argument("--workflow-id", dest="workflow_id", default=None)
    ls_list.add_argument("--role", default=None)
    ls_list.add_argument("--worktree-path", dest="worktree_path", default=None)

    ls_release = ls_sub.add_parser("release", help="Transition active lease to released")
    ls_release.add_argument("lease_id")

    ls_revoke = ls_sub.add_parser("revoke", help="Transition active lease to revoked")
    ls_revoke.add_argument("lease_id")

    ls_sub.add_parser("expire-stale", help="Expire all past-TTL active leases")

    ls_summary = ls_sub.add_parser("summary", help="Compact read model for worktree/workflow")
    ls_summary.add_argument("--worktree-path", dest="worktree_path", default=None)
    ls_summary.add_argument("--workflow-id", dest="workflow_id", default=None)

    # completion
    co_p = subparsers.add_parser("completion", help="Completion records for role task endings")
    co_sub = co_p.add_subparsers(dest="action", required=True)

    co_submit = co_sub.add_parser("submit", help="Validate and record a completion payload")
    co_submit.add_argument("--lease-id", dest="lease_id", required=True)
    co_submit.add_argument("--workflow-id", dest="workflow_id", required=True)
    co_submit.add_argument("--role", required=True)
    co_submit.add_argument("--payload", required=True, help="JSON object with completion fields")

    co_latest = co_sub.add_parser("latest", help="Return most recent completion record")
    co_latest.add_argument("--lease-id", dest="lease_id", default=None)
    co_latest.add_argument("--workflow-id", dest="workflow_id", default=None)

    co_list = co_sub.add_parser("list", help="List completion records with optional filters")
    co_list.add_argument("--lease-id", dest="lease_id", default=None)
    co_list.add_argument("--workflow-id", dest="workflow_id", default=None)
    co_list.add_argument("--role", default=None)
    co_list.add_argument(
        "--valid-only",
        dest="valid_only",
        action="store_true",
        default=False,
        help="Return only valid=1 records",
    )

    co_route = co_sub.add_parser(
        "route",
        help="Determine the next role given (role, verdict) using the canonical routing table",
    )
    co_route.add_argument("role", help="Completing role (tester, guardian, implementer, planner)")
    co_route.add_argument("verdict", help="Verdict string from the completion record")

    # sidecar
    sc_p = subparsers.add_parser("sidecar", help="Shadow-mode read-only sidecars")
    sc_sub = sc_p.add_subparsers(dest="action", required=True)

    sc_sub.add_parser("observatory", help="Run observatory health report")
    sc_sub.add_parser("list", help="List available sidecars")

    sc_search = sc_sub.add_parser("search", help="Search traces and manifest entries")
    sc_search.add_argument("query", help="Search term (case-insensitive substring)")
    sc_search.add_argument(
        "--limit", type=int, default=10, help="Maximum results to return (default 10)"
    )

    # evaluate — read JSON from stdin, return PolicyDecision
    subparsers.add_parser(
        "evaluate",
        help="Evaluate a hook event against all registered policies (JSON on stdin)",
    )

    # policy — list and explain registered policies
    pol_p = subparsers.add_parser("policy", help="Policy registry introspection")
    pol_sub = pol_p.add_subparsers(dest="action", required=True)
    pol_sub.add_parser("list", help="List all registered policies as JSON array")
    pol_sub.add_parser(
        "explain",
        help="Run all policies without short-circuit and return full trace (JSON on stdin)",
    )

    # test-state: flat-file bridge (TKT-STAB-A4)
    # test-state: SQLite-backed authority (WS3 — replaces flat-file bridge)
    ts_p = subparsers.add_parser(
        "test-state", help="Read/write test state from the SQLite test_state table"
    )
    ts_sub = ts_p.add_subparsers(dest="action", required=True)

    _ts_root_kwargs = dict(
        dest="project_root",
        default=None,
        help="Path to project root (falls back to CLAUDE_PROJECT_DIR or git root)",
    )
    ts_get = ts_sub.add_parser("get", help="Return test status JSON for a project root")
    ts_get.add_argument("--project-root", **_ts_root_kwargs)

    ts_set = ts_sub.add_parser("set", help="Write test status to the runtime table")
    ts_set.add_argument("status", help="Status string: pass | fail | pass_complete | unknown")
    ts_set.add_argument("--project-root", **_ts_root_kwargs)
    ts_set.add_argument("--head-sha", dest="head_sha", default=None, help="Git HEAD SHA")
    ts_set.add_argument("--passed", type=int, default=0, help="Number of passing tests")
    ts_set.add_argument("--failed", type=int, default=0, help="Number of failing tests")
    ts_set.add_argument("--total", type=int, default=0, help="Total test count")

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
    if args.domain == "evaluation":
        return _handle_evaluation(args)
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
    if args.domain == "bug":
        return _handle_bug(args)
    if args.domain == "approval":
        return _handle_approval(args)
    if args.domain == "lease":
        return _handle_lease(args)
    if args.domain == "completion":
        return _handle_completion(args)
    if args.domain == "test-state":
        return _handle_test_state(args)
    if args.domain == "evaluate":
        return _handle_evaluate(args)
    if args.domain == "policy":
        return _handle_policy(args)

    return _err(f"unknown domain: {args.domain}")


if __name__ == "__main__":
    raise SystemExit(main())
