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
import runtime.core.critic_reviews as critic_reviews_mod
import runtime.core.dispatch_engine as dispatch_engine_mod
import runtime.core.enforcement_config as enforcement_config_mod
import runtime.core.eval_metrics as eval_metrics_mod
import runtime.core.hook_doc_validation as hook_doc_validation_mod
import runtime.core.hook_manifest as hook_manifest_mod
import runtime.core.prompt_pack_validation as prompt_pack_validation_mod
import runtime.core.eval_report as eval_report_mod
import runtime.core.eval_scorer as eval_scorer_mod
import runtime.core.evaluation as evaluation_mod
import runtime.core.events as events_mod
import runtime.core.leases as leases_mod
import runtime.core.lifecycle as lifecycle_mod
import runtime.core.markers as markers_mod
import runtime.core.observatory as observatory_mod
import runtime.core.policy_engine as policy_engine_mod
import runtime.core.workflow_bootstrap as workflow_bootstrap_mod
import runtime.core.quick_eval as quick_eval_mod
import runtime.core.shadow_parity as shadow_parity_mod
import runtime.core.scratchlanes as scratchlanes_mod
import runtime.core.statusline as statusline_mod
import runtime.core.todos as todos_mod
import runtime.core.tokens as tokens_mod
import runtime.core.traces as traces_mod
import runtime.core.workflows as workflows_mod
import runtime.core.worktrees as worktrees_mod
from runtime.core.config import default_db_path, resolve_db_path
from runtime.core.db import connect
from runtime.eval_schemas import ensure_eval_schema  # noqa: F401 — imported for eval_metrics
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


def _get_conn(project_root: str | None = None):
    db_path = resolve_db_path(project_root=project_root)
    conn = connect(db_path)
    ensure_schema(conn)
    return conn


def _agent_contract_carrier_effect(conn, payload: dict, decision):
    """Write the Agent contract carrier after policy allow.

    ``agent_contract_required`` owns launch validation. This helper runs only
    after that policy gate has allowed the Agent/Task invocation, then performs
    the stateful carrier write that lets ``SubagentStart`` receive the same
    six-field contract. Shell hooks must not duplicate contract shape, stage, or
    subagent validation.
    """
    import os as _os
    import time as _time

    from runtime.core.agent_contract_codec import (
        CONTRACT_BLOCK_PREFIX as _CONTRACT_BLOCK_PREFIX,
        first_line_contract_json as _first_line_contract_json,
    )
    from runtime.core.dispatch_contract import (
        dispatch_subagent_type_for_stage as _dispatch_subagent_type_for_stage,
    )
    from runtime.core.dispatch_hook import record_agent_dispatch as _record_agent_dispatch
    from runtime.core.pending_agent_requests import write_pending_request as _write_pending_request

    if decision.action != "allow":
        return None
    if payload.get("event_type") != "PreToolUse":
        return None
    if payload.get("tool_name") not in ("Agent", "Task"):
        return None

    tool_input = payload.get("tool_input", {})
    if not isinstance(tool_input, dict):
        return None
    prompt = tool_input.get("prompt", "") or ""
    contract_raw = _first_line_contract_json(prompt)
    if contract_raw is None:
        return None

    session_id = str(payload.get("session_id") or "")
    if not session_id:
        # Preserve the historical hook behavior: a malformed/missing session id
        # means there is no transport correlation key, so no carrier row is
        # written. Real Claude Code PreToolUse payloads include session_id.
        return None

    if payload.get("carrier_db_resolved") is False:
        return policy_engine_mod.PolicyDecision(
            action="deny",
            reason=(
                "carrier_write_failed: no project policy DB path could be resolved "
                "for canonical Agent dispatch. Set CLAUDE_POLICY_DB or run from "
                "inside a git repo with .claude/state.db."
            ),
            policy_name="agent_contract_carrier",
        )

    try:
        contract = json.loads(contract_raw)
        stage_id = str(contract.get("stage_id") or "")
        expected_subagent_type = _dispatch_subagent_type_for_stage(stage_id)
        if not expected_subagent_type:
            raise ValueError(f"unknown active stage: {stage_id!r}")

        _write_pending_request(
            conn,
            session_id=session_id,
            agent_type=expected_subagent_type,
            workflow_id=str(contract["workflow_id"]),
            stage_id=stage_id,
            goal_id=str(contract["goal_id"]),
            work_item_id=str(contract["work_item_id"]),
            decision_scope=str(contract["decision_scope"]),
            generated_at=int(contract["generated_at"]),
        )
    except Exception as exc:
        return policy_engine_mod.PolicyDecision(
            action="deny",
            reason=(
                "carrier_write_failed: pending_agent_requests row could not be "
                f"written for canonical Agent dispatch. Detail: {exc}"
            ),
            policy_name="agent_contract_carrier",
        )

    timeout_at = None
    timeout_seconds = _os.environ.get("CLAUDEX_DISPATCH_ATTEMPT_TIMEOUT_SECONDS", "2700")
    if timeout_seconds.isdigit() and int(timeout_seconds) > 0:
        timeout_at = int(_time.time()) + int(timeout_seconds)

    try:
        workflow_id = str(contract.get("workflow_id") or "")
        instruction = prompt.split("\n", 1)[0]
        if not instruction.startswith(_CONTRACT_BLOCK_PREFIX):
            instruction = f"{_CONTRACT_BLOCK_PREFIX}{contract_raw}"
        _record_agent_dispatch(
            conn,
            session_id,
            expected_subagent_type,
            instruction,
            workflow_id=workflow_id or None,
            timeout_at=timeout_at,
        )
    except Exception:
        # Delivery tracking is diagnostic. The carrier row is the required
        # SubagentStart handoff, so tracking failures do not block dispatch.
        pass

    return None


# ---------------------------------------------------------------------------
# Domain handlers
# ---------------------------------------------------------------------------


def _handle_schema(args) -> int:
    conn = _get_conn()
    conn.close()
    return _ok({"message": "schema ensured"})


def _handle_config(args) -> int:
    """Handle all ``cc-policy config`` subcommands.

    Subcommands:
      get <key> [--workflow-id <id>] [--project-root <path>]
          Look up a toggle with scope precedence (workflow > project > global).
      set <key> <value> [--scope global|project=...|workflow=...]
          Write a toggle. Guardian-only for enforcement-sensitive keys; the
          user-facing regular Stop key may also be written by the orchestrator
          path (empty CLAUDE_AGENT_ROLE). actor_role is read from the env.
      list [--scope <scope>]
          List all enforcement_config rows, optionally filtered by scope.

    All subcommands output JSON {"status": "ok", ...} on success.
    PermissionError from set_ is surfaced as {"status": "error", "message": ...}.
    """
    import os

    conn = _get_conn()
    try:
        if args.action == "get":
            value = enforcement_config_mod.get(
                conn,
                args.key,
                workflow_id=getattr(args, "workflow_id", "") or "",
                project_root=getattr(args, "project_root", "") or "",
            )
            return _ok({"key": args.key, "value": value, "found": value is not None})

        elif args.action == "set":
            actor_role = os.environ.get("CLAUDE_AGENT_ROLE", "") or ""
            scope = getattr(args, "scope", "global") or "global"
            enforcement_config_mod.set_(
                conn,
                args.key,
                args.value,
                scope=scope,
                actor_role=actor_role,
            )
            return _ok({"key": args.key, "value": args.value, "scope": scope})

        elif args.action == "list":
            scope_filter = getattr(args, "scope", None)
            rows = enforcement_config_mod.list_all(conn, scope=scope_filter)
            return _ok({"items": rows, "count": len(rows)})

    except enforcement_config_mod.PermissionError as e:
        return _err(str(e))
    except ValueError as e:
        return _err(str(e))
    finally:
        conn.close()
    return _err(f"unknown config action: {args.action}")


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
    # Shared by set and get-active; both accept --project-root/--workflow-id
    # scoping per W-CONV-2 (set) and ENFORCE-RCA-6-ext/#26 (get-active).
    from runtime.core.policy_utils import normalize_path as _norm_path

    conn = _get_conn()
    try:
        if args.action == "set":
            # W-CONV-2: accept optional --project-root and --workflow-id so the
            # test-marker-lifecycle.sh helper and production callers can write
            # scoped markers via `cc-policy marker set`.
            #
            # A21 hardening: when --project-root is omitted, resolve through the
            # canonical CLI resolver (_resolve_project_root: args → env
            # CLAUDE_PROJECT_DIR → git toplevel → normalize_path) so normal repo
            # sessions no longer persist agent_markers.project_root = NULL.
            # This closes the A19R secondary defect where scoped
            # `marker get-active --project-root <root>` could not find a marker
            # written by `marker set` without the flag. If resolution still
            # returns empty (no args, no env, cwd outside a git repo), fall back
            # to the legacy unscoped write (project_root=None) rather than
            # crashing — preserving backward compat for context-less callers.
            _pr = getattr(args, "project_root", None) or ""
            if not _pr:
                _pr = _resolve_project_root(args)
            _wf = getattr(args, "workflow_id", None) or ""
            markers_mod.set_active(
                conn,
                args.agent_id,
                args.role,
                project_root=_norm_path(_pr) if _pr else None,
                workflow_id=_wf if _wf else None,
            )
            return _ok({"agent_id": args.agent_id, "role": args.role})

        elif args.action == "get-active":
            # ENFORCE-RCA-6-ext/#26: honor --project-root and --workflow-id
            # scoping so the caller can filter to its own project and avoid
            # returning a stale marker from an unrelated project.
            _pr = getattr(args, "project_root", None)
            _wf = getattr(args, "workflow_id", None)
            result = markers_mod.get_active(
                conn,
                project_root=_norm_path(_pr) if _pr else None,
                workflow_id=_wf if _wf else None,
            )
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
                source=getattr(args, "source", None),
                since=getattr(args, "since", None),
                limit=getattr(args, "limit", 50),
            )
            return _ok({"items": rows, "count": len(rows)})

    finally:
        conn.close()
    return _err(f"unknown event action: {args.action}")


def _handle_doc(args) -> int:
    """Thin CLI adapter over runtime.core.doc_reference_validation.

    ``cc-policy doc ref-check <path>``:
        Scan the markdown at ``<path>`` for hook-surface references and
        diff them against HOOK_MANIFEST. Prints the structured report as
        JSON. Exits non-zero when drift is detected (unknown adapter
        paths, unknown events, or unknown event-matcher pairs).
    """
    from runtime.core.doc_reference_validation import validate_doc_references_file

    if args.action == "ref-check":
        path = args.path
        if not Path(path).is_file():
            return _err(f"doc ref-check: path not found or not a file: {path}")
        report = validate_doc_references_file(path)
        body = report.as_dict()
        # Non-zero exit on drift; stable JSON body either way.
        if not report.healthy:
            return _err(json.dumps(body, sort_keys=True))
        return _ok(body)

    return _err(f"unknown doc action: {args.action}")


def _handle_hook(args) -> int:
    """Handle ``cc-policy hook`` subcommands (read-only hook tools).

    Two actions are currently supported:

    * ``validate-settings`` (DEC-CLAUDEX-HOOK-MANIFEST-001) —
      compares repo-owned hook adapter entries in ``settings.json``
      against ``runtime.core.hook_manifest.HOOK_MANIFEST``, reports
      drift in both directions plus any repo-owned adapter paths
      that do not resolve to tracked files on disk.
    * ``doc-check`` (DEC-CLAUDEX-HOOK-DOC-VALIDATION-001) — reads a
      candidate ``hooks/HOOKS.md`` from disk, pipes it through
      ``runtime.core.hook_doc_validation.validate_hook_doc`` against
      the runtime-compiled hook-doc projection, and reports drift.

    Both commands are strictly read-only — they do not rewrite
    ``settings.json`` or ``hooks/HOOKS.md``, do not execute any
    hook adapter, do not write to the runtime DB, and do not emit
    any event.
    """
    if args.action == "validate-settings":
        from pathlib import Path

        settings_path_str = getattr(args, "settings_path", None)
        # Default: the settings.json at the repo root (parent of runtime/).
        if settings_path_str:
            settings_path = Path(settings_path_str).resolve()
        else:
            settings_path = (_PROJECT_ROOT / "settings.json").resolve()

        if not settings_path.is_file():
            return _err(
                f"hook validate-settings: settings file not found at {settings_path}"
            )

        try:
            with settings_path.open() as f:
                settings = json.load(f)
        except (OSError, json.JSONDecodeError) as exc:
            return _err(
                f"hook validate-settings: failed to read {settings_path}: {exc}"
            )

        # Determine the repo root that adapter_paths resolve relative to.
        # When --settings-path is given we trust the file's parent
        # directory; otherwise we use the computed _PROJECT_ROOT.
        if settings_path_str:
            repo_root = settings_path.parent
        else:
            repo_root = _PROJECT_ROOT

        # Filesystem existence check: for every repo-owned adapter that
        # settings.json references, verify the file exists. This is the
        # part of the validation that cannot live in the pure helper.
        settings_entries = hook_manifest_mod.extract_repo_owned_entries(settings)
        missing_paths: list[str] = []
        seen: set[str] = set()
        for _event, _matcher, adapter_path in settings_entries:
            if adapter_path in seen:
                continue
            seen.add(adapter_path)
            full = (repo_root / adapter_path).resolve()
            if not full.is_file():
                missing_paths.append(adapter_path)

        report = hook_manifest_mod.validate_settings(
            settings,
            missing_files=tuple(sorted(missing_paths)),
        )

        payload = {
            "report": report,
            "settings_path": str(settings_path),
            "repo_root": str(repo_root),
        }

        if report["healthy"]:
            return _ok(payload)
        # Unhealthy: print structured JSON to stdout (CI-friendly) and
        # return exit code 1. Follows the same convention as
        # ``cc-policy shadow parity-invariant``.
        payload["status"] = "violation"
        print(json.dumps(payload))
        return 1

    if args.action == "doc-check":
        import time as _time
        from pathlib import Path

        doc_path_str = getattr(args, "doc_path", None)
        if doc_path_str:
            doc_path = Path(doc_path_str).resolve()
        else:
            doc_path = (_PROJECT_ROOT / "hooks" / "HOOKS.md").resolve()

        if not doc_path.is_file():
            return _err(
                f"hook doc-check: hook doc not found at {doc_path}"
            )

        try:
            candidate = doc_path.read_text(encoding="utf-8")
        except OSError as exc:
            return _err(
                f"hook doc-check: failed to read {doc_path}: {exc}"
            )

        # ``repo_root`` in the payload is always ``_PROJECT_ROOT`` —
        # the runtime compiles the expected body from the currently
        # loaded ``HOOK_MANIFEST``, which lives under the running
        # repo, not under ``--doc-path``'s parent. ``doc_path``
        # tells the user which file the candidate came from;
        # ``repo_root`` tells them which manifest it was compared
        # against.
        repo_root = _PROJECT_ROOT

        # ``generated_at`` is required by the validator but does
        # NOT affect the content hash (the hash is derived from the
        # rendered body, which is independent of the timestamp).
        # Passing ``int(time.time())`` keeps the CLI usable in
        # production while leaving drift detection deterministic
        # across repeated calls.
        report = hook_doc_validation_mod.validate_hook_doc(
            candidate,
            generated_at=int(_time.time()),
        )

        payload = {
            "report": report,
            "doc_path": str(doc_path),
            "repo_root": str(repo_root),
        }

        if report["healthy"]:
            return _ok(payload)
        payload["status"] = "violation"
        print(json.dumps(payload))
        return 1

    return _err(f"unknown hook action: {args.action}")


def _handle_bridge(args) -> int:
    """Handle ``cc-policy bridge`` subcommands (read-only bridge tools).

    Current actions:

    * ``validate-settings`` (DEC-CLAUDEX-BRIDGE-PERMISSIONS-001) —
      reads ``ClauDEX/bridge/claude-settings.json`` (or the file
      specified by ``--settings-path``), runs
      ``runtime.core.bridge_permissions.validate_bridge_settings``,
      and reports drift. Exit 0 with ``{"status": "ok"}`` on clean;
      exit non-zero with ``{"status": "drift", "messages": [...]}``
      on violation.
    * ``broker-health`` — classify broker pid/socket health.
    * ``probe-response-drift`` — classify response-surface drift for a run.
    * ``topology`` — return the runtime-owned live lane topology probe.

    This command is strictly read-only — it does not rewrite the
    bridge file, does not write to the runtime DB, and does not emit
    any event.
    """
    if args.action == "validate-settings":
        from pathlib import Path

        import runtime.core.bridge_permissions as bridge_permissions_mod

        settings_path_str = getattr(args, "settings_path", None)
        if settings_path_str:
            settings_path = Path(settings_path_str).resolve()
        else:
            # Default: ClauDEX/bridge/claude-settings.json at repo root.
            settings_path = (
                _PROJECT_ROOT / "ClauDEX" / "bridge" / "claude-settings.json"
            ).resolve()

        if not settings_path.is_file():
            return _err(
                f"bridge validate-settings: settings file not found at {settings_path}"
            )

        try:
            with settings_path.open() as f:
                settings = json.load(f)
        except (OSError, json.JSONDecodeError) as exc:
            return _err(
                f"bridge validate-settings: failed to read {settings_path}: {exc}"
            )

        messages = bridge_permissions_mod.validate_bridge_settings(settings)

        if not messages:
            return _ok({"settings_path": str(settings_path)})

        # Non-empty: exit non-zero with drift detail.
        payload = {
            "status": "drift",
            "messages": messages,
            "settings_path": str(settings_path),
        }
        print(json.dumps(payload))
        return 1

    if args.action == "broker-health":
        import runtime.core.bridge_permissions as bridge_permissions_mod

        try:
            snapshot = bridge_permissions_mod.probe_broker_health(
                braid_root=getattr(args, "braid_root", None),
            )
        except Exception as exc:  # pragma: no cover — probe is fail-closed
            print(
                json.dumps(
                    {
                        "status": "error",
                        "error_detail": (
                            f"{type(exc).__name__}: {exc}"
                        ),
                    }
                )
            )
            return 1
        print(json.dumps(snapshot.to_json_dict()))
        return 0

    if args.action == "topology":
        import runtime.core.lane_topology as lane_topology_mod

        try:
            snapshot = lane_topology_mod.probe_lane_topology(
                braid_root=getattr(args, "braid_root", None),
                state_dir=getattr(args, "state_dir", None),
            )
        except Exception as exc:  # pragma: no cover — probe is fail-closed
            print(
                json.dumps(
                    {
                        "status": "error",
                        "error_detail": (
                            f"{type(exc).__name__}: {exc}"
                        ),
                    }
                )
            )
            return 1
        print(json.dumps(snapshot))
        return 0

    if args.action == "probe-response-drift":
        import runtime.core.bridge_permissions as bridge_permissions_mod

        try:
            diagnostic = bridge_permissions_mod.probe_response_surface_drift(
                run_id=args.run_id,
                braid_root=getattr(args, "braid_root", None),
                state_dir=getattr(args, "state_dir", None),
            )
        except Exception as exc:  # pragma: no cover — probe is fail-closed
            print(
                json.dumps(
                    {
                        "status": "error",
                        "error_detail": (
                            f"{type(exc).__name__}: {exc}"
                        ),
                    }
                )
            )
            return 1
        print(json.dumps(diagnostic.to_json_dict()))
        return 0

    return _err(f"unknown bridge action: {args.action}")


def _handle_constitution(args) -> int:
    """Handle ``cc-policy constitution`` subcommands (read-only registry inspection).

    Actions:

    * ``list``: Emit the full constitution registry contents as JSON —
      concrete paths and planned area slugs with counts.
    * ``validate``: Check that every concrete constitution path exists
      on disk. Exits 0 when healthy, non-zero when any path is missing.

    Both commands are strictly read-only — they do not mutate the
    registry, the filesystem, or the runtime DB.
    """
    from runtime.core import constitution_registry as cr

    if args.action == "list":
        concrete = [
            {"name": e.name, "path": e.path, "rationale": e.rationale}
            for e in cr.concrete_entries()
        ]
        planned = [
            {"name": e.name, "rationale": e.rationale}
            for e in cr.planned_areas()
        ]
        return _ok({
            "concrete_count": len(concrete),
            "planned_count": len(planned),
            "concrete_paths": sorted(cr.CONCRETE_PATHS),
            "planned_areas": [e.name for e in cr.planned_areas()],
            "concrete_entries": concrete,
            "planned_entries": planned,
        })

    if args.action == "validate":
        repo_root = Path(getattr(args, "repo_root", None) or _PROJECT_ROOT)
        missing = []
        for entry in cr.concrete_entries():
            full = repo_root / entry.path  # type: ignore[operator]
            if not full.is_file():
                missing.append(entry.path)

        payload = {
            "concrete_count": len(cr.concrete_entries()),
            "planned_count": len(cr.planned_areas()),
            "missing_concrete_paths": missing,
            "planned_areas": [e.name for e in cr.planned_areas()],
            "healthy": len(missing) == 0,
            "repo_root": str(repo_root),
        }

        if payload["healthy"]:
            return _ok(payload)
        payload["status"] = "unhealthy"
        print(json.dumps(payload))
        return 1

    return _err(f"unknown constitution action: {args.action}")


def _handle_decision(args) -> int:
    """Handle ``cc-policy decision`` subcommands (read-only projection surfaces).

    @decision DEC-CLAUDEX-DECISION-DIGEST-CLI-001
    Title: cc-policy decision digest is the sole CLI surface that renders the decision-digest projection from the canonical runtime registry
    Status: proposed (shadow-mode, Phase 7 Slice 14 — decision-digest CLI read-only surface)
    Rationale: Phase 7 Slice 13 introduced
      ``runtime.core.decision_digest_projection`` as a pure builder that
      turns a sequence of ``DecisionRecord`` instances into a
      ``DecisionDigest`` projection. Slice 14 bridges the canonical
      decision store to the pure builder via a read-only CLI subcommand
      so operators and CI can inspect the digest without hand-editing
      markdown and without writing a digest file. The surface is
      strictly read-only: it opens the runtime DB via a SQLite URI with
      ``mode=ro`` (no directory creation, no WAL, no schema bootstrap),
      lists decisions via
      ``runtime.core.decision_work_registry.list_decisions``, and feeds
      the resulting records through
      ``render_decision_digest`` / ``build_decision_digest_projection``.
      A missing / unwritable DB surfaces as a clean JSON error from
      ``_err()``, never as an unhandled ``sqlite3.OperationalError`` and
      never as a newly-created DB file. No DB writes, no filesystem
      writes, no schema creation, no events, no mutations.

    Imports for the projection builder and decision-work registry are
    function-scoped rather than module-scoped so the module-load graph
    of ``runtime/cli.py`` does not acquire a build-time dependency on
    either authority. This keeps the shadow-only module-level import
    discipline of both authorities intact; AST discipline tests pin the
    module-level invariant explicitly while allowing function-scope use
    inside this handler.

    Actions:

    * ``digest``: Read decisions from the runtime DB (with optional
      ``--status`` / ``--scope`` filters), render the decision-digest
      body via the pure builder, and emit a JSON payload containing the
      rendered body, the structured projection, the metadata envelope,
      the included decision ids, the cutoff epoch, and the filters used.
    * ``digest-check`` (Phase 7 Slice 15): Read decisions from the
      runtime DB with the same filter/read-only semantics, read a
      candidate digest file from ``--candidate-path`` (UTF-8, read-only),
      feed both through the pure validator
      :func:`decision_digest_projection.validate_decision_digest`, and
      emit a JSON payload carrying the stable report shape. Exits ``0``
      when the candidate body matches the projection; exits ``1`` with
      ``status=violation`` when drift is detected so CI and pre-merge
      gates can key off the exit code without re-parsing the body.
    """
    # Function-scope imports intentional — see module docstring and the
    # AST discipline tests in test_decision_digest_projection.py /
    # test_decision_work_registry.py. Both actions share the projection
    # builder / validator + DB registry, so we import once at the
    # handler boundary and share the read-only open helper across
    # branches.
    if args.action not in {"digest", "digest-check", "ingest-commit", "ingest-range", "drift-check"}:
        return _err(f"unknown decision action: {args.action}")

    # ----------------------- ingest-commit --------------------------------
    # Phase 7 Slice 14 — write path: parse commit-message trailers and
    # upsert matching DEC-* ids into the canonical decisions table.
    # (DEC-CLAUDEX-DEC-TRAILER-INGEST-001)
    if args.action == "ingest-commit":
        sha = getattr(args, "sha", None)
        if not sha:
            return _err("decision ingest-commit: --sha is required")

        project_root = getattr(args, "project_root", None) or str(_PROJECT_ROOT)
        dry_run = getattr(args, "dry_run", False)

        # Function-scope import — shadow-only discipline; must not appear
        # at module scope.  The ingest module itself imports
        # decision_work_registry at its own function scope.
        from runtime.core import decision_trailer_ingest as dti

        # Resolve commit message from the git repo.
        try:
            message, author, committed_at = dti.load_commit_message(
                sha, worktree_path=project_root
            )
        except ValueError as exc:
            return _err(f"decision ingest-commit: {exc}")

        if dry_run:
            # Dry-run: parse and report without writing.
            dec_ids = dti.parse_decision_trailers(message)
            payload = {
                "sha": sha,
                "decisions_found": dec_ids,
                "decisions_ingested": 0,
                "rows": [],
                "dry_run": True,
                "status": "ok",
            }
            return _ok(payload)

        # Live ingest: open the DB read-write and call ingest_commit.
        import sqlite3 as _sqlite3

        from runtime.schemas import ensure_schema

        db_path = default_db_path()
        try:
            conn = _sqlite3.connect(str(db_path))
            conn.row_factory = _sqlite3.Row
            ensure_schema(conn)
            rows = dti.ingest_commit(conn, sha, message, author, committed_at)
            conn.close()
        except _sqlite3.Error as exc:
            return _err(
                f"decision ingest-commit: DB error at {db_path}: {exc}"
            )

        payload = {
            "sha": sha,
            "decisions_ingested": len(rows),
            "rows": rows,
            "status": "ok",
        }
        return _ok(payload)

    # ----------------------- ingest-range --------------------------------
    # Phase 7 Slice 15 — batch write path: resolve a git revision range
    # via ``git rev-list``, iterate SHAs oldest→newest, and call the
    # existing ``ingest_commit`` per SHA.  No new upsert_decision call
    # sites — this is a pure orchestrator over ingest_commit.
    # (DEC-CLAUDEX-DEC-INGEST-BACKFILL-001)
    if args.action == "ingest-range":
        range_spec = getattr(args, "range", None)
        if not range_spec:
            return _err("decision ingest-range: --range is required")

        project_root = getattr(args, "project_root", None) or str(_PROJECT_ROOT)
        dry_run = getattr(args, "dry_run", False)

        # Function-scope import — shadow-only discipline; must not appear
        # at module scope.  (DEC-CLAUDEX-DEC-TRAILER-INGEST-001)
        from runtime.core import decision_trailer_ingest as dti

        if dry_run:
            # Dry-run: call ingest_range with dry_run=True — no DB needed.
            try:
                result = dti.ingest_range(
                    None,  # conn is unused in dry-run mode
                    range_spec,
                    worktree_path=project_root,
                    dry_run=True,
                )
            except ValueError as exc:
                return _err(f"decision ingest-range: {exc}")
            return _ok(result)

        # Live ingest: open the DB read-write, ensure schema, call ingest_range.
        import sqlite3 as _sqlite3

        from runtime.schemas import ensure_schema

        db_path = default_db_path()
        try:
            conn = _sqlite3.connect(str(db_path))
            conn.row_factory = _sqlite3.Row
            ensure_schema(conn)
            result = dti.ingest_range(
                conn,
                range_spec,
                worktree_path=project_root,
                dry_run=False,
            )
            conn.close()
        except ValueError as exc:
            return _err(f"decision ingest-range: {exc}")
        except _sqlite3.Error as exc:
            return _err(
                f"decision ingest-range: DB error at {db_path}: {exc}"
            )

        return _ok(result)

    # ----------------------- drift-check --------------------------------
    # Phase 7 Slice 16 — read-only drift detection between commit-trailer
    # evidence (layer 2) and the runtime decision registry (layer 1).
    # Exits 0 when aligned, 1 when drift detected, ≥2 on fatal error.
    # (DEC-CLAUDEX-DEC-DRIFT-CHECK-001)
    if args.action == "drift-check":
        range_spec = getattr(args, "range", None)
        if not range_spec:
            return _err("decision drift-check: --range is required", code=2)

        project_root = getattr(args, "project_root", None) or str(_PROJECT_ROOT)
        exit_on_drift = getattr(args, "exit_on_drift", True)

        # Function-scope import — shadow-only discipline; must not appear
        # at module scope.  (DEC-CLAUDEX-DEC-TRAILER-INGEST-001,
        # DEC-CLAUDEX-DECISION-DIGEST-CLI-001)
        from runtime.core import decision_trailer_ingest as dti

        # Drift-check is read-only: open the DB in read-only mode
        # (mode=ro primary, mode=ro&immutable=1 fallback) so this command
        # can never accidentally write to the decisions table.
        import sqlite3 as _sqlite3

        db_path = default_db_path()

        def _try_open_ro(uri: str):
            connection = _sqlite3.connect(uri, uri=True)
            connection.row_factory = _sqlite3.Row
            return connection

        ro_uri = f"file:{db_path}?mode=ro"
        immutable_uri = f"file:{db_path}?mode=ro&immutable=1"

        try:
            conn_ro = _try_open_ro(ro_uri)
        except _sqlite3.Error:
            try:
                conn_ro = _try_open_ro(immutable_uri)
            except _sqlite3.Error as exc2:
                return _err(
                    f"decision drift-check: failed to read DB at {db_path} "
                    f"read-only: {exc2}",
                    code=2,
                )

        try:
            result = dti.drift_check(conn_ro, range_spec, worktree_path=project_root)
        except ValueError as exc:
            conn_ro.close()
            return _err(f"decision drift-check: {exc}", code=2)
        except _sqlite3.Error as exc:
            conn_ro.close()
            return _err(f"decision drift-check: DB error at {db_path}: {exc}", code=2)
        finally:
            conn_ro.close()

        # Exit-code CI semantics (matches digest-check convention):
        #   0 = aligned=True, status=ok
        #   1 = aligned=False, status=ok (drift detected, valid payload)
        #  ≥2 = status=error (handled above via _err())
        if result.get("aligned"):
            return _ok(result)
        # Drift detected.
        if not exit_on_drift:
            return _ok(result)
        # Exit 1: drift detected and --exit-on-drift (default).
        print(json.dumps(result))
        return 1

    from runtime.core import decision_digest_projection as ddp
    from runtime.core import decision_work_registry as dwr

    # Shared read-only DB open with ``mode=ro`` primary and
    # ``mode=ro&immutable=1`` fallback (see DEC-CLAUDEX-DECISION-DIGEST-CLI-001
    # and Phase 7 Slice 14 correction #2). Both ``digest`` and
    # ``digest-check`` use the exact same read-only open semantics so
    # there is a single authority for how this CLI touches the DB.
    # ``db_read_mode`` is surfaced in the successful payload on both
    # branches so operators can see which path served the request.
    import sqlite3 as _sqlite3

    def _read_decisions_ro(status_filter, scope_filter, *, subcommand):
        """Open the runtime DB read-only and return ``(decisions, db_read_mode)``.

        ``subcommand`` is the CLI subcommand name (``"digest"`` or
        ``"digest-check"``) used only to shape the error message so
        callers see which surface failed. Returns ``None`` and an
        ``_err()``-style JSON error code via the nested helper when
        both open attempts fail.
        """
        db_path = default_db_path()

        def _try_read(uri: str):
            connection = _sqlite3.connect(uri, uri=True)
            try:
                connection.row_factory = _sqlite3.Row
                return dwr.list_decisions(
                    connection,
                    status=status_filter,
                    scope=scope_filter,
                )
            finally:
                connection.close()

        ro_uri = f"file:{db_path}?mode=ro"
        immutable_uri = f"file:{db_path}?mode=ro&immutable=1"

        try:
            return _try_read(ro_uri), "ro", None
        except _sqlite3.Error as exc:
            first_error = exc
            try:
                return _try_read(immutable_uri), "ro_immutable", None
            except _sqlite3.Error as exc2:
                return None, None, (
                    f"decision {subcommand}: failed to read DB at "
                    f"{db_path} read-only; mode=ro: {first_error}; "
                    f"mode=ro+immutable=1: {exc2}"
                )

    # --cutoff-epoch validation (shared). Argparse delivers the raw
    # string so we can emit a JSON error (consistent with _err())
    # rather than argparse's stderr error path.
    subcommand = args.action
    raw_cutoff = getattr(args, "cutoff_epoch", "0")
    try:
        cutoff_epoch = int(raw_cutoff)
    except (TypeError, ValueError):
        return _err(
            f"decision {subcommand}: --cutoff-epoch must be an int; "
            f"got {raw_cutoff!r}"
        )
    if cutoff_epoch < 0:
        return _err(
            f"decision {subcommand}: --cutoff-epoch must be non-negative"
        )

    status_filter = getattr(args, "status", None)
    scope_filter = getattr(args, "scope", None)
    filters = {"status": status_filter, "scope": scope_filter}

    if args.action == "digest":
        # --generated-at validation. Default is the current epoch; the
        # caller may pin an explicit timestamp for deterministic output.
        raw_generated = getattr(args, "generated_at", None)
        if raw_generated is None:
            import time as _time

            generated_at = int(_time.time())
        else:
            try:
                generated_at = int(raw_generated)
            except (TypeError, ValueError):
                return _err(
                    f"decision digest: --generated-at must be an int; "
                    f"got {raw_generated!r}"
                )
            if generated_at < 0:
                return _err(
                    "decision digest: --generated-at must be non-negative"
                )

        decisions, db_read_mode, err = _read_decisions_ro(
            status_filter, scope_filter, subcommand="digest"
        )
        if err is not None:
            return _err(err)

        try:
            rendered_body = ddp.render_decision_digest(
                decisions, cutoff_epoch=cutoff_epoch
            )
            projection = ddp.build_decision_digest_projection(
                decisions,
                generated_at=generated_at,
                cutoff_epoch=cutoff_epoch,
            )
        except ValueError as exc:
            return _err(f"decision digest: {exc}")

        metadata = projection.metadata
        payload = {
            "healthy": True,
            "rendered_body": rendered_body,
            "projection": {
                "decision_ids": list(projection.decision_ids),
                "cutoff_epoch": projection.cutoff_epoch,
                "content_hash": projection.content_hash,
            },
            "metadata": {
                "generator_version": metadata.generator_version,
                "generated_at": metadata.generated_at,
                "stale_condition": {
                    "rationale": metadata.stale_condition.rationale,
                    "watched_authorities": list(
                        metadata.stale_condition.watched_authorities
                    ),
                    "watched_files": list(
                        metadata.stale_condition.watched_files
                    ),
                },
                "source_versions": [
                    [kind, ver] for (kind, ver) in metadata.source_versions
                ],
                "provenance": [
                    {
                        "source_kind": ref.source_kind,
                        "source_id": ref.source_id,
                        "source_version": ref.source_version,
                    }
                    for ref in metadata.provenance
                ],
            },
            "decision_count": len(projection.decision_ids),
            "decision_ids": list(projection.decision_ids),
            "cutoff_epoch": projection.cutoff_epoch,
            "filters": filters,
            "repo_root": str(_PROJECT_ROOT),
            "db_read_mode": db_read_mode,
        }
        return _ok(payload)

    # ----------------------- digest-check -----------------------------
    # Phase 7 Slice 15 — read-only decision-digest body drift validation.
    from pathlib import Path

    candidate_path_str = getattr(args, "candidate_path", None)
    if not candidate_path_str:
        return _err(
            "decision digest-check: --candidate-path is required"
        )
    candidate_path = Path(candidate_path_str).resolve()
    if not candidate_path.is_file():
        return _err(
            f"decision digest-check: candidate not found at {candidate_path}"
        )
    try:
        candidate = candidate_path.read_text(encoding="utf-8")
    except OSError as exc:
        return _err(
            f"decision digest-check: failed to read {candidate_path}: {exc}"
        )

    decisions, db_read_mode, err = _read_decisions_ro(
        status_filter, scope_filter, subcommand="digest-check"
    )
    if err is not None:
        return _err(err)

    try:
        report = ddp.validate_decision_digest(
            candidate, decisions, cutoff_epoch=cutoff_epoch
        )
    except ValueError as exc:
        return _err(f"decision digest-check: {exc}")

    payload = {
        "report": report,
        "candidate_path": str(candidate_path),
        "decision_count": len(report["decision_ids"]),
        "decision_ids": list(report["decision_ids"]),
        "cutoff_epoch": cutoff_epoch,
        "filters": filters,
        "db_read_mode": db_read_mode,
        "repo_root": str(_PROJECT_ROOT),
    }

    if report["healthy"]:
        return _ok(payload)
    # Drift: structured JSON on stdout (CI-friendly) + exit code 1.
    # Matches the convention used by ``cc-policy hook doc-check`` and
    # ``cc-policy shadow parity-invariant``.
    payload["status"] = "violation"
    print(json.dumps(payload))
    return 1


def _handle_prompt_pack(args) -> int:
    """Handle ``cc-policy prompt-pack`` subcommands (read-only prompt-pack tools).

    Actions:

    * ``check`` (DEC-CLAUDEX-PROMPT-PACK-CHECK-CLI-001): reads a
      candidate prompt-pack body from ``--candidate-path`` and
      caller-supplied compiler inputs from ``--inputs-path`` (a
      JSON file with ``workflow_id``, ``stage_id``, ``layers``,
      ``generated_at``, and optional ``manifest_version``), then
      delegates to
      :func:`runtime.core.prompt_pack_validation.validate_prompt_pack`
      and reports drift.

    * ``compile`` (DEC-CLAUDEX-PROMPT-PACK-COMPILE-CLI-001): calls
      the existing single compiler authority
      :func:`runtime.core.prompt_pack.compile_prompt_pack_for_stage`
      in **id mode only** (``--goal-id`` + ``--work-item-id``
      resolved through
      :func:`runtime.core.workflow_contract_capture.capture_workflow_contracts`)
      and prints a JSON payload containing the rendered prompt-pack
      body, the structured :class:`PromptPack` identity fields,
      the content hash, and the projection metadata. ``LookupError``
      and ``ValueError`` from the compiler surface as CLI errors
      with a ``prompt-pack compile:`` prefix — the two error
      classes are left distinguishable via the underlying
      exception message, not collapsed into a single shape.

    * ``subagent-start`` (DEC-CLAUDEX-PROMPT-PACK-SUBAGENT-START-CLI-001):
      thin adapter over
      :func:`runtime.core.prompt_pack.build_subagent_start_prompt_pack_response`.
      Accepts a ``--payload`` JSON string carrying the six
      request-contract fields (``workflow_id``, ``stage_id``,
      ``goal_id``, ``work_item_id``, ``decision_scope``,
      ``generated_at``). On success, prints the helper's report
      shape (``status``, ``healthy``, ``violations``, ``envelope``)
      as JSON to stdout. Invalid payloads return the same structural
      ``invalid`` report from the helper. Compile-path errors
      (``LookupError``/``ValueError``) surface on stderr with a
      ``prompt-pack subagent-start:`` prefix.

    All three actions are strictly read-only — they do not rewrite
    any file, do not write to the runtime DB, do not emit any event,
    and do not execute any prompt-pack consumer. All comparison
    and compile logic lives in the pure library modules; the CLI
    layer only handles argument binding, connection management,
    and payload shaping.
    """
    if args.action == "check":
        from pathlib import Path

        candidate_path = Path(args.candidate_path).resolve()
        inputs_path = Path(args.inputs_path).resolve()

        if not candidate_path.is_file():
            return _err(
                f"prompt-pack check: candidate file not found at {candidate_path}"
            )
        if not inputs_path.is_file():
            return _err(
                f"prompt-pack check: inputs file not found at {inputs_path}"
            )

        try:
            candidate = candidate_path.read_text(encoding="utf-8")
        except OSError as exc:
            return _err(
                f"prompt-pack check: failed to read candidate {candidate_path}: {exc}"
            )

        try:
            with inputs_path.open() as f:
                inputs = json.load(f)
        except (OSError, json.JSONDecodeError) as exc:
            return _err(
                f"prompt-pack check: failed to read inputs {inputs_path}: {exc}"
            )

        # Validate the top-level inputs shape before delegating to
        # the compiler. The validator itself raises ValueError on
        # deep layer / identifier errors; we catch those below.
        if not isinstance(inputs, dict):
            return _err(
                f"prompt-pack check: inputs JSON must be an object; "
                f"got {type(inputs).__name__}"
            )

        workflow_id = inputs.get("workflow_id")
        if not isinstance(workflow_id, str) or not workflow_id:
            return _err(
                "prompt-pack check: inputs.workflow_id must be a non-empty string"
            )

        stage_id = inputs.get("stage_id")
        if not isinstance(stage_id, str) or not stage_id:
            return _err(
                "prompt-pack check: inputs.stage_id must be a non-empty string"
            )

        layers = inputs.get("layers")
        if not isinstance(layers, dict):
            return _err(
                f"prompt-pack check: inputs.layers must be an object; "
                f"got {type(layers).__name__ if layers is not None else 'missing'}"
            )

        generated_at = inputs.get("generated_at")
        # ``bool`` is a subclass of ``int`` in Python — reject it
        # explicitly so ``"generated_at": true`` doesn't slip
        # through as an integer.
        if isinstance(generated_at, bool) or not isinstance(generated_at, int):
            return _err(
                f"prompt-pack check: inputs.generated_at must be an int; "
                f"got {type(generated_at).__name__}"
            )
        if generated_at < 0:
            return _err(
                "prompt-pack check: inputs.generated_at must be non-negative"
            )

        manifest_version = inputs.get("manifest_version")
        if manifest_version is not None and (
            not isinstance(manifest_version, str) or not manifest_version
        ):
            return _err(
                "prompt-pack check: inputs.manifest_version must be a "
                "non-empty string when present"
            )

        kwargs = {
            "workflow_id": workflow_id,
            "stage_id": stage_id,
            "layers": layers,
            "generated_at": generated_at,
        }
        if manifest_version is not None:
            kwargs["manifest_version"] = manifest_version

        try:
            report = prompt_pack_validation_mod.validate_prompt_pack(
                candidate, **kwargs
            )
        except ValueError as exc:
            # The pure validator raises ValueError for deep layer /
            # identifier shape problems. Surface that as a CLI
            # error rather than a drift report, because it means
            # the caller's inputs are malformed, not that the
            # candidate drifted from a valid expected body.
            return _err(f"prompt-pack check: invalid inputs: {exc}")

        payload = {
            "report": report,
            "candidate_path": str(candidate_path),
            "inputs_path": str(inputs_path),
            "repo_root": str(_PROJECT_ROOT),
        }

        # Phase 7 Slice 12 — optional metadata validation gate.
        # @decision DEC-CLAUDEX-PROMPT-PACK-CHECK-CLI-METADATA-001
        # Title: --metadata-path extends check with metadata-drift validation; overall exit is 0 only when both body and metadata healthy
        # Status: proposed (Phase 7 Slice 12)
        # Rationale: Phase 7 Slice 11 made the compiled metadata
        # envelope meaningful by deriving watched_files from the full
        # concrete constitution set. A body-only checker cannot detect
        # a candidate whose body is current while its metadata has
        # been tampered with or left stale. Activating metadata
        # validation requires an explicit operator opt-in via
        # --metadata-path; when active, inputs.watched_files must be
        # present and well-shaped — otherwise the CLI errors rather
        # than silently falling back to the direct-builder default.
        metadata_path_str = getattr(args, "metadata_path", None)
        if metadata_path_str is not None:
            metadata_path = Path(metadata_path_str).resolve()
            if not metadata_path.is_file():
                return _err(
                    f"prompt-pack check: metadata file not found at "
                    f"{metadata_path}"
                )

            try:
                with metadata_path.open() as f:
                    candidate_metadata = json.load(f)
            except (OSError, json.JSONDecodeError) as exc:
                return _err(
                    f"prompt-pack check: failed to read metadata "
                    f"{metadata_path}: {exc}"
                )
            if not isinstance(candidate_metadata, dict):
                return _err(
                    f"prompt-pack check: metadata JSON must be an "
                    f"object; got {type(candidate_metadata).__name__}"
                )

            watched_files_raw = inputs.get("watched_files")
            if watched_files_raw is None:
                return _err(
                    "prompt-pack check: --metadata-path requires "
                    "inputs.watched_files to be present"
                )
            if not isinstance(watched_files_raw, list):
                return _err(
                    f"prompt-pack check: inputs.watched_files must be a "
                    f"list of non-empty strings; got "
                    f"{type(watched_files_raw).__name__}"
                )
            for wf in watched_files_raw:
                if not isinstance(wf, str) or not wf:
                    return _err(
                        "prompt-pack check: inputs.watched_files "
                        "must be a list of non-empty strings"
                    )
            watched_files_tuple = tuple(watched_files_raw)

            metadata_kwargs = {
                "workflow_id": workflow_id,
                "stage_id": stage_id,
                "layers": layers,
                "generated_at": generated_at,
                "watched_files": watched_files_tuple,
            }
            if manifest_version is not None:
                metadata_kwargs["manifest_version"] = manifest_version

            try:
                metadata_report = (
                    prompt_pack_validation_mod.validate_prompt_pack_metadata(
                        candidate_metadata, **metadata_kwargs
                    )
                )
            except ValueError as exc:
                return _err(
                    f"prompt-pack check: invalid metadata inputs: {exc}"
                )

            payload["metadata_report"] = metadata_report
            payload["metadata_path"] = str(metadata_path)

            overall_healthy = bool(report["healthy"]) and bool(
                metadata_report["healthy"]
            )
            if overall_healthy:
                return _ok(payload)
            payload["status"] = "violation"
            print(json.dumps(payload))
            return 1

        if report["healthy"]:
            return _ok(payload)
        payload["status"] = "violation"
        print(json.dumps(payload))
        return 1

    if args.action == "compile":
        # @decision DEC-CLAUDEX-PROMPT-PACK-COMPILE-CLI-001
        # Title: cc-policy prompt-pack compile is the operator-preview surface on top of the single compiler authority
        # Status: proposed (shadow-mode, Phase 2 prompt-pack operator preview)
        # Rationale: The compile helper is already the single
        # compiler authority (DEC-CLAUDEX-PROMPT-PACK-COMPILE-FOR-
        # STAGE-001) and already supports id-mode resolution
        # (DEC-CLAUDEX-PROMPT-PACK-COMPILE-MODE-SELECTION-001).
        # This CLI surface is a thin adapter: it collects argv,
        # opens a runtime connection, calls the helper in id mode,
        # and prints a JSON payload rich enough for an operator to
        # preview the compiled result without re-running the
        # compiler. It does not duplicate any compile logic.
        #
        # Function-scope import deliberately — the module-level
        # CLI import surface continues to forbid any direct
        # ``runtime.core.prompt_pack`` import, so the shadow-only
        # discipline guard can walk only ``tree.body`` (the
        # module-level statements) and still pin that the compiler
        # is not promoted to an always-loaded CLI dependency.
        from runtime.core import prompt_pack as prompt_pack_mod

        workflow_id = args.workflow_id
        stage_id = args.stage_id
        goal_id = args.goal_id
        work_item_id = args.work_item_id
        decision_scope = args.decision_scope
        generated_at = args.generated_at

        if generated_at < 0:
            return _err(
                "prompt-pack compile: --generated-at must be non-negative"
            )

        # When --finding flags are given, pass the explicit tuple.
        # When absent (empty list from argparse default), pass None
        # so the state capture reads live findings from the ledger.
        raw_findings = getattr(args, "finding", None) or []
        findings = tuple(raw_findings) if raw_findings else None
        current_branch = getattr(args, "current_branch", None) or None
        worktree_path = getattr(args, "worktree_path", None) or None
        manifest_version = (
            getattr(args, "manifest_version", None)
            or prompt_pack_mod.MANIFEST_VERSION
        )

        # Function-scope imports of the other shadow-kernel helpers
        # — needed because the CLI also re-renders the body for the
        # operator-preview payload. Putting them next to the
        # ``prompt_pack`` import above keeps the module-load graph
        # unchanged and lets the shadow-discipline guard continue
        # to pin the allowed import surface narrowly.
        from runtime.core import prompt_pack_decisions as _ppd
        from runtime.core import prompt_pack_resolver as _ppr
        from runtime.core import prompt_pack_state as _pps
        from runtime.core import workflow_contract_capture as _wcap

        conn = _get_conn()
        try:
            try:
                pack = prompt_pack_mod.compile_prompt_pack_for_stage(
                    conn,
                    workflow_id=workflow_id,
                    stage_id=stage_id,
                    goal_id=goal_id,
                    work_item_id=work_item_id,
                    decision_scope=decision_scope,
                    generated_at=generated_at,
                    unresolved_findings=findings,
                    current_branch=current_branch,
                    worktree_path=worktree_path,
                    manifest_version=manifest_version,
                )
            except LookupError as exc:
                return _err(f"prompt-pack compile: {exc}")
            except ValueError as exc:
                return _err(f"prompt-pack compile: {exc}")

            # Re-render the prompt-pack body from the same
            # canonical layer resolution so the operator can
            # inspect the exact text the compiled PromptPack
            # represents. ``compile_prompt_pack_for_stage`` stores
            # the hash of this body on the PromptPack; recomputing
            # the layers here is deterministic and deliberately
            # avoids a second compiler authority. If the two ever
            # disagreed that would be a correctness bug in
            # build_prompt_pack, which the test suite already pins.
            goal_contract, work_item_contract = (
                _wcap.capture_workflow_contracts(
                    conn, goal_id=goal_id, work_item_id=work_item_id
                )
            )
            # DEC-CLAUDEX-PROMPT-PACK-SCOPE-AUTHORITY-001: load enforcement-
            # authority scope so the compiled prompt-pack summary derives
            # from the same row policy enforcement consults.
            from runtime.core import workflows as _workflows_scope_mod
            _wf_scope_record = _workflows_scope_mod.get_scope(conn, workflow_id)
            workflow_summary = _ppr.workflow_summary_from_contracts(
                workflow_id=workflow_id,
                goal=goal_contract,
                work_item=work_item_contract,
                workflow_scope_record=_wf_scope_record,
            )
            decision_records = _ppd.capture_relevant_decisions(
                conn, scope=decision_scope
            )
            decision_summary = _ppr.local_decision_summary_from_records(
                decisions=decision_records
            )
            snapshot = _pps.capture_runtime_state_snapshot(
                conn,
                workflow_id=workflow_id,
                unresolved_findings=findings,
                work_item_id=work_item_id,
                current_branch=current_branch,
                worktree_path=worktree_path,
            )
            runtime_state_summary = _ppr.runtime_state_summary_from_snapshot(
                snapshot=snapshot
            )
            layers = _ppr.resolve_prompt_pack_layers(
                stage=stage_id,
                workflow_summary=workflow_summary,
                decision_summary=decision_summary,
                runtime_state_summary=runtime_state_summary,
            )
            rendered_body = prompt_pack_mod.render_prompt_pack(
                workflow_id=workflow_id,
                stage_id=stage_id,
                layers=layers,
            )
        finally:
            conn.close()

        # Structured operator-preview payload. Mirrors the shape
        # ``prompt_pack_validation`` callers already expect for
        # PromptPack fields, plus the rendered body and the
        # decoded metadata.
        #
        # @decision DEC-CLAUDEX-PROMPT-PACK-METADATA-SERIALISER-SINGLE-AUTHORITY-001
        # Title: CLI compile routes metadata shape through the public prompt_pack_validation.serialise_prompt_pack_metadata helper
        # Status: proposed (Phase 7 Slice 12 correction)
        # Rationale: Slice 12 introduced the rebuild-via-compiler
        # metadata validator whose expected output is shaped by
        # ``serialise_prompt_pack_metadata``. If this CLI path also
        # constructed the metadata dict inline, there would be two
        # authorities for the on-wire metadata shape and a later
        # field addition in one place would silently drift from the
        # other. Calling the public helper makes the serialiser the
        # single authority for the JSON shape of
        # ``pack.metadata`` — the CLI emits exactly what the
        # validator rebuilds.
        payload = {
            "workflow_id": pack.workflow_id,
            "stage_id": pack.stage_id,
            "layer_names": list(pack.layer_names),
            "content_hash": pack.content_hash,
            "rendered_body": rendered_body,
            "metadata": prompt_pack_validation_mod.serialise_prompt_pack_metadata(
                pack.metadata
            ),
            "inputs": {
                "goal_id": goal_id,
                "work_item_id": work_item_id,
                "decision_scope": decision_scope,
                "unresolved_findings": list(findings) if findings is not None else None,
                "current_branch": current_branch,
                "worktree_path": worktree_path,
                "manifest_version": manifest_version,
            },
            # Phase 7 Slice 2: derived revalidation contract. Writing
            # ``rendered_body`` and ``validation_inputs`` to files and
            # invoking ``cc-policy prompt-pack check`` must produce
            # exit 0 with ``healthy=True`` and matching hash. This
            # closes the derived-surface freshness gap: a compiled
            # artifact can be revalidated from the compile output
            # alone without the caller reconstructing layers.
            #
            # Phase 7 Slice 12: extended ``validation_inputs`` with
            # ``watched_files`` so metadata-path revalidation (the new
            # ``prompt-pack check --metadata-path`` mode) can rebuild
            # the expected ``stale_condition.watched_files`` tuple
            # without the caller reconstructing the full concrete
            # constitution set. The value is sourced from
            # ``pack.metadata.stale_condition.watched_files`` in
            # deterministic order — the same authority the compile
            # path already derived from
            # ``prompt_pack_resolver.constitution_watched_files()``.
            "validation_inputs": {
                "workflow_id": workflow_id,
                "stage_id": stage_id,
                "layers": {k: v for k, v in layers.items()},
                "generated_at": generated_at,
                "manifest_version": manifest_version,
                "watched_files": list(
                    pack.metadata.stale_condition.watched_files
                ),
            },
        }
        return _ok(payload)

    if args.action == "subagent-start":
        # @decision DEC-CLAUDEX-PROMPT-PACK-SUBAGENT-START-CLI-001
        # Title: subagent-start CLI is a thin adapter over build_subagent_start_prompt_pack_response
        # Status: proposed (Phase 2 hook-adapter reduction)
        # Rationale: Function-scope import keeps the module-level import surface clean.
        # The helper owns all validation and compilation logic; the CLI only handles
        # argparse binding, JSON decode, connection management, and exit-code shaping.
        from runtime.core import prompt_pack as prompt_pack_mod

        try:
            payload = json.loads(args.payload)
        except json.JSONDecodeError as exc:
            return _err(f"prompt-pack subagent-start: payload is not valid JSON: {exc}")

        conn = _get_conn()
        try:
            try:
                report = prompt_pack_mod.build_subagent_start_prompt_pack_response(conn, payload)
            except (LookupError, ValueError) as exc:
                return _err(f"prompt-pack subagent-start: {exc}")
        finally:
            conn.close()

        if report["healthy"]:
            return _ok(report)
        print(json.dumps(report))
        return 1

    return _err(f"unknown prompt-pack action: {args.action}")


def _handle_shadow(args) -> int:
    """Handle ``cc-policy shadow`` subcommands (read-only shadow observer tools).

    DEC-CLAUDEX-SHADOW-PARITY-001: the actions here are strictly read-only —
    no emits, no writes, no migrations. Two actions are supported:

    * ``parity-report`` — aggregate recent ``shadow_stage_decision`` events
      into a JSON summary by reason code. Always exits 0.
    * ``parity-invariant`` — same aggregation, but exits non-zero when the
      report shows any ``has_unspecified_divergence`` or ``has_unknown_reason``
      condition. Output format includes the full report plus a structured
      ``invariant`` dict with ``healthy``, ``violations``, and ``details``
      fields so CI consumers can render the failure without re-parsing.
    """
    conn = _get_conn()
    try:
        if args.action == "parity-report":
            rows = events_mod.query(
                conn,
                type="shadow_stage_decision",
                source=getattr(args, "source", None),
                since=getattr(args, "since", None),
                limit=getattr(args, "limit", 200),
            )
            report = shadow_parity_mod.summarize(rows)
            return _ok({"report": report})

        if args.action == "parity-invariant":
            rows = events_mod.query(
                conn,
                type="shadow_stage_decision",
                source=getattr(args, "source", None),
                since=getattr(args, "since", None),
                limit=getattr(args, "limit", 200),
            )
            report = shadow_parity_mod.summarize(rows)
            invariant = shadow_parity_mod.check_invariants(report)
            payload = {
                "report": report,
                "invariant": invariant,
            }
            if invariant["healthy"]:
                return _ok(payload)
            # Unhealthy: print structured JSON to stdout (CI-friendly) and
            # return non-zero. This is a deliberate departure from _err(),
            # which writes to stderr — the full report is useful either way
            # and consumers should always be able to parse stdout.
            payload["status"] = "violation"
            print(json.dumps(payload))
            return 1
    finally:
        conn.close()
    return _err(f"unknown shadow action: {args.action}")


def _provision_worktree(
    conn,
    workflow_id: str,
    feature_name: str,
    project_root: str,
    base_branch: str = "main",
) -> dict:
    """Core provision logic: filesystem-first, then DB writes, with partial-failure cleanup.

    Provision sequence (DEC-GUARD-WT-008 R3, DEC-GUARD-WT-002):
      0. If the base repo is unborn (no HEAD yet), create a one-time bootstrap
         commit in the project root so git worktree add has a valid base commit.
      1. Compute worktree_path and branch from project_root + feature_name.
      2. Filesystem check: does the path already exist? → already_exists path.
      3. git worktree add (subprocess) — filesystem is created BEFORE any DB write.
         If this fails, return error immediately (nothing to clean up).
      4. worktrees.register(path, branch) — ON CONFLICT is the sole concurrency guard.
      5. leases.issue() for Guardian at PROJECT_ROOT (DEC-GUARD-WT-006 R3).
      6. leases.issue() for implementer at worktree_path.
      7. workflows.bind_workflow() — workflow binding at provision time (DEC-GUARD-WT-004).

    Partial-failure cleanup (DEC-GUARD-WT-008 R3):
      If step 4 succeeds but steps 5-7 fail, call worktrees.remove() to roll back
      the registration, then `git worktree remove` to remove the filesystem path.
      If step 3 succeeds but step 4 fails, only `git worktree remove` is needed.

    Re-provision (already_exists=True):
      Filesystem path exists → skip git worktree add, ensure DB state is correct.
      Active implementer lease is NOT revoked on re-provision (spec requirement).

    @decision DEC-GUARD-WT-002
    Title: Worktree provisioning is a runtime function, not a dispatch_engine side effect
    Status: accepted
    Rationale: This function is the ONE place in the runtime that runs git commands
      via subprocess. dispatch_engine remains pure (no git, no lease writes). The
      Guardian agent calls `cc-policy worktree provision` which delegates here.
      The filesystem-first order (DEC-GUARD-WT-008 R3) prevents DB state from
      accumulating when git fails. ON CONFLICT in register() is the sole concurrency
      guard — no list_active() pre-check to avoid TOCTOU races.

    @decision DEC-GUARD-WT-008
    Title: Provision-if-absent idempotency — filesystem-first, no TOCTOU pre-check
    Status: accepted
    Rationale: Filesystem check (os.path.exists) determines already-exists, not a
      DB pre-check. This eliminates the TOCTOU window where two concurrent provisions
      both see the DB as empty and race. The filesystem is the ground truth.

    @decision DEC-GUARD-WT-006
    Title: Guardian provisioning lease issued by provision CLI (R3)
    Status: accepted
    Rationale: check-guardian.sh uses lease_context(PROJECT_ROOT) to find the active
      lease for completion record submission. The Guardian lease must be at PROJECT_ROOT,
      not at the worktree path. This function issues it here so check-guardian.sh can
      find it after the guardian agent runs `cc-policy worktree provision`.

    @decision DEC-GUARD-WT-009
    Title: worktree provision may initialize an unborn base repo before branching
    Status: accepted
    Rationale: A fresh repo's first commit is not a reviewed landing and cannot
      belong to `guardian:land`; yet `git worktree add` refuses to branch from an
      unborn repo with no HEAD. The runtime provision authority owns the narrow,
      one-time repair: when project_root has no HEAD, it materializes a bootstrap
      commit directly via subprocess before any worktree branch is created. This
      does NOT widen the shell-level `can_land_git` capability and only applies
      while the repo is unborn.
    """
    import os as _os
    import subprocess as _subprocess

    from runtime.core.policy_utils import normalize_path

    def _run_git_checked(*git_args: str) -> str:
        result = _subprocess.run(
            ["git", "-C", project_root, *git_args],
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            stderr = result.stderr.strip() or result.stdout.strip() or "git command failed"
            raise RuntimeError(f"`git {' '.join(git_args)}` failed: {stderr}")
        return result.stdout.strip()

    def _repo_has_head() -> bool:
        result = _subprocess.run(
            ["git", "-C", project_root, "rev-parse", "--verify", "HEAD"],
            capture_output=True,
            text=True,
        )
        return result.returncode == 0

    def _bootstrap_commit_candidates() -> list[str]:
        result = _subprocess.run(
            [
                "git",
                "-C",
                project_root,
                "ls-files",
                "--cached",
                "--modified",
                "--deleted",
                "--others",
                "--exclude-standard",
                "-z",
            ],
            capture_output=True,
            check=False,
        )
        if result.returncode != 0:
            return []
        candidates: list[str] = []
        seen: set[str] = set()
        for raw in result.stdout.decode("utf-8", errors="replace").split("\x00"):
            path = raw.strip()
            if not path:
                continue
            if path == ".claude" or path.startswith(".claude/"):
                continue
            if path == ".worktrees" or path.startswith(".worktrees/"):
                continue
            if path == "tmp" or path.startswith("tmp/"):
                continue
            if path in seen:
                continue
            seen.add(path)
            candidates.append(path)
        return candidates

    def _initialize_unborn_repo() -> dict:
        branch_name = _run_git_checked("symbolic-ref", "--short", "HEAD")
        commit_message = f"chore: initialize repository for workflow {workflow_id}"
        candidates = _bootstrap_commit_candidates()
        if candidates:
            add_cmd = ["git", "-C", project_root, "add", "--all", "--", *candidates]
            add_result = _subprocess.run(add_cmd, capture_output=True, text=True)
            if add_result.returncode != 0:
                stderr = (
                    add_result.stderr.strip()
                    or add_result.stdout.strip()
                    or "git add failed"
                )
                raise RuntimeError(f"bootstrap initialization add failed: {stderr}")
        commit_args = ["git", "-C", project_root, "commit", "--allow-empty", "-m", commit_message]
        commit_result = _subprocess.run(commit_args, capture_output=True, text=True)
        if commit_result.returncode != 0:
            stderr = (
                commit_result.stderr.strip()
                or commit_result.stdout.strip()
                or "git commit failed"
            )
            raise RuntimeError(f"bootstrap initialization commit failed: {stderr}")
        commit_sha = _run_git_checked("rev-parse", "HEAD")
        events_mod.emit(
            conn,
            "workflow.bootstrap.repo_initialized",
            source=f"workflow:{workflow_id}",
            detail=json.dumps(
                {
                    "workflow_id": workflow_id,
                    "project_root": project_root,
                    "branch": branch_name,
                    "commit_sha": commit_sha,
                    "commit_message": commit_message,
                    "path_count": len(candidates),
                },
                sort_keys=True,
            ),
        )
        return {
            "repo_initialized": True,
            "bootstrap_commit_sha": commit_sha,
            "bootstrap_commit_message": commit_message,
            "bootstrap_commit_path_count": len(candidates),
        }

    project_root = normalize_path(project_root)
    branch = f"feature/{feature_name}"
    worktree_path = _os.path.join(project_root, ".worktrees", f"feature-{feature_name}")
    repo_init = {
        "repo_initialized": False,
        "bootstrap_commit_sha": None,
        "bootstrap_commit_message": None,
        "bootstrap_commit_path_count": 0,
    }

    if not _repo_has_head():
        repo_init = _initialize_unborn_repo()

    # --- Step 1: Filesystem check (DEC-GUARD-WT-008 R3) ---
    already_exists = _os.path.exists(worktree_path)

    git_created = False
    if not already_exists:
        # --- Step 2: git worktree add (filesystem-first, before any DB write) ---
        r = _subprocess.run(
            [
                "git",
                "-C",
                project_root,
                "worktree",
                "add",
                f".worktrees/feature-{feature_name}",
                "-b",
                branch,
            ],
            capture_output=True,
            text=True,
        )
        if r.returncode != 0:
            raise RuntimeError(f"git worktree add failed (exit {r.returncode}): {r.stderr.strip()}")
        git_created = True

    # --- Steps 3-6: DB writes (with partial-failure cleanup) ---
    register_done = False
    try:
        # Step 3: Register worktree (ON CONFLICT is the sole concurrency guard)
        worktrees_mod.register(conn, path=worktree_path, branch=branch, ticket=workflow_id)
        register_done = True

        # Step 4: Guardian lease at PROJECT_ROOT (DEC-GUARD-WT-006 R3)
        # Revokes any prior Guardian lease at project_root (one-active-per-worktree).
        g_lease = leases_mod.issue(
            conn,
            role="guardian",
            worktree_path=project_root,
            workflow_id=workflow_id,
            branch=branch,
            requires_eval=False,  # Guardian provisioning does not require eval
        )

        # Step 5: Implementer lease at worktree_path.
        # On re-provision: check if an active implementer lease already exists.
        # If so, reuse it (do NOT revoke — spec requirement).
        if already_exists:
            existing_impl = leases_mod.get_current(conn, worktree_path=worktree_path)
            if existing_impl is not None and existing_impl["role"] == "implementer":
                i_lease = existing_impl
            else:
                i_lease = leases_mod.issue(
                    conn,
                    role="implementer",
                    worktree_path=worktree_path,
                    workflow_id=workflow_id,
                    branch=branch,
                )
        else:
            i_lease = leases_mod.issue(
                conn,
                role="implementer",
                worktree_path=worktree_path,
                workflow_id=workflow_id,
                branch=branch,
            )

        # Step 6: Workflow binding (DEC-GUARD-WT-004 revised)
        workflows_mod.bind_workflow(
            conn,
            workflow_id=workflow_id,
            worktree_path=worktree_path,
            branch=branch,
            base_branch=base_branch,
        )

    except Exception:
        # Partial-failure cleanup (DEC-GUARD-WT-008 R3):
        # Roll back register() if it succeeded, then remove the git worktree.
        if register_done:
            try:
                worktrees_mod.remove(conn, worktree_path)
            except Exception:
                pass  # Best-effort; cleanup failure does not mask original error
        if git_created:
            try:
                _subprocess.run(
                    ["git", "-C", project_root, "worktree", "remove", worktree_path],
                    capture_output=True,
                    check=False,
                )
            except Exception:
                pass  # Best-effort cleanup
        raise

    return {
        "worktree_path": worktree_path,
        "branch": branch,
        "guardian_lease_id": g_lease["lease_id"],
        "implementer_lease_id": i_lease["lease_id"],
        "workflow_id": workflow_id,
        "already_exists": already_exists,
        **repo_init,
    }


def _handle_worktree(args) -> int:
    worktree_db_root = None
    if args.action == "provision":
        worktree_db_root = getattr(args, "project_root", None) or None
    conn = _get_conn(project_root=worktree_db_root)
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

        elif args.action == "provision":
            import os as _os

            # Resolve project_root from args or CLAUDE_PROJECT_DIR env var
            project_root = getattr(args, "project_root", None) or ""
            if not project_root:
                project_root = _os.environ.get("CLAUDE_PROJECT_DIR", "")
            if not project_root:
                return _err(
                    "worktree provision: --project-root is required (or set CLAUDE_PROJECT_DIR)"
                )

            workflow_id = getattr(args, "workflow_id", None) or ""
            if not workflow_id:
                return _err("worktree provision: --workflow-id is required")

            feature_name = getattr(args, "feature_name", None) or ""
            if not feature_name:
                return _err("worktree provision: --feature-name is required")

            base_branch = getattr(args, "base_branch", "main") or "main"

            try:
                result = _provision_worktree(
                    conn,
                    workflow_id=workflow_id,
                    feature_name=feature_name,
                    project_root=project_root,
                    base_branch=base_branch,
                )
            except Exception as exc:
                return _err(f"worktree provision failed: {exc}")

            return _ok(result)

    finally:
        conn.close()
    return _err(f"unknown worktree action: {args.action}")


def _handle_dispatch(args) -> int:
    conn = _get_conn()
    try:
        if args.action == "process-stop":
            # Read JSON from stdin: {"agent_type": "reviewer", "project_root": "/path"}
            import json as _json

            raw = sys.stdin.read()
            if not raw or not raw.strip():
                return _err("dispatch process-stop: empty input")
            try:
                payload = _json.loads(raw)
            except _json.JSONDecodeError as e:
                return _err(f"dispatch process-stop: invalid JSON: {e}")

            agent_type = payload.get("agent_type", "")
            project_root = payload.get("project_root", "")

            if not agent_type:
                return _err("dispatch process-stop: agent_type is required")

            result = dispatch_engine_mod.process_agent_stop(conn, agent_type, project_root)

            # Build hookSpecificOutput — same contract as PE-W2/W3.
            suggestion = result.get("suggestion", "")
            if suggestion:
                hook_output = {"hookEventName": "SubagentStop", "additionalContext": suggestion}
            else:
                hook_output = {"hookEventName": "SubagentStop"}

            return _ok(
                {
                    "next_role": result["next_role"],
                    "workflow_id": result["workflow_id"],
                    "auto_dispatch": result.get("auto_dispatch", False),
                    # W-GWT-1 (DEC-GUARD-WT-003, DEC-GUARD-WT-007): pass through
                    # worktree_path and guardian_mode so callers (post-task.sh,
                    # orchestrator) can read them from the structured result without
                    # parsing the suggestion text. The suggestion text remains the
                    # primary carrier to the orchestrator via additionalContext.
                    "worktree_path": result.get("worktree_path", ""),
                    "guardian_mode": result.get("guardian_mode", ""),
                    "critic_found": result.get("critic_found", False),
                    "critic_verdict": result.get("critic_verdict", ""),
                    "critic_provider": result.get("critic_provider", ""),
                    "critic_summary": result.get("critic_summary", ""),
                    "critic_detail": result.get("critic_detail", ""),
                    "critic_try_again_streak": result.get("critic_try_again_streak", 0),
                    "critic_retry_limit": result.get("critic_retry_limit", 0),
                    "critic_repeated_fingerprint_streak": result.get(
                        "critic_repeated_fingerprint_streak", 0
                    ),
                    "critic_escalated": result.get("critic_escalated", False),
                    "critic_escalation_reason": result.get("critic_escalation_reason", ""),
                    "error": result["error"],
                    "hookSpecificOutput": hook_output,
                }
            )

        elif args.action == "agent-start":
            # W-CONV-2: forward project_root and workflow_id so the marker is
            # scoped to this project. Both are optional — callers that do not
            # supply them get NULL columns and unscoped get_active() still works.
            #
            # A22 hardening (symmetric with A21 `marker set`): when
            # --project-root is omitted, resolve through the canonical CLI
            # resolver `_resolve_project_root(args)` (args → CLAUDE_PROJECT_DIR
            # → git toplevel → normalize_path) so normal repo sessions no
            # longer persist agent_markers.project_root = NULL via this
            # dispatch path. If resolution still returns empty, preserve the
            # legacy unscoped write (project_root=None) — matching A21.
            from runtime.core.policy_utils import normalize_path as _norm_path

            _pr = getattr(args, "project_root", None) or ""
            if not _pr:
                _pr = _resolve_project_root(args)
            _wf = getattr(args, "workflow_id", None) or ""
            lifecycle_mod.on_agent_start(
                conn,
                args.agent_type,
                args.agent_id,
                project_root=_norm_path(_pr) if _pr else None,
                workflow_id=_wf if _wf else None,
            )
            return _ok({"agent_id": args.agent_id, "agent_type": args.agent_type})

        elif args.action == "agent-stop":
            lifecycle_mod.on_agent_stop(conn, args.agent_type, args.agent_id)
            return _ok({"agent_id": args.agent_id, "agent_type": args.agent_type})

        elif args.action == "agent-prompt":
            # DEC-CLAUDEX-AGENT-PROMPT-001: runtime-owned Agent dispatch prompt producer.
            # Resolves six contract fields from runtime state and returns a
            # prompt_prefix containing the CLAUDEX_CONTRACT_BLOCK: line on line 1.
            from runtime.core.agent_prompt import build_agent_dispatch_prompt as _build_ap

            try:
                result = _build_ap(
                    conn,
                    workflow_id=args.workflow_id,
                    stage_id=args.stage_id,
                    goal_id=getattr(args, "goal_id", None),
                    work_item_id=getattr(args, "work_item_id", None),
                    decision_scope=getattr(args, "decision_scope", "kernel"),
                    generated_at=getattr(args, "generated_at", None),
                )
            except ValueError as exc:
                return _err(f"dispatch agent-prompt: {exc}")
            return _ok(result)

        elif args.action == "attempt-issue":
            # @decision DEC-CLAUDEX-HOOK-WIRING-001
            # Title: attempt-issue CLI wires PreToolUse:Agent to dispatch_attempts.issue
            # Status: accepted
            # Rationale: pre-agent.sh calls this at PreToolUse:Agent time when a
            #   CLAUDEX_CONTRACT_BLOCK is present.  dispatch_hook.record_agent_dispatch()
            #   upserts agent_sessions + seats and issues a pending attempt in one call.
            from runtime.core.dispatch_hook import record_agent_dispatch as _ra_dispatch

            try:
                result = _ra_dispatch(
                    conn,
                    args.session_id,
                    args.agent_type,
                    args.instruction or "",
                    workflow_id=args.workflow_id or None,
                    timeout_at=args.timeout_at or None,
                )
            except (ValueError, Exception) as exc:
                return _err(f"dispatch attempt-issue: {exc}")
            return _ok(result)

        elif args.action == "attempt-claim":
            # @decision DEC-CLAUDEX-HOOK-WIRING-001
            # Title: attempt-claim CLI wires SubagentStart to dispatch_attempts.claim
            # Status: accepted
            # Rationale: subagent-start.sh calls this after consuming the carrier row.
            #   dispatch_hook.record_subagent_delivery() finds the most recent pending
            #   attempt for the seat and advances it to 'delivered'.  Returns
            #   {"found": false} when no pending attempt exists (best-effort no-op).
            from runtime.core.dispatch_hook import record_subagent_delivery as _ra_delivery

            try:
                result = _ra_delivery(conn, args.session_id, args.agent_type)
            except (ValueError, Exception) as exc:
                return _err(f"dispatch attempt-claim: {exc}")
            if result is None:
                return _ok({"found": False, "attempt": None})
            return _ok({"found": True, "attempt": result})

        elif args.action == "sweep-dead":
            # @decision DEC-DEAD-RECOVERY-001
            from runtime.core import dead_recovery as _dr

            kwargs: dict = {}
            if getattr(args, "grace_seconds", None) is not None:
                kwargs["grace_seconds"] = int(args.grace_seconds)
            try:
                result = _dr.sweep_all(conn, **kwargs)
            except ValueError as exc:
                return _err(f"dispatch sweep-dead: {exc}")
            return _ok(result)

        elif args.action == "seat-release":
            # Runtime-owned seat teardown (DEC-SUPERVISION-THREADS-DOMAIN-001
            # continuation).  Releases the seat and abandons every active
            # supervision_thread touching it in one transaction per action.
            from runtime.core.dispatch_hook import release_session_seat as _release

            try:
                result = _release(conn, args.session_id, args.agent_type)
            except Exception as exc:
                return _err(f"dispatch seat-release: {exc}")
            return _ok(result)

        elif args.action == "attempt-expire-stale":
            # Sweep pending/delivered attempts whose timeout_at has elapsed.
            # Called by scripts/claudex-watchdog.sh on every tick so timed-out
            # attempts are cleaned up without a manual caller.
            # Returns {"expired": N} — N=0 is normal when nothing is stale.
            from runtime.core.dispatch_attempts import expire_stale as _expire_stale

            try:
                n = _expire_stale(
                    conn,
                    fallback_pending_max_age_seconds=(
                        args.fallback_pending_max_age_seconds
                        if getattr(args, "fallback_pending_max_age_seconds", 0) > 0
                        else None
                    ),
                )
            except Exception as exc:
                return _err(f"dispatch attempt-expire-stale: {exc}")
            return _ok({"expired": n})

    finally:
        conn.close()
    return _err(f"unknown dispatch action: {args.action}")


def _handle_agent_session(args) -> int:
    """Handler for `cc-policy agent-session` subcommands.

    Thin adapter over ``runtime.core.agent_sessions``
    (DEC-AGENT-SESSION-DOMAIN-001).  No agent_sessions state is read or
    written outside of that domain module.  Session creation is
    intentionally absent — sessions are bootstrapped exclusively
    through ``dispatch_hook.ensure_session_and_seat``.
    """
    from runtime.core import agent_sessions as as_mod

    conn = _get_conn()
    try:
        if args.action == "get":
            try:
                row = as_mod.get(conn, args.session_id)
            except ValueError as exc:
                return _err(f"agent-session get: {exc}")
            return _ok({"session": row})

        if args.action == "mark-completed":
            try:
                result = as_mod.mark_completed(conn, args.session_id)
            except ValueError as exc:
                return _err(f"agent-session mark-completed: {exc}")
            return _ok(
                {
                    "session": result["row"],
                    "transitioned": result["transitioned"],
                }
            )

        if args.action == "mark-dead":
            try:
                result = as_mod.mark_dead(conn, args.session_id)
            except ValueError as exc:
                return _err(f"agent-session mark-dead: {exc}")
            return _ok(
                {
                    "session": result["row"],
                    "transitioned": result["transitioned"],
                }
            )

        if args.action == "mark-orphaned":
            try:
                result = as_mod.mark_orphaned(conn, args.session_id)
            except ValueError as exc:
                return _err(f"agent-session mark-orphaned: {exc}")
            return _ok(
                {
                    "session": result["row"],
                    "transitioned": result["transitioned"],
                }
            )

        if args.action == "list-active":
            rows = as_mod.list_active(conn, workflow_id=args.workflow_id)
            return _ok({"sessions": rows})

    finally:
        conn.close()
    return _err(f"unknown agent-session action: {args.action}")


def _handle_seat(args) -> int:
    """Handler for `cc-policy seat` subcommands.

    Thin adapter over ``runtime.core.seats`` (DEC-SEAT-DOMAIN-001).
    No seat state is read or written outside of that domain module.
    Seat creation is intentionally absent — seats are bootstrapped
    exclusively through ``dispatch_hook.ensure_session_and_seat``.
    """
    from runtime.core import seats as seat_mod

    conn = _get_conn()
    try:
        if args.action == "get":
            try:
                row = seat_mod.get(conn, args.seat_id)
            except ValueError as exc:
                return _err(f"seat get: {exc}")
            return _ok({"seat": row})

        if args.action == "release":
            try:
                result = seat_mod.release(conn, args.seat_id)
            except ValueError as exc:
                return _err(f"seat release: {exc}")
            return _ok(
                {"seat": result["row"], "transitioned": result["transitioned"]}
            )

        if args.action == "mark-dead":
            try:
                result = seat_mod.mark_dead(conn, args.seat_id)
            except ValueError as exc:
                return _err(f"seat mark-dead: {exc}")
            return _ok(
                {"seat": result["row"], "transitioned": result["transitioned"]}
            )

        if args.action == "list-for-session":
            try:
                rows = seat_mod.list_for_session(
                    conn, args.session_id, status=args.status
                )
            except ValueError as exc:
                return _err(f"seat list-for-session: {exc}")
            return _ok({"seats": rows})

        if args.action == "list-active":
            rows = seat_mod.list_active(conn)
            return _ok({"seats": rows})

    finally:
        conn.close()
    return _err(f"unknown seat action: {args.action}")


def _handle_supervision(args) -> int:
    """Handler for `cc-policy supervision` subcommands.

    Delegates every action to ``runtime.core.supervision_threads``
    (DEC-SUPERVISION-THREADS-DOMAIN-001). No supervision-thread state is
    read or written outside of that domain module.
    """
    from runtime.core import supervision_threads as sup_mod

    conn = _get_conn()
    try:
        if args.action == "attach":
            try:
                row = sup_mod.attach(
                    conn,
                    args.supervisor_seat_id,
                    args.worker_seat_id,
                    args.thread_type,
                )
            except ValueError as exc:
                return _err(f"supervision attach: {exc}")
            return _ok({"thread": row})

        if args.action == "detach":
            try:
                row = sup_mod.detach(conn, args.thread_id)
            except ValueError as exc:
                return _err(f"supervision detach: {exc}")
            return _ok({"thread": row})

        if args.action == "abandon":
            try:
                row = sup_mod.abandon(conn, args.thread_id)
            except ValueError as exc:
                return _err(f"supervision abandon: {exc}")
            return _ok({"thread": row})

        if args.action == "get":
            try:
                row = sup_mod.get(conn, args.thread_id)
            except ValueError as exc:
                return _err(f"supervision get: {exc}")
            return _ok({"thread": row})

        if args.action == "list-for-supervisor":
            try:
                rows = sup_mod.list_for_supervisor(
                    conn,
                    args.supervisor_seat_id,
                    status=args.status,
                )
            except ValueError as exc:
                return _err(f"supervision list-for-supervisor: {exc}")
            return _ok({"threads": rows})

        if args.action == "list-for-worker":
            try:
                rows = sup_mod.list_for_worker(
                    conn,
                    args.worker_seat_id,
                    status=args.status,
                )
            except ValueError as exc:
                return _err(f"supervision list-for-worker: {exc}")
            return _ok({"threads": rows})

        if args.action == "list-for-session":
            try:
                rows = sup_mod.list_for_session(
                    conn,
                    args.agent_session_id,
                    status=args.status,
                )
            except ValueError as exc:
                return _err(f"supervision list-for-session: {exc}")
            return _ok({"threads": rows})

        if args.action == "list-for-seat":
            try:
                rows = sup_mod.list_for_seat(
                    conn,
                    args.seat_id,
                    status=args.status,
                )
            except ValueError as exc:
                return _err(f"supervision list-for-seat: {exc}")
            return _ok({"threads": rows})

        if args.action == "abandon-for-seat":
            try:
                count = sup_mod.abandon_for_seat(conn, args.seat_id)
            except ValueError as exc:
                return _err(f"supervision abandon-for-seat: {exc}")
            return _ok({"abandoned": count})

        if args.action == "abandon-for-session":
            try:
                count = sup_mod.abandon_for_session(conn, args.agent_session_id)
            except ValueError as exc:
                return _err(f"supervision abandon-for-session: {exc}")
            return _ok({"abandoned": count})

        if args.action == "list-active":
            rows = sup_mod.list_active(conn)
            return _ok({"threads": rows})

    finally:
        conn.close()
    return _err(f"unknown supervision action: {args.action}")


def _handle_lifecycle(args) -> int:
    """Handler for `cc-policy lifecycle` subcommands.

    Currently exposes one action: on-stop, which resolves the active marker
    by role and deactivates it. This is the single Python authority for marker
    deactivation in SubagentStop hooks (DEC-LIFECYCLE-003).
    """
    conn = _get_conn()
    try:
        if args.action == "on-stop":
            # ENFORCE-RCA-6-ext/#26: pass scoping through so deactivation
            # targets the caller's own active marker, not the globally newest.
            from runtime.core.policy_utils import normalize_path as _norm_path

            _pr = getattr(args, "project_root", None)
            _wf = getattr(args, "workflow_id", None)
            result = lifecycle_mod.on_stop_by_role(
                conn,
                args.agent_type,
                project_root=_norm_path(_pr) if _pr else None,
                workflow_id=_wf if _wf else None,
            )
            return _ok(result)
    finally:
        conn.close()
    return _err(f"unknown lifecycle action: {args.action}")


def _handle_statusline(args) -> int:
    conn = _get_conn()
    try:
        if args.action == "snapshot":
            snap = statusline_mod.snapshot(conn)
            return _ok(snap)
        if args.action == "hygiene":
            from runtime.core.checkout_hygiene import classify_checkout_hygiene

            result = classify_checkout_hygiene(
                conn,
                worktree_path=args.worktree_path,
            )
            return _ok(result)
    finally:
        conn.close()
    return _err(f"unknown statusline action: {args.action}")


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
    if args.action == "bootstrap-request":
        try:
            result = workflow_bootstrap_mod.request_local_workflow_bootstrap(
                workflow_id=args.workflow_id,
                desired_end_state=args.desired_end_state,
                title=args.title,
                goal_id=args.goal_id,
                work_item_id=args.work_item_id,
                worktree_path=getattr(args, "worktree_path", None),
                base_branch=getattr(args, "base_branch", "main") or "main",
                ticket=getattr(args, "ticket", None),
                initiative=getattr(args, "initiative", None),
                autonomy_budget=int(getattr(args, "autonomy_budget", 0) or 0),
                decision_scope=getattr(args, "decision_scope", "kernel"),
                generated_at=getattr(args, "generated_at", None),
                requested_by=args.requested_by,
                justification=args.justification,
                ttl_seconds=int(
                    getattr(
                        args,
                        "ttl_seconds",
                        workflow_bootstrap_mod.DEFAULT_BOOTSTRAP_REQUEST_TTL_SECONDS,
                    )
                    or workflow_bootstrap_mod.DEFAULT_BOOTSTRAP_REQUEST_TTL_SECONDS
                ),
            )
        except ValueError as e:
            return _err(f"{args.action}: {e}")
        return _ok(result)

    if args.action in {"bootstrap-local", "bootstrap-planner"}:
        try:
            result = workflow_bootstrap_mod.bootstrap_local_workflow(
                workflow_id=args.workflow_id,
                bootstrap_token=args.bootstrap_token,
                desired_end_state=args.desired_end_state,
                title=args.title,
                goal_id=args.goal_id,
                work_item_id=args.work_item_id,
                worktree_path=getattr(args, "worktree_path", None),
                base_branch=getattr(args, "base_branch", None),
                ticket=getattr(args, "ticket", None),
                initiative=getattr(args, "initiative", None),
                autonomy_budget=getattr(args, "autonomy_budget", None),
                decision_scope=getattr(args, "decision_scope", None),
                generated_at=getattr(args, "generated_at", None),
            )
        except ValueError as e:
            return _err(f"{args.action}: {e}")
        return _ok(result)

    workflow_db_root = None
    if args.action in {"stage-packet", "get"}:
        workflow_db_root = getattr(args, "worktree_path", None) or None

    conn = _get_conn(project_root=workflow_db_root)
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

        elif args.action == "scope-sync":
            # @decision DEC-CLAUDEX-SCOPE-TRIAD-UNIFIED-WRITE-AUTHORITY-001
            # Title: scope-sync atomically writes workflow_scope + work_items.scope_json
            #   from a single scope file, eliminating the dual-write-path drift that
            #   causes _validate_work_item_scope_matches_authority to fire.
            # Status: accepted
            # Rationale: Prior to this verb, workflow_scope and work_items.scope_json were
            #   written by two independent CLI paths (scope-set and work-item-set) with no
            #   transactional bridge. Any orchestrator that refreshed workflow_scope without
            #   mirroring the same triad into work_items.scope_json would produce a
            #   prompt-pack compile failure from the guard in prompt_pack_resolver.py.
            #   This verb reads the scope file once, validates its shape, checks the
            #   work_item_id exists, then executes BOTH SQL writes inside a single
            #   SQLite transaction — so either both commit or both roll back.
            #   The legacy scope-set and work-item-set primitives remain intact as
            #   lower-level escape hatches; scope-sync is the blessed orchestrator path.
            import json as _json
            import time as _time

            scope_file_path = getattr(args, "scope_file", None)
            work_item_id = getattr(args, "work_item_id", None)

            # Step 1: Parse and validate scope file (before any write).
            try:
                with open(scope_file_path, "r", encoding="utf-8") as _fh:
                    raw_text = _fh.read()
                scope_data = _json.loads(raw_text)
            except (OSError, IOError) as e:
                return _err(f"scope-sync: cannot read scope file '{scope_file_path}': {e}")
            except _json.JSONDecodeError as e:
                return _err(f"scope-sync: scope file is not valid JSON: {e}")

            if not isinstance(scope_data, dict):
                return _err(
                    f"scope-sync: scope file must be a JSON object (dict), "
                    f"got {type(scope_data).__name__}"
                )

            # Validate key set — only these keys are legal (mirrors _SCOPE_KEYS +
            # authority_domains alias; unknown keys are an error so the caller
            # cannot silently pass a stale full-manifest slice file).
            _LEGAL_SCOPE_FILE_KEYS = frozenset({
                "allowed_paths",
                "required_paths",
                "forbidden_paths",
                "state_domains",
                "authority_domains",  # alias for state_domains / authority_domains column
            })
            unknown_keys = set(scope_data.keys()) - _LEGAL_SCOPE_FILE_KEYS
            if unknown_keys:
                return _err(
                    f"scope-sync: scope file contains unknown key(s): "
                    f"{sorted(unknown_keys)}. "
                    f"Legal keys are: {sorted(_LEGAL_SCOPE_FILE_KEYS)}. "
                    f"Did you accidentally pass the full slice manifest instead of "
                    f"a narrow scope-triad file?"
                )

            # Validate that path values are lists of strings.
            _PATH_KEYS = ("allowed_paths", "required_paths", "forbidden_paths")
            for _pk in _PATH_KEYS:
                _val = scope_data.get(_pk, [])
                if not isinstance(_val, list):
                    return _err(
                        f"scope-sync: '{_pk}' must be a JSON array of strings, "
                        f"got {type(_val).__name__}"
                    )
                for _item in _val:
                    if not isinstance(_item, str):
                        return _err(
                            f"scope-sync: '{_pk}' must be a JSON array of strings; "
                            f"found non-string element {_item!r}"
                        )

            # Validate auxiliary domain lists.
            for _dk in ("state_domains", "authority_domains"):
                _val = scope_data.get(_dk, [])
                if not isinstance(_val, list):
                    return _err(
                        f"scope-sync: '{_dk}' must be a JSON array of strings, "
                        f"got {type(_val).__name__}"
                    )

            allowed_paths = scope_data.get("allowed_paths", [])
            required_paths = scope_data.get("required_paths", [])
            forbidden_paths = scope_data.get("forbidden_paths", [])
            # authority_domains on the workflow_scope row uses the name from
            # workflows.set_scope; scope file may use either name.
            authority_domains = scope_data.get("authority_domains") or scope_data.get("state_domains") or []

            # Serialize scope_json for work_items using the canonical key names
            # (_SCOPE_KEYS: allowed_paths, required_paths, forbidden_paths, state_domains).
            # state_domains carries whichever domain list the file provided.
            state_domains = scope_data.get("state_domains") or scope_data.get("authority_domains") or []
            scope_json_payload = {
                "allowed_paths": allowed_paths,
                "required_paths": required_paths,
                "forbidden_paths": forbidden_paths,
                "state_domains": state_domains,
            }
            scope_json_str = _json.dumps(scope_json_payload)

            # Step 2: Validate workflow binding exists (guard replicates set_scope check).
            if workflows_mod.get_binding(conn, args.workflow_id) is None:
                return _err(
                    f"scope-sync: workflow_id '{args.workflow_id}' not found in "
                    f"workflow_bindings. Run 'cc-policy workflow bind' first."
                )

            # Step 3: Validate work_item_id exists (must happen before any write).
            import runtime.core.decision_work_registry as _dwr

            existing_wi = _dwr.get_work_item(conn, work_item_id)
            if existing_wi is None:
                return _err(
                    f"scope-sync: work_item_id '{work_item_id}' not found in "
                    f"work_items table. Seed it first via 'cc-policy workflow work-item-set'. "
                    f"No writes performed (atomic rollback)."
                )

            # Step 4: Both writes in a single SQLite transaction.
            # We bypass workflows_mod.set_scope (which has its own with conn:) and
            # _dwr.update_work_item_scope_json (same) to ensure TRUE atomicity —
            # both SQL statements commit or neither does.
            now = int(_time.time())
            with conn:
                conn.execute(
                    """
                    INSERT INTO workflow_scope
                        (workflow_id, allowed_paths, required_paths, forbidden_paths,
                         authority_domains, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(workflow_id) DO UPDATE SET
                        allowed_paths     = excluded.allowed_paths,
                        required_paths    = excluded.required_paths,
                        forbidden_paths   = excluded.forbidden_paths,
                        authority_domains = excluded.authority_domains,
                        updated_at        = excluded.updated_at
                    """,
                    (
                        args.workflow_id,
                        _json.dumps(allowed_paths),
                        _json.dumps(required_paths),
                        _json.dumps(forbidden_paths),
                        _json.dumps(authority_domains),
                        now,
                    ),
                )
                conn.execute(
                    "UPDATE work_items SET scope_json = ?, updated_at = ? WHERE work_item_id = ?",
                    (scope_json_str, now, work_item_id),
                )

            return _ok({
                "workflow_id": args.workflow_id,
                "work_item_id": work_item_id,
                "action": "scope-sync",
                "paths_written": 3,
                "status": "ok",
            })

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

        elif args.action == "stage-packet":
            from runtime.core.stage_packet import build_stage_packet as _build_stage_packet

            try:
                result = _build_stage_packet(
                    conn,
                    workflow_id=getattr(args, "workflow_id", None),
                    stage_id=args.stage_id,
                    goal_id=getattr(args, "goal_id", None),
                    work_item_id=getattr(args, "work_item_id", None),
                    worktree_path=getattr(args, "worktree_path", None),
                    decision_scope=getattr(args, "decision_scope", "kernel"),
                    generated_at=getattr(args, "generated_at", None),
                )
            except ValueError as e:
                return _err(f"stage-packet: {e}")
            return _ok(result)

        elif args.action == "list":
            rows = workflows_mod.list_bindings(conn)
            return _ok({"items": rows, "count": len(rows)})

        elif args.action == "unbind":
            removed = workflows_mod.unbind_workflow(conn, args.workflow_id)
            return _ok(
                {
                    "workflow_id": args.workflow_id,
                    "action": "unbind",
                    "removed": removed,
                    "found": removed,
                }
            )

        elif args.action == "scope-unset":
            removed = workflows_mod.unset_scope(conn, args.workflow_id)
            return _ok(
                {
                    "workflow_id": args.workflow_id,
                    "action": "scope-unset",
                    "removed": removed,
                    "found": removed,
                }
            )

        elif args.action == "goal-set":
            # Canonical workflow-scoped goal upsert.
            # Refuses unbound workflow_id so callers cannot seed goals under
            # workflows that have no worktree/branch binding — the binding
            # is the authority that proves the workflow exists.
            # (DEC-CLAUDEX-DW-WORKFLOW-JOIN-001)
            if workflows_mod.get_binding(conn, args.workflow_id) is None:
                return _err(
                    f"workflow_id '{args.workflow_id}' is not bound; "
                    f"run `cc-policy workflow bind` first. Refusing to "
                    f"seed a goal under an unbound workflow — this is the "
                    f"authority check introduced by "
                    f"DEC-CLAUDEX-DW-WORKFLOW-JOIN-001."
                )
            import runtime.core.decision_work_registry as _dwr

            # Cross-workflow ownership guard on the goal authority.
            # Symmetric with the work-item-set check: upsert must not
            # reassign an existing goal_id from workflow A to workflow B.
            # Legal upserts — same-workflow overwrite and legacy
            # NULL-workflow adoption — are preserved.
            # (DEC-CLAUDEX-DW-WORKFLOW-JOIN-001)
            existing = _dwr.get_goal(conn, args.goal_id)
            if (
                existing is not None
                and existing.workflow_id is not None
                and existing.workflow_id != args.workflow_id
            ):
                return _err(
                    f"goal_id '{args.goal_id}' is already scoped to "
                    f"workflow '{existing.workflow_id}'; refusing to "
                    f"reassign it to '{args.workflow_id}'. Cross-workflow "
                    f"goal reassignment would re-open the contract bleed "
                    f"closed by DEC-CLAUDEX-DW-WORKFLOW-JOIN-001. Choose a "
                    f"distinct goal_id for the new workflow, or retire the "
                    f"existing goal first."
                )

            record = _dwr.GoalRecord(
                goal_id=args.goal_id,
                desired_end_state=args.desired_end_state,
                status=args.status,
                autonomy_budget=int(args.autonomy_budget),
                continuation_rules_json=getattr(args, "continuation_rules_json", "[]") or "[]",
                stop_conditions_json=getattr(args, "stop_conditions_json", "[]") or "[]",
                escalation_boundaries_json=getattr(args, "escalation_boundaries_json", "[]") or "[]",
                user_decision_boundaries_json=getattr(args, "user_decision_boundaries_json", "[]") or "[]",
                workflow_id=args.workflow_id,
            )
            stored = _dwr.upsert_goal(conn, record)
            return _ok(
                {
                    "action": "goal-set",
                    "workflow_id": args.workflow_id,
                    "goal_id": stored.goal_id,
                    "goal_status": stored.status,
                    "created_at": stored.created_at,
                    "updated_at": stored.updated_at,
                }
            )

        elif args.action == "work-item-set":
            # Canonical workflow-scoped work-item upsert.
            # Two authority checks:
            #   1) workflow_id must be bound (same rule as goal-set).
            #   2) goal_id must already exist AND carry the same workflow_id
            #      — otherwise the caller is attaching a work_item to a goal
            #      that belongs to a different workflow, which would re-open
            #      the cross-workflow bleed DEC-CLAUDEX-DW-WORKFLOW-JOIN-001
            #      closed.
            if workflows_mod.get_binding(conn, args.workflow_id) is None:
                return _err(
                    f"workflow_id '{args.workflow_id}' is not bound; "
                    f"run `cc-policy workflow bind` first. Refusing to "
                    f"seed a work_item under an unbound workflow."
                )
            import runtime.core.decision_work_registry as _dwr

            goal = _dwr.get_goal(conn, args.goal_id)
            if goal is None:
                return _err(
                    f"goal_id '{args.goal_id}' not found; create the goal "
                    f"first with `cc-policy workflow goal-set`."
                )
            if goal.workflow_id != args.workflow_id:
                return _err(
                    f"goal_id '{args.goal_id}' is scoped to workflow "
                    f"'{goal.workflow_id}', not '{args.workflow_id}'. "
                    f"Refusing to attach a work_item across workflow "
                    f"boundaries (DEC-CLAUDEX-DW-WORKFLOW-JOIN-001)."
                )
            record = _dwr.WorkItemRecord(
                work_item_id=args.work_item_id,
                goal_id=args.goal_id,
                title=args.title,
                status=args.status,
                version=int(getattr(args, "version", 1) or 1),
                author=getattr(args, "author", "planner") or "planner",
                scope_json=getattr(args, "scope_json", "{}") or "{}",
                evaluation_json=getattr(args, "evaluation_json", "{}") or "{}",
                head_sha=getattr(args, "head_sha", None) or None,
                reviewer_round=int(getattr(args, "reviewer_round", 0) or 0),
                workflow_id=args.workflow_id,
            )
            stored = _dwr.upsert_work_item(conn, record)
            return _ok(
                {
                    "action": "work-item-set",
                    "workflow_id": args.workflow_id,
                    "goal_id": stored.goal_id,
                    "work_item_id": stored.work_item_id,
                    "work_item_status": stored.status,
                    "created_at": stored.created_at,
                    "updated_at": stored.updated_at,
                }
            )

        elif args.action == "goal-get":
            import runtime.core.decision_work_registry as _dwr

            goal = _dwr.get_goal(conn, args.goal_id)
            if goal is None:
                return _err(f"goal_id '{args.goal_id}' not found")
            return _ok(
                {
                    "goal_id": goal.goal_id,
                    "desired_end_state": goal.desired_end_state,
                    "status": goal.status,
                    "autonomy_budget": goal.autonomy_budget,
                    "workflow_id": goal.workflow_id,
                    "created_at": goal.created_at,
                    "updated_at": goal.updated_at,
                    "found": True,
                }
            )

        elif args.action == "work-item-get":
            import runtime.core.decision_work_registry as _dwr

            wi = _dwr.get_work_item(conn, args.work_item_id)
            if wi is None:
                return _err(f"work_item_id '{args.work_item_id}' not found")
            return _ok(
                {
                    "work_item_id": wi.work_item_id,
                    "goal_id": wi.goal_id,
                    "title": wi.title,
                    "status": wi.status,
                    "version": wi.version,
                    "author": wi.author,
                    "head_sha": wi.head_sha,
                    "reviewer_round": wi.reviewer_round,
                    "workflow_id": wi.workflow_id,
                    "created_at": wi.created_at,
                    "updated_at": wi.updated_at,
                    "found": True,
                }
            )

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


def _handle_critic_review(args) -> int:
    """Handle all ``cc-policy critic-review`` subcommands."""
    import json as _json

    conn = _get_conn()
    try:
        if args.action == "submit":
            metadata = {}
            if getattr(args, "metadata", None):
                try:
                    metadata = _json.loads(args.metadata)
                except _json.JSONDecodeError as e:
                    return _err(f"invalid JSON metadata: {e}")
            result = critic_reviews_mod.submit(
                conn,
                workflow_id=args.workflow_id,
                lease_id=getattr(args, "lease_id", "") or "",
                role=getattr(args, "role", critic_reviews_mod.IMPLEMENTER_ROLE),
                provider=getattr(args, "provider", "codex") or "codex",
                verdict=args.verdict,
                summary=getattr(args, "summary", "") or "",
                detail=getattr(args, "detail", "") or "",
                fingerprint=getattr(args, "fingerprint", "") or "",
                metadata=metadata,
                project_root=getattr(args, "project_root", "") or "",
            )
            return _ok(result)

        elif args.action == "latest":
            record = critic_reviews_mod.latest(
                conn,
                workflow_id=getattr(args, "workflow_id", None),
                lease_id=getattr(args, "lease_id", None),
                role=getattr(args, "role", critic_reviews_mod.IMPLEMENTER_ROLE),
            )
            if record is None:
                return _ok({"found": False})
            return _ok(record)

        elif args.action == "list":
            rows = critic_reviews_mod.list_reviews(
                conn,
                workflow_id=getattr(args, "workflow_id", None),
                lease_id=getattr(args, "lease_id", None),
                role=getattr(args, "role", None),
                limit=getattr(args, "limit", None),
            )
            return _ok({"items": rows, "count": len(rows)})

    except ValueError as e:
        return _err(str(e))
    finally:
        conn.close()
    return _err(f"unknown critic-review action: {args.action}")


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
    from dataclasses import replace as _replace

    from runtime.core.command_intent import build_bash_command_intent as _build_bash_command_intent

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
    command = tool_input.get("command", "") if isinstance(tool_input, dict) else ""
    command_intent = (
        _build_bash_command_intent(command, cwd=cwd)
        if tool_name == "Bash" and command
        else None
    )

    # --- Target-aware context resolution (DEC-PE-W3-CTX-001) ---
    # Runtime-owned command intent is now the primary target resolver. When
    # the command targets a different repo than the session cwd (e.g.
    # ``git -C /other-repo commit`` or ``cd /other-repo && git commit``),
    # build_bash_command_intent() derives target_cwd from the raw command.
    # ``payload.target_cwd`` remains supported as an explicit override for
    # backwards-compatible callers and older tests.
    #
    # Resolution order:
    #   1. explicit payload.target_cwd if present
    #   2. derived command_intent.target_cwd
    #   3. cwd as before
    resolved_project_root = ""
    target_cwd = payload.get("target_cwd", "") or ""
    if target_cwd and command_intent is not None:
        command_intent = _replace(command_intent, target_cwd=target_cwd)
    elif not target_cwd and command_intent is not None:
        target_cwd = command_intent.target_cwd
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
    # DEC-CONV-001: normalize so all DB lookups use the canonical realpath form.
    # build_context also normalizes, but applying it here ensures the value
    # logged or passed to other callsites is already canonical.
    if resolved_project_root:
        from runtime.core.policy_utils import normalize_path as _normalize_path

        resolved_project_root = _normalize_path(resolved_project_root)

    # Fix #175: effective_cwd is the directory policies should treat as "current
    # working directory". When the command targets a repo other than the session
    # cwd (target_cwd was resolved to a project root), use target_cwd so that
    # policies receiving request.cwd see the target repo's path, not the session
    # path. This eliminates the workaround in bash_main_sacred, bash_eval_readiness,
    # and bash_workflow_scope that re-parsed the raw command with
    # extract_git_target_dir() — those policies now use request.context.project_root
    # or request.cwd and get the right directory without re-parsing.
    effective_cwd = target_cwd if resolved_project_root else cwd

    conn = _get_conn()
    try:
        ctx = policy_engine_mod.build_context(
            conn,
            cwd=effective_cwd,
            actor_role=actor_role,
            actor_id=actor_id,
            project_root=resolved_project_root,
        )

        request = policy_engine_mod.PolicyRequest(
            event_type=event_type,
            tool_name=tool_name,
            tool_input=tool_input,
            context=ctx,
            cwd=effective_cwd,
            command_intent=command_intent,
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

        carrier_deny = _agent_contract_carrier_effect(conn, payload, decision)
        if carrier_deny is not None:
            decision = carrier_deny
    finally:
        conn.close()

    # Build hookSpecificOutput per Claude hook contract.
    # ENFORCE-RCA-11 / DEC-EVAL-HOOKOUT-001: hookEventName is REQUIRED by the
    # Claude Code hook output contract (hooks/HOOKS.md:28-34). Without it,
    # Claude Code silently discards the permissionDecision and the command
    # executes unblocked. This was the latent root cause of every
    # cc-policy evaluate deny being a no-op since PE-W1 (3be693f).
    if decision.action == "deny":
        hook_output = {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": decision.reason,
            "blockingHook": decision.policy_name,
        }
    elif decision.action == "feedback":
        hook_output = {
            "hookEventName": "PreToolUse",
            "additionalContext": decision.reason,
        }
    else:
        hook_output = {
            "hookEventName": "PreToolUse",
            "permissionDecision": "allow",
        }

    return _ok(
        {
            "action": decision.action,
            "reason": decision.reason,
            "policy_name": decision.policy_name,
            "hookSpecificOutput": hook_output,
        }
    )


def _handle_evaluate_quick(args) -> int:
    """Handle ``cc-policy evaluate quick`` — STFP scope gate.

    Runs git diff against HEAD in the resolved project root, validates
    that the diff meets Simple Task Fast Path criteria (<=50 lines,
    <=3 files, no source-code extensions), and writes
    evaluation_state=ready_for_guardian when criteria are met.

    Args (from argparse):
      --project-root  Path to the git repo root. Defaults to
                      CLAUDE_PROJECT_DIR env var, then git root of cwd.
      --workflow-id   Workflow ID for evaluation_state row.
                      Defaults to "stfp-quick" inside quick_eval module.

    Output JSON (on stdout):
      {"status": "ok", "eligible": true,  "reason": "...",
       "files_changed": N, "lines_changed": N, "eval_written": true}

    On ineligible diff, exits 1 with error JSON on stderr so the caller
    can detect failure unambiguously.

    @decision DEC-QUICKEVAL-002
    Title: evaluate quick exits 1 on ineligible diffs
    Status: accepted
    Rationale: Shell callers (orchestrator scripts) rely on exit code to
      branch: 0=approved, 1=needs full reviewer. Emitting error JSON to
      stderr follows the cc-policy convention (_err returns exit code 1).
      The full result dict is always in the JSON payload regardless of
      exit code so callers can log the reason.
    """
    import os as _os

    project_root = getattr(args, "project_root", None) or ""
    if not project_root:
        project_root = _os.environ.get("CLAUDE_PROJECT_DIR", "")
    if not project_root:
        import subprocess as _sp

        r = _sp.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True,
            text=True,
        )
        project_root = r.stdout.strip() if r.returncode == 0 else ""

    if not project_root:
        return _err(
            "evaluate quick: cannot resolve project root — pass --project-root or set CLAUDE_PROJECT_DIR"
        )

    workflow_id = getattr(args, "workflow_id", None) or ""

    conn = _get_conn()
    try:
        result = quick_eval_mod.evaluate_quick(conn, project_root, workflow_id=workflow_id)
    finally:
        conn.close()

    if not result["eligible"]:
        # Emit structured error so callers can log the reason
        print(
            __import__("json").dumps({"status": "error", "message": result["reason"], **result}),
            file=sys.stderr,
        )
        return 1

    return _ok(result)


def _handle_context(args) -> int:
    """Handle ``cc-policy context`` subcommands.

    Subcommands:
      role  — resolve the current actor role from lease → marker → env var
              and return {"role": str, "agent_id": str, "workflow_id": str}.

    This is the canonical identity resolution path for check-*.sh hooks.
    All SubagentStop hooks should call ``cc-policy context role`` instead of
    reading context-lib.sh current_active_agent_role() so they share the same
    lease → marker → env var resolution order as the write/bash policy engine.

    @decision DEC-PE-W5-004
    Title: cc-policy context role is the canonical identity resolver for hooks
    Status: accepted
    Rationale: check-*.sh hooks previously called current_active_agent_role()
      from context-lib.sh (marker-only lookup). PE-W5 introduces this CLI
      endpoint so hooks use the same build_context() resolution path used by
      the policy engine: lease → marker → env var. All SubagentStop hooks that
      need actor role MUST call this endpoint, not the shell helper.
    """
    if args.action == "role":
        import os as _os

        cwd = _os.environ.get("CLAUDE_PROJECT_DIR", "") or _os.getcwd()
        actor_role = _os.environ.get("CLAUDE_ACTOR_ROLE", "")
        actor_id = _os.environ.get("CLAUDE_ACTOR_ID", "")

        conn = _get_conn()
        try:
            ctx = policy_engine_mod.build_context(
                conn,
                cwd=cwd,
                actor_role=actor_role,
                actor_id=actor_id,
            )
        finally:
            conn.close()

        return _ok(
            {
                "role": ctx.actor_role or "",
                "agent_id": ctx.actor_id or "",
                "workflow_id": ctx.workflow_id or "",
            }
        )

    if args.action == "capability-contract":
        from runtime.core.authority_registry import resolve_contract

        stage = args.stage
        contract = resolve_contract(stage)
        if contract is None:
            from runtime.core.stage_registry import ACTIVE_STAGES

            return _err(
                f"Unknown or sink stage {stage!r}; "
                f"valid active stages: {sorted(ACTIVE_STAGES)}"
            )
        return _ok({"data": contract.as_prompt_projection()})

    return _err(f"unknown context action: {args.action}")


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
    """Resolve project_root from args, env, or git root. Returns '' on failure.

    All resolved paths are normalized via normalize_path() (DEC-CONV-001) so
    the returned value is always a canonical realpath form suitable for use
    as a SQLite key in test_state and other tables.
    """
    import os

    from runtime.core.policy_utils import normalize_path

    project_root = getattr(args, "project_root", None) or ""
    if not project_root:
        project_root = os.environ.get("CLAUDE_PROJECT_DIR", "")
    if not project_root:
        import subprocess

        result = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True,
            text=True,
        )
        project_root = result.stdout.strip() if result.returncode == 0 else ""
    return normalize_path(project_root) if project_root else ""


def _handle_scratchlane(args) -> int:
    """Handle task-local scratchlane permit CRUD.

    Scratchlanes are user-approved artifact roots under
    ``tmp/.claude-scratch/<task_slug>``. This handler is intentionally narrow:
    it resolves the project root, reads/writes the permit table, and returns
    JSON describing the active root.
    """
    project_root = _resolve_project_root(args)
    if not project_root:
        return _err("scratchlane requires --project-root or CLAUDE_PROJECT_DIR")

    conn = _get_conn()
    try:
        if args.action == "grant":
            record = scratchlanes_mod.grant(
                conn,
                project_root,
                args.task_slug,
                granted_by=getattr(args, "granted_by", None) or "user",
                note=getattr(args, "note", None) or "",
            )
            Path(record["root_path"]).mkdir(parents=True, exist_ok=True)
            return _ok({"permit": record, "project_root": project_root})

        if args.action == "get":
            record = scratchlanes_mod.get_active(conn, project_root, args.task_slug)
            return _ok(
                {
                    "project_root": project_root,
                    "task_slug": args.task_slug,
                    "found": record is not None,
                    "permit": record,
                }
            )

        if args.action == "revoke":
            revoked = scratchlanes_mod.revoke(conn, project_root, args.task_slug)
            return _ok(
                {
                    "project_root": project_root,
                    "task_slug": args.task_slug,
                    "revoked": revoked,
                }
            )

        if args.action == "list":
            items = scratchlanes_mod.list_active(conn, project_root=project_root)
            return _ok(
                {
                    "project_root": project_root,
                    "items": items,
                    "count": len(items),
                }
            )
    finally:
        conn.close()

    return _err(f"unknown scratchlane action: {args.action}")


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
# Behavioral Evaluation Framework handler
# ---------------------------------------------------------------------------


def _get_eval_conn():
    """Open eval_results.db using the project-root convention.

    eval_results.db lives in <project_root>/.claude/ alongside state.db, but
    is a separate file managed exclusively by eval_metrics. This helper
    matches the get_eval_conn() signature in eval_metrics but derives the
    project root from _PROJECT_ROOT (the directory containing runtime/).

    @decision DEC-EVAL-CLI-001
    Title: _get_eval_conn() derives project_root from _PROJECT_ROOT
    Status: accepted
    Rationale: eval_metrics.get_eval_conn(project_dir) expects the project
      root (parent of .claude/). _PROJECT_ROOT = Path(__file__).parent.parent
      is the canonical project root for all CLI invocations. This is the same
      path used by default_db_path() for state.db, so both databases land in
      the same .claude/ directory. Callers never need to pass --db-path for
      eval subcommands.
    """
    return eval_metrics_mod.get_eval_conn(_PROJECT_ROOT)


def _handle_eval(args) -> int:
    """Handle all ``cc-policy eval`` subcommands.

    Subcommands:
      run [--category CAT] [--mode MODE] [--live]
            [--scenarios-dir DIR] [--fixtures-dir DIR]
          Discover and run scenarios. Outputs JSON with run_id and summary.

      report [--run-id ID] [--last N] [--json]
          Generate a human-readable (or JSON) report. Defaults to most
          recent run. Text output goes to stdout.

      list [--category CAT] [--mode MODE]
          List available scenarios as a JSON array.

      score --run-id ID
          Re-score a previous run from eval_outputs.

    Authority invariants (DEC-EVAL-CLI-001):
      - These commands NEVER write to state.db.
      - ``run`` and ``score`` write to eval_results.db via eval_metrics.
      - ``report`` and ``list`` are read-only.
    """
    if args.action == "run":
        import runtime.core.eval_runner as eval_runner_mod

        scenarios_dir_raw = getattr(args, "scenarios_dir", None)
        fixtures_dir_raw = getattr(args, "fixtures_dir", None)

        scenarios_dir = (
            Path(scenarios_dir_raw) if scenarios_dir_raw else _PROJECT_ROOT / "evals" / "scenarios"
        )
        fixtures_dir = (
            Path(fixtures_dir_raw) if fixtures_dir_raw else _PROJECT_ROOT / "evals" / "fixtures"
        )
        project_tmp = _PROJECT_ROOT / "tmp"
        project_tmp.mkdir(parents=True, exist_ok=True)

        category = getattr(args, "category", None) or None
        live_flag = getattr(args, "live", False)
        mode_arg = getattr(args, "mode", None) or None

        # --live flag overrides --mode
        if live_flag:
            mode_arg = "live"

        if not scenarios_dir.is_dir():
            return _err(f"eval run: scenarios-dir not found: {scenarios_dir}")
        if not fixtures_dir.is_dir():
            return _err(f"eval run: fixtures-dir not found: {fixtures_dir}")

        eval_conn = _get_eval_conn()
        try:
            run_id = eval_runner_mod.run_all(
                scenarios_dir=scenarios_dir,
                fixtures_dir=fixtures_dir,
                eval_conn=eval_conn,
                project_tmp=project_tmp,
                repo_root=_PROJECT_ROOT,
                category=category,
                mode=mode_arg,
            )

            run = eval_metrics_mod.get_run(eval_conn, run_id)
            return _ok(
                {
                    "run_id": run_id,
                    "scenario_count": run.get("scenario_count", 0),
                    "pass_count": run.get("pass_count", 0),
                    "fail_count": run.get("fail_count", 0),
                    "error_count": run.get("error_count", 0),
                    "mode": run.get("mode", "deterministic"),
                }
            )
        except Exception as exc:
            return _err(f"eval run error: {exc}")
        finally:
            eval_conn.close()

    elif args.action == "report":
        run_id = getattr(args, "run_id", None) or None
        as_json = getattr(args, "as_json", False)

        eval_conn = _get_eval_conn()
        try:
            if as_json:
                report_data = eval_report_mod.generate_json_report(eval_conn, run_id=run_id)
                return _ok(report_data)
            else:
                report_text = eval_report_mod.generate_report(eval_conn, run_id=run_id)
                print(report_text)
                return 0
        except Exception as exc:
            return _err(f"eval report error: {exc}")
        finally:
            eval_conn.close()

    elif args.action == "list":
        import runtime.core.eval_runner as eval_runner_mod

        scenarios_dir_raw = getattr(args, "scenarios_dir", None)
        fixtures_dir_raw = getattr(args, "fixtures_dir", None)

        scenarios_dir = (
            Path(scenarios_dir_raw) if scenarios_dir_raw else _PROJECT_ROOT / "evals" / "scenarios"
        )

        category = getattr(args, "category", None) or None
        mode_arg = getattr(args, "mode", None) or None

        if not scenarios_dir.is_dir():
            return _err(f"eval list: scenarios-dir not found: {scenarios_dir}")

        try:
            scenarios = eval_runner_mod.discover_scenarios(
                scenarios_dir, category=category, mode=mode_arg
            )
            # Return a lightweight projection — callers don't need full YAML
            items = [
                {
                    "name": s.get("name"),
                    "category": s.get("category"),
                    "mode": s.get("mode"),
                    "fixture": s.get("fixture"),
                    "description": s.get("description", ""),
                }
                for s in scenarios
            ]
            return _ok({"items": items, "count": len(items)})
        except Exception as exc:
            return _err(f"eval list error: {exc}")

    elif args.action == "score":
        run_id = getattr(args, "run_id", None)
        if not run_id:
            return _err("eval score: --run-id is required")

        eval_conn = _get_eval_conn()
        try:
            run = eval_metrics_mod.get_run(eval_conn, run_id)
            if run is None:
                return _err(f"eval score: run_id '{run_id}' not found")

            # Fetch all outputs for this run and re-score via eval_scorer
            rows = eval_conn.execute(
                "SELECT scenario_id, raw_output FROM eval_outputs WHERE run_id = ? ORDER BY id",
                (run_id,),
            ).fetchall()

            if not rows:
                return _err(f"eval score: no outputs found for run_id '{run_id}'")

            # Get existing scores to retrieve ground_truth and category
            existing_scores = eval_metrics_mod.get_scores(eval_conn, run_id)
            score_map = {s["scenario_id"]: s for s in existing_scores}

            rescored = 0
            for row in rows:
                scenario_id = row[0]
                raw_output = row[1]
                existing = score_map.get(scenario_id, {})
                category = existing.get("category", "gate")
                verdict_expected = existing.get("verdict_expected", "")
                confidence_expected = existing.get("confidence_expected")

                ground_truth = {
                    "expected_verdict": verdict_expected,
                    "expected_confidence": confidence_expected,
                }
                scoring_weights: dict = {}

                result = eval_scorer_mod.score_scenario(raw_output, ground_truth, scoring_weights)
                eval_metrics_mod.record_score(
                    eval_conn,
                    run_id=run_id,
                    scenario_id=scenario_id,
                    category=category,
                    verdict_expected=verdict_expected,
                    verdict_actual=result.get("verdict_actual"),
                    verdict_correct=result.get("verdict_correct", 0),
                    defect_recall=result.get("defect_recall"),
                    evidence_score=result.get("evidence_score"),
                    false_positive_count=result.get("false_positive_count", 0),
                    confidence_expected=confidence_expected,
                    confidence_actual=result.get("confidence_actual"),
                    duration_ms=result.get("duration_ms"),
                    error_message=result.get("error_message"),
                )
                rescored += 1

            eval_metrics_mod.finalize_run(eval_conn, run_id)
            updated_run = eval_metrics_mod.get_run(eval_conn, run_id)
            return _ok(
                {
                    "run_id": run_id,
                    "rescored": rescored,
                    "scenario_count": updated_run.get("scenario_count", 0),
                    "pass_count": updated_run.get("pass_count", 0),
                    "fail_count": updated_run.get("fail_count", 0),
                    "error_count": updated_run.get("error_count", 0),
                }
            )
        except Exception as exc:
            return _err(f"eval score error: {exc}")
        finally:
            eval_conn.close()

    return _err(f"unknown eval action: {args.action}")


# ---------------------------------------------------------------------------
# Observatory handler (W-OBS-1)
# ---------------------------------------------------------------------------


def _handle_obs(args) -> int:
    """Handle all ``cc-policy obs`` subcommands.

    Subcommands:
      emit  <name> <value> [--labels JSON] [--session-id S] [--role R]
      emit-batch            Read a JSON array of metric dicts from stdin.
      query <name>          Query obs_metrics with optional filters.
      suggest <cat> <title> [--body B] [--target-metric M] [--baseline F]
                            [--signal-id S] [--source-session SS]
      accept <id>           Accept a suggestion (optional --measure-after T).
      reject <id>           Reject a suggestion (optional --reason R).
      defer  <id>           Defer a suggestion (optional --reassess-after N).
      batch-accept <cat>    Accept all proposed suggestions in a category.
      converge              Run check_convergence and return results.
      cleanup               Delete stale metrics and terminal suggestions.
      status                Return high-level observatory status.
      summary               Run full analysis and record an obs_run.

    All output is JSON. Errors go to stderr with exit code 1.
    """
    import json as _json

    conn = _get_conn()
    try:
        if args.action == "emit":
            labels = None
            if getattr(args, "labels", None):
                try:
                    labels = _json.loads(args.labels)
                except _json.JSONDecodeError as e:
                    return _err(f"obs emit: invalid --labels JSON: {e}")
            row_id = observatory_mod.emit_metric(
                conn,
                name=args.name,
                value=float(args.value),
                labels=labels,
                session_id=getattr(args, "session_id", None) or None,
                role=getattr(args, "role", None) or None,
            )
            return _ok({"id": row_id, "metric_name": args.name, "value": float(args.value)})

        elif args.action == "emit-batch":
            raw = sys.stdin.read()
            if not raw or not raw.strip():
                return _err("obs emit-batch: empty stdin — nothing to insert")
            try:
                metrics_list = _json.loads(raw)
            except _json.JSONDecodeError as e:
                return _err(f"obs emit-batch: invalid JSON on stdin: {e}")
            if not isinstance(metrics_list, list):
                return _err("obs emit-batch: stdin must be a JSON array")
            count = observatory_mod.emit_batch(conn, metrics_list)
            return _ok({"inserted": count})

        elif args.action == "query":
            labels_filter = None
            if getattr(args, "labels_filter", None):
                try:
                    labels_filter = _json.loads(args.labels_filter)
                except _json.JSONDecodeError as e:
                    return _err(f"obs query: invalid --labels-filter JSON: {e}")
            rows = observatory_mod.query_metrics(
                conn,
                name=args.name,
                since=getattr(args, "since", None),
                until=getattr(args, "until", None),
                labels_filter=labels_filter,
                role=getattr(args, "role", None) or None,
                limit=getattr(args, "limit", 100) or 100,
            )
            return _ok({"items": rows, "count": len(rows)})

        elif args.action == "suggest":
            baseline = getattr(args, "baseline", None)
            if baseline is not None:
                baseline = float(baseline)
            row_id = observatory_mod.suggest(
                conn,
                category=args.category,
                title=args.title,
                body=getattr(args, "body", None) or None,
                target_metric=getattr(args, "target_metric", None) or None,
                baseline=baseline,
                signal_id=getattr(args, "signal_id", None) or None,
                source_session=getattr(args, "source_session", None) or None,
            )
            return _ok({"id": row_id, "category": args.category, "title": args.title})

        elif args.action == "accept":
            measure_after = getattr(args, "measure_after", None)
            if measure_after is not None:
                measure_after = int(measure_after)
            observatory_mod.accept_suggestion(conn, id=int(args.id), measure_after=measure_after)
            return _ok({"id": int(args.id), "status": "accepted"})

        elif args.action == "reject":
            observatory_mod.reject_suggestion(
                conn,
                id=int(args.id),
                reason=getattr(args, "reason", None) or None,
            )
            return _ok({"id": int(args.id), "status": "rejected"})

        elif args.action == "defer":
            reassess = getattr(args, "reassess_after", 5) or 5
            observatory_mod.defer_suggestion(conn, id=int(args.id), reassess_after=int(reassess))
            return _ok({"id": int(args.id), "status": "deferred"})

        elif args.action == "batch-accept":
            count = observatory_mod.batch_accept(conn, category=args.category)
            return _ok({"category": args.category, "accepted": count})

        elif args.action == "converge":
            results = observatory_mod.check_convergence(conn)
            return _ok({"items": results, "count": len(results)})

        elif args.action == "cleanup":
            result = observatory_mod.obs_cleanup(
                conn,
                metrics_ttl_days=getattr(args, "metrics_ttl_days", 30) or 30,
                suggestions_ttl_days=getattr(args, "suggestions_ttl_days", 90) or 90,
            )
            return _ok(result)

        elif args.action == "status":
            result = observatory_mod.status(conn)
            return _ok(result)

        elif args.action == "summary":
            result = observatory_mod.summary(conn)
            return _ok(result)

    except Exception as e:
        return _err(f"obs command error: {e}")
    finally:
        conn.close()
    return _err(f"unknown obs action: {args.action}")


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
    # W-CONV-2: optional scoping params for project_root and workflow_id
    ms.add_argument(
        "--project-root",
        dest="project_root",
        default=None,
        help="Canonical project root path (normalize_path applied before storage)",
    )
    ms.add_argument(
        "--workflow-id",
        dest="workflow_id",
        default=None,
        help="Workflow ID to associate with this marker",
    )
    mga = marker_sub.add_parser("get-active")
    # ENFORCE-RCA-6-ext/#26: scoped marker lookup prevents cross-project
    # contamination. Without these flags, get_active returns the globally
    # newest active marker, which can be a stale marker from an unrelated
    # project and poison role detection in this one.
    mga.add_argument(
        "--project-root",
        dest="project_root",
        default=None,
        help="Scope marker lookup to this canonical project root",
    )
    mga.add_argument(
        "--workflow-id",
        dest="workflow_id",
        default=None,
        help="Scope marker lookup further to this workflow_id",
    )
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
    eq.add_argument("--source")
    eq.add_argument("--since", type=int)
    eq.add_argument("--limit", type=int, default=50)

    # hook — read-only ClauDEX hook manifest tooling
    # (DEC-CLAUDEX-HOOK-MANIFEST-001)
    hook_p = subparsers.add_parser(
        "hook",
        help="ClauDEX hook manifest tools (read-only)",
    )
    hook_sub = hook_p.add_subparsers(dest="action", required=True)
    hook_validate = hook_sub.add_parser(
        "validate-settings",
        help=(
            "Validate settings.json repo-owned hook wiring against "
            "runtime.core.hook_manifest; non-zero exit on drift or invalid "
            "adapter files"
        ),
    )
    hook_validate.add_argument(
        "--settings-path",
        default=None,
        help=(
            "Path to the settings.json to validate. Defaults to the repo "
            "root's settings.json."
        ),
    )

    hook_doc_check = hook_sub.add_parser(
        "doc-check",
        help=(
            "Validate hooks/HOOKS.md against the runtime-compiled "
            "hook-doc projection; non-zero exit on drift "
            "(DEC-CLAUDEX-HOOK-DOC-VALIDATION-001)"
        ),
    )
    hook_doc_check.add_argument(
        "--doc-path",
        default=None,
        help=(
            "Path to the hook doc to validate. Defaults to the repo "
            "root's hooks/HOOKS.md."
        ),
    )

    # bridge — read-only ClauDEX bridge permission surface tooling
    # (DEC-CLAUDEX-BRIDGE-PERMISSIONS-001)
    bridge_p = subparsers.add_parser(
        "bridge",
        help="ClauDEX bridge permission surface tools (read-only)",
    )
    bridge_sub = bridge_p.add_subparsers(dest="action", required=True)
    bridge_validate = bridge_sub.add_parser(
        "validate-settings",
        help=(
            "Validate ClauDEX/bridge/claude-settings.json against "
            "runtime.core.bridge_permissions; non-zero exit on drift "
            "(DEC-CLAUDEX-BRIDGE-PERMISSIONS-001)"
        ),
    )
    bridge_validate.add_argument(
        "--settings-path",
        default=None,
        help=(
            "Path to the bridge settings file to validate. Defaults to the "
            "repo root's ClauDEX/bridge/claude-settings.json."
        ),
    )
    bridge_broker_health = bridge_sub.add_parser(
        "broker-health",
        help=(
            "Probe bridge broker daemon health (pidfile + socket). "
            "Read-only classification."
        ),
    )
    bridge_broker_health.add_argument(
        "--braid-root",
        default=None,
        help="Override $BRAID_ROOT for the probe (defaults to env).",
    )
    bridge_topology = bridge_sub.add_parser(
        "topology",
        help=(
            "Probe the runtime-owned live lane topology (Codex/Claude pane "
            "targets + authority classification). Read-only."
        ),
    )
    bridge_topology.add_argument(
        "--braid-root",
        default=None,
        help="Override $BRAID_ROOT for the probe (defaults to env).",
    )
    bridge_topology.add_argument(
        "--state-dir",
        default=None,
        help="Override $CLAUDEX_STATE_DIR for the probe (defaults to env).",
    )
    bridge_probe = bridge_sub.add_parser(
        "probe-response-drift",
        help=(
            "Classify response-surface drift for a run (broker health + "
            "pending-review + env). Read-only."
        ),
    )
    bridge_probe.add_argument(
        "--run-id",
        required=True,
        help="Target run id under $BRAID_ROOT/runs/.",
    )
    bridge_probe.add_argument(
        "--braid-root",
        default=None,
        help="Override $BRAID_ROOT for the probe (defaults to env).",
    )
    bridge_probe.add_argument(
        "--state-dir",
        default=None,
        help="Override $CLAUDEX_STATE_DIR for the probe (defaults to env).",
    )

    # constitution — read-only constitution registry inspection/validation
    const_p = subparsers.add_parser(
        "constitution",
        help="Constitution registry tools (read-only)",
    )
    const_sub = const_p.add_subparsers(dest="action", required=True)
    const_sub.add_parser(
        "list",
        help="List all constitution-level entries (concrete + planned) as JSON",
    )
    const_validate = const_sub.add_parser(
        "validate",
        help=(
            "Validate that all concrete constitution paths exist on disk; "
            "non-zero exit when any path is missing"
        ),
    )
    const_validate.add_argument(
        "--repo-root",
        default=None,
        help=(
            "Path to the repo root for file-existence checks. Defaults to "
            "the project root."
        ),
    )

    # decision — read-only decision-digest CLI projection surface
    # (DEC-CLAUDEX-DECISION-DIGEST-CLI-001, Phase 7 Slice 14)
    dec_p = subparsers.add_parser(
        "decision",
        help="Decision registry projections (read-only)",
    )
    dec_sub = dec_p.add_subparsers(dest="action", required=True)
    dec_digest = dec_sub.add_parser(
        "digest",
        help=(
            "Render the decision-digest projection from the canonical "
            "decision records stored in the runtime registry"
        ),
    )
    dec_digest.add_argument(
        "--cutoff-epoch",
        default="0",
        help=(
            "Inclusive lower bound on DecisionRecord.updated_at. "
            "Decisions older than this epoch are dropped from the "
            "projection. Default: 0 (include all)."
        ),
    )
    dec_digest.add_argument(
        "--generated-at",
        default=None,
        help=(
            "Unix epoch timestamp to stamp on the projection metadata. "
            "Default: current time."
        ),
    )
    dec_digest.add_argument(
        "--status",
        default=None,
        help="Filter decisions by DecisionRecord.status (optional)",
    )
    dec_digest.add_argument(
        "--scope",
        default=None,
        help="Filter decisions by DecisionRecord.scope (optional)",
    )

    # decision digest-check — Phase 7 Slice 15 read-only drift validation
    dec_digest_check = dec_sub.add_parser(
        "digest-check",
        help=(
            "Validate a candidate decision-digest body against the "
            "projection rendered from the canonical decision records; "
            "exits 0 when healthy and 1 with status=violation on drift"
        ),
    )
    dec_digest_check.add_argument(
        "--candidate-path",
        required=True,
        help=(
            "Path to the candidate decision-digest file (UTF-8 text). "
            "Read-only — the CLI never writes to this path."
        ),
    )
    dec_digest_check.add_argument(
        "--cutoff-epoch",
        default="0",
        help=(
            "Inclusive lower bound on DecisionRecord.updated_at applied "
            "before rendering the expected body. Default: 0 (include all)."
        ),
    )
    dec_digest_check.add_argument(
        "--status",
        default=None,
        help="Filter decisions by DecisionRecord.status (optional)",
    )
    dec_digest_check.add_argument(
        "--scope",
        default=None,
        help="Filter decisions by DecisionRecord.scope (optional)",
    )

    # decision ingest-commit — Phase 7 Slice 14 write path
    # (DEC-CLAUDEX-DEC-TRAILER-INGEST-001)
    dec_ingest = dec_sub.add_parser(
        "ingest-commit",
        help=(
            "Parse commit-message trailers (Decision: DEC-*) and upsert "
            "matching decision IDs into the canonical decision registry; "
            "exits 0 on success (including when no trailers are found)"
        ),
    )
    dec_ingest.add_argument(
        "--sha",
        required=True,
        help="Commit SHA to ingest (resolved via git show in --project-root)",
    )
    dec_ingest.add_argument(
        "--project-root",
        default=None,
        dest="project_root",
        help=(
            "Path to the git repository root. Defaults to the cc-policy "
            "project root if omitted."
        ),
    )
    dec_ingest.add_argument(
        "--dry-run",
        action="store_true",
        default=False,
        dest="dry_run",
        help=(
            "Parse trailers and report what would be ingested without "
            "writing to the database; exits 0."
        ),
    )

    # decision ingest-range — Phase 7 Slice 15 batch backfill write path
    # (DEC-CLAUDEX-DEC-INGEST-BACKFILL-001)
    dec_ingest_range = dec_sub.add_parser(
        "ingest-range",
        help=(
            "Batch-ingest Decision: DEC-* trailers from every commit in a "
            "git revision range (oldest→newest) into the canonical decision "
            "registry; exits 0 on success (including empty ranges). "
            "(DEC-CLAUDEX-DEC-INGEST-BACKFILL-001)"
        ),
    )
    dec_ingest_range.add_argument(
        "--range",
        required=True,
        dest="range",
        help=(
            "Git rev-list range spec (e.g. '6869fd3..origin/main' or "
            "'HEAD~10..HEAD'). Passed verbatim to git rev-list --reverse."
        ),
    )
    dec_ingest_range.add_argument(
        "--project-root",
        default=None,
        dest="project_root",
        help=(
            "Path to the git repository root used for git rev-list and "
            "git show. Defaults to the cc-policy project root if omitted."
        ),
    )
    dec_ingest_range.add_argument(
        "--dry-run",
        action="store_true",
        default=False,
        dest="dry_run",
        help=(
            "Iterate and parse commits but do not write to the database; "
            "reports commits_scanned and status=ok without DB mutations."
        ),
    )

    # decision drift-check — Phase 7 Slice 16 read-only drift detection
    # (DEC-CLAUDEX-DEC-DRIFT-CHECK-001)
    dec_drift_check = dec_sub.add_parser(
        "drift-check",
        help=(
            "Compare commit-trailer evidence in a git revision range against "
            "the current decision registry state; exits 0 when aligned, 1 "
            "when drift detected (rc=1 with status=ok payload), ≥2 on fatal "
            "error. Pure read-only — never writes to the decisions table. "
            "(DEC-CLAUDEX-DEC-DRIFT-CHECK-001)"
        ),
    )
    dec_drift_check.add_argument(
        "--range",
        required=True,
        dest="range",
        help=(
            "Git rev-list range spec (e.g. '6869fd3..HEAD' or 'A..B'). "
            "Passed verbatim to git rev-list --reverse. "
            "Use the full history root..HEAD for global enforcement."
        ),
    )
    dec_drift_check.add_argument(
        "--project-root",
        default=None,
        dest="project_root",
        help=(
            "Path to the git repository root used for git rev-list and "
            "git show. Defaults to the cc-policy project root if omitted."
        ),
    )
    dec_drift_check.add_argument(
        "--exit-on-drift",
        action=argparse.BooleanOptionalAction,
        default=True,
        dest="exit_on_drift",
        help=(
            "When drift is detected, exit with code 1 (default: enabled). "
            "Use --no-exit-on-drift to emit the drift payload with exit 0 "
            "(useful for informational CI steps that should never block)."
        ),
    )

    # prompt-pack — read-only ClauDEX prompt-pack drift validation
    # (DEC-CLAUDEX-PROMPT-PACK-CHECK-CLI-001)
    pp_p = subparsers.add_parser(
        "prompt-pack",
        help="ClauDEX prompt-pack tools (read-only)",
    )
    pp_sub = pp_p.add_subparsers(dest="action", required=True)
    pp_check = pp_sub.add_parser(
        "check",
        help=(
            "Validate a candidate prompt-pack body against the "
            "runtime-compiled expected projection; non-zero exit "
            "on drift (DEC-CLAUDEX-PROMPT-PACK-VALIDATION-001)"
        ),
    )
    pp_check.add_argument(
        "--candidate-path",
        required=True,
        help="Path to the candidate prompt-pack body file",
    )
    pp_check.add_argument(
        "--inputs-path",
        required=True,
        help=(
            "Path to a JSON file supplying the compiler inputs: "
            "workflow_id (string), stage_id (string), layers "
            "(object), generated_at (int), and optional "
            "manifest_version (string). When --metadata-path is "
            "also supplied, this inputs object must additionally "
            "include watched_files (list of non-empty strings)"
        ),
    )
    # Phase 7 Slice 12 — optional metadata drift gate
    # (DEC-CLAUDEX-PROMPT-PACK-METADATA-VALIDATION-001).
    pp_check.add_argument(
        "--metadata-path",
        default=None,
        help=(
            "Optional path to a JSON file containing the candidate "
            "prompt-pack metadata envelope (the ``metadata`` object "
            "from ``cc-policy prompt-pack compile``). When supplied, "
            "the CLI additionally validates the metadata against "
            "the compiler-rebuilt expected metadata; overall exit "
            "is 0 only when both body and metadata reports are "
            "healthy. Requires inputs.watched_files (list of non-"
            "empty strings) to be present"
        ),
    )

    # prompt-pack compile — read-only operator-preview surface on top
    # of the single compiler authority
    # (DEC-CLAUDEX-PROMPT-PACK-COMPILE-CLI-001). id mode only.
    pp_compile = pp_sub.add_parser(
        "compile",
        help=(
            "Compile a prompt pack via the single compiler authority "
            "in id mode and print the rendered body + identity fields "
            "as JSON (read-only, DEC-CLAUDEX-PROMPT-PACK-COMPILE-CLI-001)"
        ),
    )
    pp_compile.add_argument(
        "--workflow-id",
        required=True,
        help="Workflow identifier (runtime.core.workflows)",
    )
    pp_compile.add_argument(
        "--stage-id",
        required=True,
        help="Stage identifier (runtime.core.stage_registry)",
    )
    pp_compile.add_argument(
        "--goal-id",
        required=True,
        help="goal_contracts.goal_id to resolve via workflow_contract_capture",
    )
    pp_compile.add_argument(
        "--work-item-id",
        required=True,
        help="work_items.work_item_id to resolve via workflow_contract_capture",
    )
    pp_compile.add_argument(
        "--decision-scope",
        required=True,
        help="Exact-match scope string for the decision capture query",
    )
    pp_compile.add_argument(
        "--generated-at",
        type=int,
        required=True,
        help="Unix epoch seconds stamped into ProjectionMetadata.generated_at",
    )
    pp_compile.add_argument(
        "--finding",
        action="append",
        default=[],
        help=(
            "Unresolved finding identifier (repeatable). When provided, "
            "overrides live findings from the reviewer findings ledger. "
            "When absent, open findings are read from the ledger automatically"
        ),
    )
    pp_compile.add_argument(
        "--current-branch",
        default=None,
        help=(
            "Optional explicit current branch override — takes precedence "
            "over the workflow binding's branch column"
        ),
    )
    pp_compile.add_argument(
        "--worktree-path",
        default=None,
        help=(
            "Optional explicit worktree path override — takes precedence "
            "over the workflow binding's worktree_path column"
        ),
    )
    pp_compile.add_argument(
        "--manifest-version",
        default=None,
        help=(
            "Optional manifest version string stamped into the prompt "
            "pack's ProjectionMetadata.source_versions and provenance. "
            "Defaults to runtime.core.prompt_pack.MANIFEST_VERSION"
        ),
    )

    # prompt-pack subagent-start — thin adapter over the composition helper
    # (DEC-CLAUDEX-PROMPT-PACK-SUBAGENT-START-CLI-001)
    pp_sa = pp_sub.add_parser(
        "subagent-start",
        help=(
            "Build a SubagentStart hook envelope from a JSON payload "
            "(read-only, DEC-CLAUDEX-PROMPT-PACK-SUBAGENT-START-CLI-001)"
        ),
    )
    pp_sa.add_argument(
        "--payload",
        required=True,
        help=(
            "JSON object carrying the six request-contract fields at top level: "
            "workflow_id, stage_id, goal_id, work_item_id, decision_scope (strings), "
            "generated_at (int unix epoch seconds)"
        ),
    )

    # shadow — read-only ClauDEX shadow observer reporting
    # (DEC-CLAUDEX-SHADOW-PARITY-001)
    shadow_p = subparsers.add_parser(
        "shadow",
        help="ClauDEX shadow observer tools (read-only)",
    )
    shadow_sub = shadow_p.add_subparsers(dest="action", required=True)
    sr_parity = shadow_sub.add_parser(
        "parity-report",
        help="Aggregate recent shadow_stage_decision events into a JSON summary",
    )
    sr_parity.add_argument(
        "--source",
        default=None,
        help="Filter by events.source (e.g. 'workflow:wf-foo')",
    )
    sr_parity.add_argument(
        "--since",
        type=int,
        default=None,
        help="Earliest created_at (unix epoch seconds) to include",
    )
    sr_parity.add_argument(
        "--limit",
        type=int,
        default=200,
        help="Maximum number of shadow_stage_decision rows to aggregate (default 200)",
    )

    sr_invariant = shadow_sub.add_parser(
        "parity-invariant",
        help=(
            "Exit non-zero if shadow_stage_decision events show any "
            "unspecified_divergence or unknown reason code"
        ),
    )
    sr_invariant.add_argument(
        "--source",
        default=None,
        help="Filter by events.source (e.g. 'workflow:wf-foo')",
    )
    sr_invariant.add_argument(
        "--since",
        type=int,
        default=None,
        help="Earliest created_at (unix epoch seconds) to include",
    )
    sr_invariant.add_argument(
        "--limit",
        type=int,
        default=200,
        help="Maximum number of shadow_stage_decision rows to inspect (default 200)",
    )

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

    # worktree provision — W-GWT-2 (DEC-GUARD-WT-002)
    # Guardian calls this to create worktrees, issue leases, and bind workflows.
    wt_prov = wt_sub.add_parser(
        "provision",
        help=(
            "Provision a new worktree: git worktree add, DB register, "
            "Guardian + implementer leases, workflow binding (W-GWT-2)"
        ),
    )
    wt_prov.add_argument(
        "--workflow-id",
        dest="workflow_id",
        required=True,
        help="Workflow ID to bind to the new worktree",
    )
    wt_prov.add_argument(
        "--feature-name",
        dest="feature_name",
        required=True,
        help="Feature name (used to compute branch feature/<name> and path .worktrees/feature-<name>)",
    )
    wt_prov.add_argument(
        "--project-root",
        dest="project_root",
        default=None,
        help="Git repo root (defaults to CLAUDE_PROJECT_DIR env var)",
    )
    wt_prov.add_argument(
        "--base-branch",
        dest="base_branch",
        default="main",
        help="Base branch for the new worktree (default: main)",
    )

    # dispatch
    # lifecycle: agent marker lifecycle (single authority for on-stop by role)
    lc_p = subparsers.add_parser("lifecycle", help="Agent marker lifecycle")
    lc_sub = lc_p.add_subparsers(dest="action", required=True)
    lc_onstop = lc_sub.add_parser(
        "on-stop",
        help="Deactivate the active marker whose role matches agent_type (DEC-LIFECYCLE-003)",
    )
    lc_onstop.add_argument(
        "agent_type",
        help="Role to match for deactivation (implementer, reviewer, guardian, planner)",
    )
    # ENFORCE-RCA-6-ext/#26: scoped deactivation prevents the handler from
    # grabbing a globally-newer active marker from an unrelated project and
    # deactivating it instead of the caller's own.
    lc_onstop.add_argument(
        "--project-root",
        dest="project_root",
        default=None,
        help="Scope deactivation to this canonical project root",
    )
    lc_onstop.add_argument(
        "--workflow-id",
        dest="workflow_id",
        default=None,
        help="Scope deactivation further to this workflow_id",
    )

    dp_p = subparsers.add_parser("dispatch", help="Dispatch engine operations")
    dp_sub = dp_p.add_subparsers(dest="action", required=True)

    # process-stop: reads JSON from stdin, returns hookSpecificOutput
    dp_sub.add_parser(
        "process-stop",
        help="Process an agent stop event (JSON on stdin). Returns hookSpecificOutput.",
    )

    # agent-prompt: runtime-owned producer for Agent tool prompt bodies
    # (DEC-CLAUDEX-AGENT-PROMPT-001). Emits prompt_prefix containing the
    # CLAUDEX_CONTRACT_BLOCK: line so pre-agent.sh can extract the six contract
    # fields at PreToolUse:Agent time.
    dap = dp_sub.add_parser(
        "agent-prompt",
        help=(
            "Produce an Agent tool prompt prefix containing a CLAUDEX_CONTRACT_BLOCK line. "
            "Resolves goal_id and work_item_id from runtime state when omitted."
        ),
    )
    dap.add_argument("--workflow-id", dest="workflow_id", required=True)
    dap.add_argument("--stage-id", dest="stage_id", required=True)
    dap.add_argument("--goal-id", dest="goal_id", default=None)
    dap.add_argument("--work-item-id", dest="work_item_id", default=None)
    dap.add_argument("--decision-scope", dest="decision_scope", default="kernel")
    dap.add_argument("--generated-at", dest="generated_at", type=int, default=None)

    # agent-start / agent-stop: marker lifecycle
    das = dp_sub.add_parser("agent-start", help="Mark agent as active (set marker)")
    das.add_argument("agent_type", help="Role (implementer, reviewer, guardian, planner)")
    das.add_argument("agent_id", help="Unique agent identifier")
    # W-CONV-2: optional scoping so subagent-start.sh can write project-scoped markers
    das.add_argument(
        "--project-root",
        dest="project_root",
        default=None,
        help="Canonical project root path; stored in agent_markers.project_root",
    )
    das.add_argument(
        "--workflow-id",
        dest="workflow_id",
        default=None,
        help="Workflow ID to associate with this marker",
    )

    dae = dp_sub.add_parser("agent-stop", help="Deactivate agent marker")
    dae.add_argument("agent_type", help="Role (for symmetry; not used in deactivation query)")
    dae.add_argument("agent_id", help="Unique agent identifier")

    # attempt-issue: PreToolUse:Agent → issue a pending dispatch_attempts row
    # (DEC-CLAUDEX-HOOK-WIRING-001)
    daip = dp_sub.add_parser(
        "attempt-issue",
        help=(
            "Issue a pending dispatch attempt at PreToolUse:Agent time. "
            "Upserts agent_sessions + seats on the fly."
        ),
    )
    daip.add_argument(
        "--session-id", dest="session_id", required=True,
        help="Orchestrator session_id from PreToolUse payload",
    )
    daip.add_argument(
        "--agent-type", dest="agent_type", required=True,
        help="tool_input.subagent_type from PreToolUse payload",
    )
    daip.add_argument(
        "--instruction", dest="instruction", default="",
        help="Diagnostic label (e.g. the CLAUDEX_CONTRACT_BLOCK line). Not the full prompt.",
    )
    daip.add_argument(
        "--workflow-id", dest="workflow_id", default=None,
        help="Optional workflow binding extracted from the contract block",
    )
    daip.add_argument(
        "--timeout-at", dest="timeout_at", type=int, default=None,
        help="Optional Unix timestamp for stale-attempt sweep",
    )

    # attempt-claim: SubagentStart → claim delivery on the most recent pending attempt
    # (DEC-CLAUDEX-HOOK-WIRING-001)
    dacp = dp_sub.add_parser(
        "attempt-claim",
        help=(
            "Claim delivery of the most recent pending attempt at SubagentStart time. "
            "Returns {found: false} when no pending attempt exists."
        ),
    )
    dacp.add_argument(
        "--session-id", dest="session_id", required=True,
        help="session_id from SubagentStart payload",
    )
    dacp.add_argument(
        "--agent-type", dest="agent_type", required=True,
        help="agent_type from SubagentStart payload",
    )

    # attempt-expire-stale: sweep stale pending/delivered attempts → timed_out
    # Called by scripts/claudex-watchdog.sh on every tick.
    daes = dp_sub.add_parser(
        "attempt-expire-stale",
        help=(
            "Sweep pending/delivered dispatch attempts past timeout_at and "
            "optionally expire legacy pending rows with no timeout_at."
        ),
    )
    daes.add_argument(
        "--fallback-pending-max-age-seconds",
        dest="fallback_pending_max_age_seconds",
        type=int,
        default=0,
        help=(
            "Optional legacy cleanup threshold: expire pending rows with "
            "timeout_at NULL older than this many seconds."
        ),
    )

    # sweep-dead: runtime-owned dead-loop recovery (DEC-DEAD-RECOVERY-001).
    # Thin adapter over runtime.core.dead_recovery.sweep_all().  Called by
    # scripts/claudex-watchdog.sh immediately after attempt-expire-stale so
    # silent-death cases (no SubagentStop event) are recovered by the
    # runtime rather than by stop-hook recursion.
    dsw = dp_sub.add_parser(
        "sweep-dead",
        help=(
            "Mark active seats with past-grace terminal attempts as dead "
            "and cascade-close their supervision_threads; transition "
            "every-seat-terminal sessions to completed or dead."
        ),
    )
    dsw.add_argument(
        "--grace-seconds",
        dest="grace_seconds",
        type=int,
        default=None,
        help=(
            "Minimum age (seconds) a terminal dispatch_attempt must reach "
            "before its seat is eligible for sweeping. Defaults to "
            "runtime.core.dead_recovery.DEFAULT_GRACE_SECONDS."
        ),
    )

    # seat-release: release a seat and abandon its active supervision_threads
    # (DEC-SUPERVISION-THREADS-DOMAIN-001 continuation).  Thin adapter over
    # runtime.core.dispatch_hook.release_session_seat().
    dsr = dp_sub.add_parser(
        "seat-release",
        help=(
            "Release a session seat and abandon every active supervision_thread "
            "where it is supervisor or worker."
        ),
    )
    dsr.add_argument(
        "--session-id", dest="session_id", required=True,
        help="Orchestrator session_id for the seat being released",
    )
    dsr.add_argument(
        "--agent-type", dest="agent_type", required=True,
        help="Harness agent_type the seat was created for",
    )

    # statusline
    sl_p = subparsers.add_parser("statusline", help="Runtime-backed statusline snapshot")
    sl_sub = sl_p.add_subparsers(dest="action", required=True)
    sl_sub.add_parser("snapshot")
    sl_h = sl_sub.add_parser(
        "hygiene",
        help="Classify checkout dirt into active, baseline, ephemeral, and unexpected buckets",
    )
    sl_h.add_argument(
        "--worktree-path",
        dest="worktree_path",
        required=True,
        help="Path to the git worktree whose dirt should be classified",
    )

    # doc — hook-surface reference validation (Invariant #8,
    # DEC-DOC-REF-VALIDATION-001)
    doc_p = subparsers.add_parser(
        "doc",
        help="Markdown doc reference validation (read-only)",
    )
    doc_sub = doc_p.add_subparsers(dest="action", required=True)
    doc_ref = doc_sub.add_parser(
        "ref-check",
        help=(
            "Scan a markdown file for hook-surface references and diff "
            "them against HOOK_MANIFEST. Exit non-zero on drift."
        ),
    )
    doc_ref.add_argument("path", help="Path to the markdown file to validate")

    # trace
    tr_p = subparsers.add_parser("trace", help="Trace-lite session manifests and summaries")
    tr_sub = tr_p.add_subparsers(dest="action", required=True)

    tr_start = tr_sub.add_parser("start", help="Begin a new trace for a session")
    tr_start.add_argument("session_id")
    tr_start.add_argument(
        "--role", dest="role", default=None, help="Agent role (implementer, reviewer, planner, ...)"
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
    wf_get.add_argument(
        "--worktree-path",
        dest="worktree_path",
        default=None,
        help=(
            "Optional repo/worktree root used for DB routing when the caller is "
            "querying a workflow outside the current session repo."
        ),
    )

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

    # DEC-CLAUDEX-SCOPE-TRIAD-UNIFIED-WRITE-AUTHORITY-001: scope-sync atomically
    # writes BOTH the workflow_scope enforcement row and work_items.scope_json in
    # a single SQLite transaction, preventing the dual-write-path drift that causes
    # _validate_work_item_scope_matches_authority to fire at prompt-pack compile time.
    # This is the blessed orchestrator path; scope-set and work-item-set --scope-json
    # remain as lower-level primitives.
    wf_scope_sync = wf_sub.add_parser(
        "scope-sync",
        help=(
            "Atomically write ScopeManifest to both workflow_scope and "
            "work_items.scope_json from a single scope file "
            "(DEC-CLAUDEX-SCOPE-TRIAD-UNIFIED-WRITE-AUTHORITY-001)"
        ),
    )
    wf_scope_sync.add_argument("workflow_id")
    wf_scope_sync.add_argument(
        "--work-item-id",
        dest="work_item_id",
        required=True,
        help="work_item_id whose scope_json column will be updated (must already exist)",
    )
    wf_scope_sync.add_argument(
        "--scope-file",
        dest="scope_file",
        required=True,
        help=(
            "Path to a JSON file containing the scope triad: allowed_paths, "
            "required_paths, forbidden_paths (JSON arrays of strings), and "
            "optionally state_domains or authority_domains. Unknown keys are rejected."
        ),
    )

    wf_scope_get = wf_sub.add_parser("scope-get", help="Get scope manifest for a workflow")
    wf_scope_get.add_argument("workflow_id")

    wf_scope_check = wf_sub.add_parser("scope-check", help="Check changed files against scope")
    wf_scope_check.add_argument("workflow_id")
    wf_scope_check.add_argument("--changed", default="[]", help="JSON array of changed file paths")

    wf_stage_packet = wf_sub.add_parser(
        "stage-packet",
        help=(
            "Return the canonical execution packet for a workflow stage: "
            "dispatch contract, agent tool spec, contracts, scope, runtime state, "
            "and canonical readback command forms. workflow_id may be omitted "
            "when runtime can resolve a bound worktree context."
        ),
    )
    wf_stage_packet.add_argument(
        "workflow_id",
        nargs="?",
        default=None,
        help=(
            "Optional workflow_id. When omitted, runtime resolves the bound "
            "workflow from --worktree-path, CLAUDE_PROJECT_DIR, or the current "
            "git worktree."
        ),
    )
    wf_stage_packet.add_argument("--stage-id", dest="stage_id", required=True)
    wf_stage_packet.add_argument("--goal-id", dest="goal_id", default=None)
    wf_stage_packet.add_argument("--work-item-id", dest="work_item_id", default=None)
    wf_stage_packet.add_argument(
        "--worktree-path",
        dest="worktree_path",
        default=None,
        help="Optional worktree path used for workflow bootstrap when workflow_id is omitted",
    )
    wf_stage_packet.add_argument("--decision-scope", dest="decision_scope", default="kernel")
    wf_stage_packet.add_argument("--generated-at", dest="generated_at", type=int, default=None)

    def _add_workflow_bootstrap_args(
        parser,
        *,
        require_desired_end_state: bool,
        defaults_from_request: bool,
    ):
        parser.add_argument("workflow_id")
        parser.add_argument(
            "--desired-end-state",
            dest="desired_end_state",
            required=require_desired_end_state,
            default=None if defaults_from_request else None,
            help="Free-text description of what the initial local workflow adoption is trying to achieve",
        )
        if defaults_from_request:
            parser.add_argument(
                "--bootstrap-token",
                dest="bootstrap_token",
                required=True,
                help="One-shot token minted by `cc-policy workflow bootstrap-request`.",
            )
        parser.add_argument(
            "--title",
            default=None if defaults_from_request else "Initial planning bootstrap",
            help="Title for the initial planner work item",
        )
        parser.add_argument(
            "--goal-id",
            dest="goal_id",
            default=None if defaults_from_request else "g-initial-planning",
            help="Goal id to seed when workflow bootstrap creates the first active goal",
        )
        parser.add_argument(
            "--work-item-id",
            dest="work_item_id",
            default=None if defaults_from_request else "wi-initial-planning",
            help="Work item id to seed when workflow bootstrap creates the first in-progress planner work item",
        )
        parser.add_argument(
            "--worktree-path",
            dest="worktree_path",
            default=None,
            help="Optional path to the git worktree to bootstrap; defaults to the current git repo",
        )
        parser.add_argument(
            "--base-branch",
            dest="base_branch",
            default=None if defaults_from_request else "main",
        )
        parser.add_argument("--ticket", default=None)
        parser.add_argument("--initiative", default=None)
        parser.add_argument(
            "--autonomy-budget",
            dest="autonomy_budget",
            type=int,
            default=None if defaults_from_request else 0,
        )
        parser.add_argument(
            "--decision-scope",
            dest="decision_scope",
            default=None if defaults_from_request else "kernel",
        )
        parser.add_argument("--generated-at", dest="generated_at", type=int, default=None)

    wf_bootstrap_request = wf_sub.add_parser(
        "bootstrap-request",
        help=(
            "Mint a one-shot bootstrap token for a fresh local workflow adoption. "
            "This records explicit operator intent and returns the exact "
            "bootstrap-local command to run next."
        ),
    )
    _add_workflow_bootstrap_args(
        wf_bootstrap_request,
        require_desired_end_state=True,
        defaults_from_request=False,
    )
    wf_bootstrap_request.add_argument(
        "--requested-by",
        required=True,
        help="Human or operator identity requesting the local workflow bootstrap",
    )
    wf_bootstrap_request.add_argument(
        "--justification",
        required=True,
        help="Why this fresh workflow bootstrap is being requested",
    )
    wf_bootstrap_request.add_argument(
        "--ttl-seconds",
        dest="ttl_seconds",
        type=int,
        default=workflow_bootstrap_mod.DEFAULT_BOOTSTRAP_REQUEST_TTL_SECONDS,
        help="Lifetime of the one-shot bootstrap token before it expires",
    )

    wf_bootstrap_local = wf_sub.add_parser(
        "bootstrap-local",
        help=(
            "Consume a runtime-issued bootstrap token to bootstrap a fresh local "
            "workflow: require git identity, resolve the canonical local "
            ".claude/state.db, bind the workflow, seed the initial active goal "
            "+ in-progress planner work item, and return the canonical planner "
            "launch spec."
        ),
    )
    _add_workflow_bootstrap_args(
        wf_bootstrap_local,
        require_desired_end_state=False,
        defaults_from_request=True,
    )

    # Compatibility alias — same authority, hidden from help. This is not a
    # separate bootstrap path.
    wf_bootstrap_planner = wf_sub.add_parser("bootstrap-planner", help=argparse.SUPPRESS)
    _add_workflow_bootstrap_args(
        wf_bootstrap_planner,
        require_desired_end_state=False,
        defaults_from_request=True,
    )

    wf_sub.add_parser("list", help="List all workflow bindings")

    wf_unbind = wf_sub.add_parser(
        "unbind",
        help="Remove workflow binding row (idempotent; also drops matching scope row)",
    )
    wf_unbind.add_argument("workflow_id")

    wf_scope_unset = wf_sub.add_parser(
        "scope-unset",
        help="Remove workflow scope manifest row (idempotent; leaves binding intact)",
    )
    wf_scope_unset.add_argument("workflow_id")

    # DEC-CLAUDEX-DW-WORKFLOW-JOIN-001: workflow-scoped seeding verbs.
    # Before this slice no orchestrator-facing CLI surface existed to create a
    # goal or work_item bound to a workflow_id — callers had to reach
    # decision_work_registry through Python. The new verbs close that gap and
    # enforce the binding-exists precondition so seeds cannot be attached to
    # workflows that have no worktree/branch authority.
    wf_goal_set = wf_sub.add_parser(
        "goal-set",
        help="Create or upsert a goal scoped to a bound workflow_id",
    )
    wf_goal_set.add_argument("workflow_id")
    wf_goal_set.add_argument("goal_id")
    wf_goal_set.add_argument(
        "--desired-end-state",
        dest="desired_end_state",
        required=True,
        help="Free-text description of the goal's completion criterion",
    )
    wf_goal_set.add_argument(
        "--status",
        default="active",
        choices=sorted(["active", "awaiting_user", "complete", "blocked_external"]),
    )
    wf_goal_set.add_argument(
        "--autonomy-budget",
        dest="autonomy_budget",
        type=int,
        default=0,
        help="Integer budget of autonomous steps the goal may spend",
    )
    wf_goal_set.add_argument(
        "--continuation-rules-json",
        dest="continuation_rules_json",
        default="[]",
        help="JSON array of continuation rule strings",
    )
    wf_goal_set.add_argument(
        "--stop-conditions-json",
        dest="stop_conditions_json",
        default="[]",
        help="JSON array of stop-condition strings",
    )
    wf_goal_set.add_argument(
        "--escalation-boundaries-json",
        dest="escalation_boundaries_json",
        default="[]",
        help="JSON array of escalation-boundary strings",
    )
    wf_goal_set.add_argument(
        "--user-decision-boundaries-json",
        dest="user_decision_boundaries_json",
        default="[]",
        help="JSON array of user-decision-boundary strings",
    )

    wf_goal_get = wf_sub.add_parser(
        "goal-get",
        help="Read back a goal record by goal_id",
    )
    wf_goal_get.add_argument("goal_id")

    wf_wi_set = wf_sub.add_parser(
        "work-item-set",
        help="Create or upsert a work_item scoped to a bound workflow_id",
    )
    wf_wi_set.add_argument("workflow_id")
    wf_wi_set.add_argument("goal_id")
    wf_wi_set.add_argument("work_item_id")
    wf_wi_set.add_argument(
        "--title", required=True, help="Human-readable work-item title"
    )
    wf_wi_set.add_argument(
        "--status",
        default="in_progress",
        choices=sorted(
            [
                "pending",
                "in_progress",
                "in_review",
                "ready_to_land",
                "landed",
                "needs_changes",
                "blocked_by_plan",
                "abandoned",
            ]
        ),
    )
    wf_wi_set.add_argument("--version", type=int, default=1)
    wf_wi_set.add_argument("--author", default="planner")
    wf_wi_set.add_argument(
        "--scope-json",
        dest="scope_json",
        default="{}",
        help="JSON Scope Manifest (allowed/required/forbidden/state_domains)",
    )
    wf_wi_set.add_argument(
        "--evaluation-json",
        dest="evaluation_json",
        default="{}",
        help=(
            "JSON Evaluation Contract — 9 legal keys (DEC-CLAUDEX-EVAL-CONTRACT-SCHEMA-PARITY-001): "
            "required_tests, required_evidence, "
            "required_real_path_checks, required_authority_invariants, "
            "required_integration_points, forbidden_shortcuts, "
            "rollback_boundary, acceptance_notes, "
            "ready_for_guardian_definition. "
            "Tuple-valued keys accept JSON arrays of strings; "
            "string-valued keys accept JSON strings. "
            "Unknown keys raise ValueError at decode time."
        ),
    )
    wf_wi_set.add_argument(
        "--head-sha",
        dest="head_sha",
        default=None,
        help="Optional commit SHA the work_item currently points at",
    )
    wf_wi_set.add_argument(
        "--reviewer-round",
        dest="reviewer_round",
        type=int,
        default=0,
    )

    wf_wi_get = wf_sub.add_parser(
        "work-item-get",
        help="Read back a work_item record by work_item_id",
    )
    wf_wi_get.add_argument("work_item_id")

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
    ap_p = subparsers.add_parser(
        "approval", help="One-shot approval tokens for guarded git ops"
    )
    ap_sub = ap_p.add_subparsers(dest="action", required=True)

    ap_grant = ap_sub.add_parser(
        "grant", help="Grant one-shot approval for a guarded git op"
    )
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
    ls_issue.add_argument("role", help="Agent role (implementer, reviewer, guardian, planner)")
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
    co_route.add_argument("role", help="Completing role (reviewer, guardian, implementer, planner)")
    co_route.add_argument("verdict", help="Verdict string from the completion record")

    # critic-review
    cr_p = subparsers.add_parser(
        "critic-review",
        help="Persist and query implementer critic reviews that drive inner-loop routing",
    )
    cr_sub = cr_p.add_subparsers(dest="action", required=True)

    cr_submit = cr_sub.add_parser("submit", help="Record a critic verdict")
    cr_submit.add_argument("--workflow-id", dest="workflow_id", required=True)
    cr_submit.add_argument("--lease-id", dest="lease_id", default="")
    cr_submit.add_argument("--role", default="implementer")
    cr_submit.add_argument("--provider", default="codex")
    cr_submit.add_argument("--verdict", required=True)
    cr_submit.add_argument("--summary", default="")
    cr_submit.add_argument("--detail", default="")
    cr_submit.add_argument("--fingerprint", default="")
    cr_submit.add_argument("--project-root", dest="project_root", default="")
    cr_submit.add_argument(
        "--metadata",
        default="{}",
        help="JSON object with hook/runtime metadata for this critic run",
    )

    cr_latest = cr_sub.add_parser("latest", help="Return the most recent critic review")
    cr_latest.add_argument("--workflow-id", dest="workflow_id", default=None)
    cr_latest.add_argument("--lease-id", dest="lease_id", default=None)
    cr_latest.add_argument("--role", default="implementer")

    cr_list = cr_sub.add_parser("list", help="List critic reviews")
    cr_list.add_argument("--workflow-id", dest="workflow_id", default=None)
    cr_list.add_argument("--lease-id", dest="lease_id", default=None)
    cr_list.add_argument("--role", default=None)
    cr_list.add_argument("--limit", type=int, default=None)

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

    # evaluate — policy evaluation (default: JSON from stdin) or STFP quick gate
    #
    # ``cc-policy evaluate``         — existing behavior: read JSON from stdin,
    #                                  evaluate against all registered policies.
    # ``cc-policy evaluate quick``   — STFP scope gate: validate working-tree diff
    #                                  and write evaluation_state=ready_for_guardian.
    #
    # The subparser is optional (required=False) so ``cc-policy evaluate`` with no
    # subcommand continues to work for the hooks that pipe JSON to it.
    eval_gate_p = subparsers.add_parser(
        "evaluate",
        help="Evaluate a hook event against all registered policies (JSON on stdin), "
        "or run STFP quick-eval gate (subcommand: quick)",
    )
    eval_gate_sub = eval_gate_p.add_subparsers(dest="action", required=False)
    eq_p = eval_gate_sub.add_parser(
        "quick",
        help="STFP scope gate: validate working-tree diff, write evaluation_state=ready_for_guardian",
    )
    eq_p.add_argument(
        "--project-root",
        dest="project_root",
        default=None,
        help="Path to git repo root (defaults to CLAUDE_PROJECT_DIR or git root of cwd)",
    )
    eq_p.add_argument(
        "--workflow-id",
        dest="workflow_id",
        default=None,
        help="Workflow ID for evaluation_state row (defaults to 'stfp-quick')",
    )

    # context — canonical identity resolution for hooks
    ctx_p = subparsers.add_parser("context", help="Resolve current actor identity from runtime")
    ctx_sub = ctx_p.add_subparsers(dest="action", required=True)
    ctx_sub.add_parser(
        "role",
        help=(
            "Return {role, agent_id, workflow_id} resolved via lease -> marker -> env var. "
            "Used by SubagentStop hooks to get the stopping agent's identity."
        ),
    )
    cap_contract_p = ctx_sub.add_parser(
        "capability-contract",
        help="Return the capability contract for a stage as JSON (read-only projection).",
    )
    cap_contract_p.add_argument(
        "--stage",
        required=True,
        help="Stage identifier (e.g. 'planner', 'reviewer', 'guardian:land') or live alias (e.g. 'Plan').",
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

    # scratchlane — task-local artifact roots under tmp/.claude-scratch/<task>
    sl_p = subparsers.add_parser(
        "scratchlane",
        help="Task-local scratchlane permits under tmp/.claude-scratch/",
    )
    sl_sub = sl_p.add_subparsers(dest="action", required=True)
    _sl_root_kwargs = {
        "dest": "project_root",
        "default": None,
        "help": "Project root (defaults to CLAUDE_PROJECT_DIR or git root)",
    }

    sl_grant = sl_sub.add_parser("grant", help="Grant or refresh a scratchlane permit")
    sl_grant.add_argument("--task-slug", dest="task_slug", required=True)
    sl_grant.add_argument("--granted-by", dest="granted_by", default="user")
    sl_grant.add_argument("--note", dest="note", default="")
    sl_grant.add_argument("--project-root", **_sl_root_kwargs)

    sl_get = sl_sub.add_parser("get", help="Get the active scratchlane permit for a task")
    sl_get.add_argument("--task-slug", dest="task_slug", required=True)
    sl_get.add_argument("--project-root", **_sl_root_kwargs)

    sl_revoke = sl_sub.add_parser("revoke", help="Revoke the active scratchlane permit")
    sl_revoke.add_argument("--task-slug", dest="task_slug", required=True)
    sl_revoke.add_argument("--project-root", **_sl_root_kwargs)

    sl_list = sl_sub.add_parser("list", help="List active scratchlane permits")
    sl_list.add_argument("--project-root", **_sl_root_kwargs)

    # eval — Behavioral Evaluation Framework CLI
    ev_p = subparsers.add_parser("eval", help="Behavioral Evaluation Framework")
    ev_sub = ev_p.add_subparsers(dest="action", required=True)

    # eval run
    ev_run = ev_sub.add_parser("run", help="Discover and run eval scenarios")
    ev_run.add_argument(
        "--category",
        default=None,
        help="Filter by category: gate | judgment | adversarial",
    )
    ev_run.add_argument(
        "--mode",
        default=None,
        help="Execution mode: deterministic | live (default: deterministic)",
    )
    ev_run.add_argument(
        "--live",
        action="store_true",
        default=False,
        help="Shorthand for --mode live",
    )
    ev_run.add_argument(
        "--scenarios-dir",
        dest="scenarios_dir",
        default=None,
        help="Path to scenarios directory (default: <repo_root>/evals/scenarios)",
    )
    ev_run.add_argument(
        "--fixtures-dir",
        dest="fixtures_dir",
        default=None,
        help="Path to fixtures directory (default: <repo_root>/evals/fixtures)",
    )

    # eval report
    ev_report = ev_sub.add_parser("report", help="Generate a report for an eval run")
    ev_report.add_argument(
        "--run-id",
        dest="run_id",
        default=None,
        help="UUID of the run to report on (default: most recent)",
    )
    ev_report.add_argument(
        "--last",
        type=int,
        default=1,
        help="Number of recent runs to include (reserved, currently unused)",
    )
    ev_report.add_argument(
        "--json",
        dest="as_json",
        action="store_true",
        default=False,
        help="Output machine-readable JSON instead of text",
    )

    # eval list
    ev_list = ev_sub.add_parser("list", help="List available eval scenarios")
    ev_list.add_argument(
        "--category",
        default=None,
        help="Filter by category: gate | judgment | adversarial",
    )
    ev_list.add_argument(
        "--mode",
        default=None,
        help="Filter by mode: deterministic | live",
    )
    ev_list.add_argument(
        "--scenarios-dir",
        dest="scenarios_dir",
        default=None,
        help="Path to scenarios directory (default: <repo_root>/evals/scenarios)",
    )

    # eval score
    ev_score = ev_sub.add_parser("score", help="Re-score a previous eval run from stored outputs")
    ev_score.add_argument("--run-id", dest="run_id", required=True, help="UUID of the run to score")

    # obs — observatory metrics, suggestions, and analysis (W-OBS-1)
    obs_p = subparsers.add_parser("obs", help="Observatory metrics and suggestions (W-OBS-1)")
    obs_sub = obs_p.add_subparsers(dest="action", required=True)

    obs_emit = obs_sub.add_parser("emit", help="Emit a single metric row")
    obs_emit.add_argument("name", help="Metric name (e.g. agent_duration_s)")
    obs_emit.add_argument("value", type=float, help="Scalar metric value")
    obs_emit.add_argument("--labels", default=None, help="JSON object of label key/value pairs")
    obs_emit.add_argument("--session-id", dest="session_id", default=None)
    obs_emit.add_argument("--role", default=None, help="Agent role (implementer, reviewer, ...)")

    obs_sub.add_parser(
        "emit-batch",
        help="Insert multiple metrics from a JSON array on stdin",
    )

    obs_query = obs_sub.add_parser("query", help="Query obs_metrics with optional filters")
    obs_query.add_argument("name", help="Metric name to query")
    obs_query.add_argument("--since", type=int, default=None, help="Epoch lower bound (inclusive)")
    obs_query.add_argument("--until", type=int, default=None, help="Epoch upper bound (inclusive)")
    obs_query.add_argument(
        "--labels-filter", dest="labels_filter", default=None, help="JSON object for label filters"
    )
    obs_query.add_argument("--role", default=None, help="Filter by agent role")
    obs_query.add_argument("--limit", type=int, default=100)

    obs_suggest = obs_sub.add_parser("suggest", help="Create a new improvement suggestion")
    obs_suggest.add_argument("category", help="Suggestion category")
    obs_suggest.add_argument("title", help="Short title for the suggestion")
    obs_suggest.add_argument("--body", default=None, help="Detailed description")
    obs_suggest.add_argument("--target-metric", dest="target_metric", default=None)
    obs_suggest.add_argument("--baseline", type=float, default=None)
    obs_suggest.add_argument("--signal-id", dest="signal_id", default=None)
    obs_suggest.add_argument("--source-session", dest="source_session", default=None)

    obs_accept = obs_sub.add_parser("accept", help="Accept a suggestion by id")
    obs_accept.add_argument("id", type=int)
    obs_accept.add_argument("--measure-after", dest="measure_after", type=int, default=None)

    obs_reject = obs_sub.add_parser("reject", help="Reject a suggestion by id")
    obs_reject.add_argument("id", type=int)
    obs_reject.add_argument("--reason", default=None)

    obs_defer = obs_sub.add_parser("defer", help="Defer a suggestion by id")
    obs_defer.add_argument("id", type=int)
    obs_defer.add_argument("--reassess-after", dest="reassess_after", type=int, default=5)

    obs_ba = obs_sub.add_parser("batch-accept", help="Accept all proposed suggestions in category")
    obs_ba.add_argument("category")

    obs_sub.add_parser("converge", help="Measure accepted suggestions past their measure_after")

    obs_cleanup = obs_sub.add_parser("cleanup", help="Delete stale metrics and suggestions")
    obs_cleanup.add_argument("--metrics-ttl-days", dest="metrics_ttl_days", type=int, default=30)
    obs_cleanup.add_argument(
        "--suggestions-ttl-days", dest="suggestions_ttl_days", type=int, default=90
    )

    obs_sub.add_parser("status", help="Return high-level observatory status")
    obs_sub.add_parser("summary", help="Run full analysis and record an obs_run")

    # agent-session — agent_sessions domain authority
    # (DEC-AGENT-SESSION-DOMAIN-001).  Read/transition surface over the
    # runtime-owned session state machine.  Session creation is NOT
    # exposed here: sessions are bootstrapped exclusively through
    # dispatch_hook.ensure_session_and_seat (PreToolUse:Agent path).
    as_p = subparsers.add_parser(
        "agent-session",
        help="Agent-session lifecycle + query authority",
    )
    as_sub = as_p.add_subparsers(dest="action", required=True)

    as_get = as_sub.add_parser("get", help="Fetch an agent_sessions row by id")
    as_get.add_argument("--session-id", dest="session_id", required=True)

    as_mc = as_sub.add_parser(
        "mark-completed", help="Transition an active session to completed"
    )
    as_mc.add_argument("--session-id", dest="session_id", required=True)

    as_md = as_sub.add_parser(
        "mark-dead", help="Transition an active session to dead"
    )
    as_md.add_argument("--session-id", dest="session_id", required=True)

    as_mo = as_sub.add_parser(
        "mark-orphaned", help="Transition an active session to orphaned"
    )
    as_mo.add_argument("--session-id", dest="session_id", required=True)

    as_la = as_sub.add_parser(
        "list-active",
        help="List every active session (optionally filtered by workflow_id)",
    )
    as_la.add_argument("--workflow-id", dest="workflow_id", default=None)

    # seat — seats domain authority (DEC-SEAT-DOMAIN-001).  Read/transition
    # surface over the runtime-owned seat state machine.  Seat creation is
    # NOT exposed here: seats are bootstrapped exclusively through
    # dispatch_hook.ensure_session_and_seat (PreToolUse:Agent path).
    seat_p = subparsers.add_parser(
        "seat",
        help="Seat lifecycle + query authority",
    )
    seat_sub = seat_p.add_subparsers(dest="action", required=True)

    seat_get = seat_sub.add_parser("get", help="Fetch a seat row by id")
    seat_get.add_argument("--seat-id", dest="seat_id", required=True)

    seat_rel = seat_sub.add_parser(
        "release", help="Transition an active seat to released"
    )
    seat_rel.add_argument("--seat-id", dest="seat_id", required=True)

    seat_dead = seat_sub.add_parser(
        "mark-dead", help="Transition a seat (from active or released) to dead"
    )
    seat_dead.add_argument("--seat-id", dest="seat_id", required=True)

    seat_lfs = seat_sub.add_parser(
        "list-for-session",
        help="List seats for a session (optionally filtered by status)",
    )
    seat_lfs.add_argument("--session-id", dest="session_id", required=True)
    seat_lfs.add_argument("--status", dest="status", default=None)

    seat_sub.add_parser(
        "list-active", help="List every seat whose status is active"
    )

    # supervision — supervision_threads domain authority
    # (DEC-SUPERVISION-THREADS-DOMAIN-001). Runtime-owned CRUD + state queries
    # for recursive-supervision relationships between seats.
    sup_p = subparsers.add_parser(
        "supervision",
        help="Supervision-thread relationships between seats",
    )
    sup_sub = sup_p.add_subparsers(dest="action", required=True)

    sup_attach = sup_sub.add_parser(
        "attach", help="Create a new active supervision_thread row"
    )
    sup_attach.add_argument("--supervisor-seat-id", dest="supervisor_seat_id", required=True)
    sup_attach.add_argument("--worker-seat-id", dest="worker_seat_id", required=True)
    sup_attach.add_argument(
        "--thread-type",
        dest="thread_type",
        required=True,
        help="One of SUPERVISION_THREAD_TYPES",
    )

    sup_detach = sup_sub.add_parser(
        "detach", help="Transition an active thread to completed"
    )
    sup_detach.add_argument("--thread-id", dest="thread_id", required=True)

    sup_abandon = sup_sub.add_parser(
        "abandon", help="Transition an active thread to abandoned (supervisor died)"
    )
    sup_abandon.add_argument("--thread-id", dest="thread_id", required=True)

    sup_get = sup_sub.add_parser("get", help="Fetch a supervision_thread row by id")
    sup_get.add_argument("--thread-id", dest="thread_id", required=True)

    sup_lfs = sup_sub.add_parser(
        "list-for-supervisor",
        help="List threads owned by a supervisor seat (optionally filtered by status)",
    )
    sup_lfs.add_argument("--supervisor-seat-id", dest="supervisor_seat_id", required=True)
    sup_lfs.add_argument("--status", dest="status", default=None)

    sup_lfw = sup_sub.add_parser(
        "list-for-worker",
        help="List threads targeting a worker seat (optionally filtered by status)",
    )
    sup_lfw.add_argument("--worker-seat-id", dest="worker_seat_id", required=True)
    sup_lfw.add_argument("--status", dest="status", default=None)

    sup_lses = sup_sub.add_parser(
        "list-for-session",
        help="List threads whose supervisor or worker seat belongs to a session",
    )
    sup_lses.add_argument("--agent-session-id", dest="agent_session_id", required=True)
    sup_lses.add_argument("--status", dest="status", default=None)

    sup_lst = sup_sub.add_parser(
        "list-for-seat",
        help="List threads where a seat appears as supervisor or worker",
    )
    sup_lst.add_argument("--seat-id", dest="seat_id", required=True)
    sup_lst.add_argument("--status", dest="status", default=None)

    sup_afs = sup_sub.add_parser(
        "abandon-for-seat",
        help="Abandon every active thread where a seat is supervisor or worker",
    )
    sup_afs.add_argument("--seat-id", dest="seat_id", required=True)

    sup_afses = sup_sub.add_parser(
        "abandon-for-session",
        help="Abandon every active thread touching a session (either side)",
    )
    sup_afses.add_argument("--agent-session-id", dest="agent_session_id", required=True)

    sup_sub.add_parser(
        "list-active", help="List every supervision_thread whose status is active"
    )

    # config — enforcement toggle authority (DEC-CONFIG-AUTHORITY-001)
    config_p = subparsers.add_parser(
        "config", help="Enforcement config: get/set/list toggle values"
    )
    config_sub = config_p.add_subparsers(dest="action", required=True)

    cfg_get = config_sub.add_parser("get", help="Look up a config value (scope-precedence)")
    cfg_get.add_argument("key", help="Config key, e.g. review_gate_regular_stop")
    cfg_get.add_argument(
        "--workflow-id",
        dest="workflow_id",
        default="",
        help="Narrow lookup to workflow scope",
    )
    cfg_get.add_argument(
        "--project-root",
        dest="project_root",
        default="",
        help="Narrow lookup to project scope",
    )
    cfg_get.add_argument(
        "--scope",
        dest="scope",
        default=None,
        help="(unused by get, kept for symmetry)",
    )

    cfg_set = config_sub.add_parser("set", help="Write a config value (guardian role required)")
    cfg_set.add_argument("key", help="Config key")
    cfg_set.add_argument("value", help="Config value (string-encoded)")
    cfg_set.add_argument(
        "--scope",
        dest="scope",
        default="global",
        help="Scope: global | project=<root> | workflow=<id>",
    )

    cfg_list = config_sub.add_parser("list", help="List all enforcement_config rows")
    cfg_list.add_argument(
        "--scope",
        dest="scope",
        default=None,
        help="Filter to a specific scope",
    )

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
    if args.domain == "evaluation":
        return _handle_evaluation(args)
    if args.domain == "marker":
        return _handle_marker(args)
    if args.domain == "event":
        return _handle_event(args)
    if args.domain == "hook":
        return _handle_hook(args)
    if args.domain == "bridge":
        return _handle_bridge(args)
    if args.domain == "constitution":
        return _handle_constitution(args)
    if args.domain == "decision":
        return _handle_decision(args)
    if args.domain == "doc":
        return _handle_doc(args)
    if args.domain == "prompt-pack":
        return _handle_prompt_pack(args)
    if args.domain == "shadow":
        return _handle_shadow(args)
    if args.domain == "worktree":
        return _handle_worktree(args)
    if args.domain == "lifecycle":
        return _handle_lifecycle(args)
    if args.domain == "dispatch":
        return _handle_dispatch(args)
    if args.domain == "agent-session":
        return _handle_agent_session(args)
    if args.domain == "seat":
        return _handle_seat(args)
    if args.domain == "supervision":
        return _handle_supervision(args)
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
    if args.domain == "critic-review":
        return _handle_critic_review(args)
    if args.domain == "test-state":
        return _handle_test_state(args)
    if args.domain == "scratchlane":
        return _handle_scratchlane(args)
    if args.domain == "eval":
        return _handle_eval(args)
    if args.domain == "evaluate":
        # Route evaluate quick to the STFP scope gate; all other invocations
        # (no subcommand) use the existing stdin policy-evaluation handler.
        if getattr(args, "action", None) == "quick":
            return _handle_evaluate_quick(args)
        return _handle_evaluate(args)
    if args.domain == "context":
        return _handle_context(args)
    if args.domain == "policy":
        return _handle_policy(args)
    if args.domain == "obs":
        return _handle_obs(args)
    if args.domain == "config":
        return _handle_config(args)

    return _err(f"unknown domain: {args.domain}")


if __name__ == "__main__":
    raise SystemExit(main())
