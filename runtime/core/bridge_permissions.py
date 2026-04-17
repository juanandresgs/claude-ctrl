"""ClauDEX bridge permission surface authority (shadow-only).

@decision DEC-CLAUDEX-BRIDGE-PERMISSIONS-001
Title: runtime/core/bridge_permissions.py is the sole declarative authority for the bridge permission surface
Status: proposed (shadow-mode, cc-policy-who-remediation Slice 1)
Rationale: The ClauDEX bridge (ClauDEX/bridge/claude-settings.json) previously
  contained explicit ``permissions.deny`` entries for git landing operations
  (commit, push, merge, rebase, reset). Those entries blocked the Claude Code
  permission layer **before** the runtime policy engine ever ran, making
  ``runtime/core/policies/bash_git_who.py`` (``CAN_LAND_GIT`` / ``bash_git_who``
  policy; DEC-WHO-LANDING-001) unreachable for those 5 patterns.

  This module establishes a declarative authority for the bridge permission
  surface following the same shadow-only pattern as ``hook_manifest.py``
  (DEC-CLAUDEX-HOOK-MANIFEST-001):

    * It declares which Bash patterns MUST NOT appear in
      ``permissions.deny`` because they are delegated to runtime policy.
    * It declares which patterns MAY remain in ``permissions.deny`` as
      true-unrecoverable safety denies (destructive / secret-read ops
      that must never be allowed even by runtime policy).
    * It declares the required ``PreToolUse Bash → pre-bash.sh`` hook
      wiring that gates runtime policy evaluation.
    * It provides a pure ``validate_bridge_settings`` function that
      returns drift messages when the live bridge file diverges from
      these declarations.

  Cross-references:
    * DEC-CLAUDEX-HOOK-MANIFEST-001 — same shadow-only pattern.
    * DEC-WHO-LANDING-001 — the now-reachable runtime landing authority
      that enforces ``CAN_LAND_GIT`` after this slice removes the
      bridge-layer denies.

  Shadow-only discipline (same as hook_manifest.py):
    * stdlib imports only: ``dataclasses``, ``pathlib.PurePosixPath``,
      ``typing``, ``json``, ``re``.
    * No import from any other ``runtime.core`` module.
    * No side effects at import time.
    * Pure function surface only — no filesystem writes, no subprocess.

  Public contract:
    * ``RUNTIME_POLICY_DELEGATED_BASH_PATTERNS`` — frozenset of Bash
      permission patterns that MUST NOT appear in ``permissions.deny``.
      These are delegated to ``pre-bash.sh`` → ``cc-policy evaluate``
      (the runtime policy engine path).
    * ``SAFETY_DENY_PATTERNS`` — frozenset of Bash patterns that MAY
      appear in ``permissions.deny``. These represent true-unrecoverable
      destructive or secret-exposure operations that runtime policy does
      not override.
    * ``REQUIRED_PRETOOL_BASH_HOOKS`` — list of required ``PreToolUse``
      Bash hook wiring shapes. The bridge must contain at least one
      ``PreToolUse`` entry with ``matcher == "Bash"`` whose ``hooks``
      list includes a command ending with ``hooks/pre-bash.sh``.
    * ``REQUIRED_POSTTOOL_BASH_HOOKS`` — list of required ``PostToolUse``
      Bash hook wiring shapes. The bridge must contain at least one
      ``PostToolUse`` entry with ``matcher == "Bash"`` whose ``hooks``
      list includes a command ending with ``hooks/post-bash.sh``.
      This extension closes the bridge-parity gap for Invariant #15
      (readiness-invalidation on shell-mutation); cross-ref
      DEC-EVAL-006 + CUTOVER_PLAN.md:1453.
    * ``validate_bridge_settings(settings)`` — pure drift validator.
      Returns an empty list on clean, non-empty list of drift messages
      on violation.
"""

from __future__ import annotations

import json
import os
import re
from dataclasses import asdict, dataclass, field
from pathlib import Path, PurePosixPath
from typing import Any, Dict, FrozenSet, List, Optional, Tuple

# ---------------------------------------------------------------------------
# Runtime-policy-delegated Bash patterns
#
# These patterns MUST NOT appear in permissions.deny. They correspond to git
# landing operations that are governed by runtime/core/policies/bash_git_who.py
# (CAN_LAND_GIT capability gate, DEC-WHO-LANDING-001). Placing them in the
# bridge deny list short-circuits the policy engine, making the runtime
# authority unreachable.
#
# Invariant: any entry in this set that also appears in the bridge
# permissions.deny is a drift violation. Tests pin this invariant against the
# live bridge file.
# ---------------------------------------------------------------------------

RUNTIME_POLICY_DELEGATED_BASH_PATTERNS: FrozenSet[str] = frozenset(
    {
        "Bash(git commit *)",
        "Bash(git push *)",
        "Bash(git merge *)",
        "Bash(git rebase *)",
        "Bash(git reset *)",
    }
)

# ---------------------------------------------------------------------------
# Safety deny patterns
#
# These patterns MAY appear (and should be present) in permissions.deny.
# They represent truly unrecoverable operations — branch deletion, force
# checkout of protected branches, recursive delete, and secret-file reads —
# that the runtime policy engine intentionally does not override. Their
# presence in the bridge deny list is correct behavior, not drift.
#
# Note: ``Bash(git checkout main*)`` and ``Bash(git checkout master*)``
# cover checkout of protected branches and are distinct from the landing
# operations above. Landing operations (commit/push/merge/rebase/reset) are
# delegated to the runtime policy engine; checkout of main/master remains a
# hard deny at the permission layer.
# ---------------------------------------------------------------------------

SAFETY_DENY_PATTERNS: FrozenSet[str] = frozenset(
    {
        "NotebookEdit",
        "Bash(git checkout main*)",
        "Bash(git checkout master*)",
        "Bash(git branch -D *)",
        "Bash(rm -rf *)",
        "Read(**/.env*)",
        "Read(**/secrets/**)",
        "Read(**/*credentials*)",
    }
)

# ---------------------------------------------------------------------------
# Required PreToolUse Bash hook wiring
#
# The bridge must contain a PreToolUse entry with matcher "Bash" whose hooks
# list includes a command containing "hooks/pre-bash.sh". This is the
# wiring that routes Bash tool calls through the runtime policy engine so
# RUNTIME_POLICY_DELEGATED_BASH_PATTERNS are evaluated at runtime rather
# than short-circuited at the permission layer.
#
# Stored as a tuple of (event, matcher, adapter_path_suffix) so the
# validator can check the wiring without knowing the exact command prefix
# ($HOME/.claude vs $(git rev-parse --show-toplevel)).
# ---------------------------------------------------------------------------

REQUIRED_PRETOOL_BASH_HOOKS: Tuple[Tuple[str, str, str], ...] = (
    # (event, matcher, adapter_path_suffix)
    ("PreToolUse", "Bash", "hooks/pre-bash.sh"),
)

# ---------------------------------------------------------------------------
# Required PostToolUse Bash hook wiring
#
# This extension closes the bridge-parity gap for Invariant #15
# (eval-readiness invalidation on shell-mutation). The root settings.json
# already wires PostToolUse Bash → post-bash.sh (landed in prior slice).
# Without a matching entry in the bridge overlay, live bridge worker sessions
# launched via scripts/claudex-claude-launch.sh would silently skip the
# post-bash.sh adapter, leaving the readiness-invalidation invariant
# unenforced on the bridge surface.
#
# Cross-references:
#   * DEC-EVAL-006 — readiness-invalidation invariant definition
#   * CUTOVER_PLAN.md:1453 — bridge-parity gap tracked here
#   * REQUIRED_PRETOOL_BASH_HOOKS above — same tuple shape
# ---------------------------------------------------------------------------

REQUIRED_POSTTOOL_BASH_HOOKS: Tuple[Tuple[str, str, str], ...] = (
    # (event, matcher, adapter_path_suffix)
    ("PostToolUse", "Bash", "hooks/post-bash.sh"),
)

# ---------------------------------------------------------------------------
# Pure drift validator
# ---------------------------------------------------------------------------


def validate_bridge_settings(settings: dict) -> List[str]:
    """Validate a bridge settings dict against the declared permission surface.

    Parameters
    ----------
    settings:
        A dict parsed from a bridge ``claude-settings.json`` file.

    Returns
    -------
    list[str]
        An empty list when the settings are consistent with the declared
        authority. A non-empty list of human-readable drift messages when
        violations are found. Callers should treat any non-empty return as
        a drift error.

    This function is pure: it reads ``settings`` in memory only, performs no
    filesystem access, and raises no exceptions on malformed input (malformed
    input produces a drift message instead).
    """
    messages: List[str] = []

    if not isinstance(settings, dict):
        messages.append(
            f"bridge settings: expected a JSON object, got {type(settings).__name__}"
        )
        return messages

    permissions = settings.get("permissions", {})
    if not isinstance(permissions, dict):
        messages.append(
            "bridge settings: 'permissions' key is not a JSON object"
        )
        return messages

    deny_list = permissions.get("deny", [])
    if not isinstance(deny_list, list):
        messages.append(
            "bridge settings: 'permissions.deny' is not a JSON array"
        )
        return messages

    deny_set: FrozenSet[str] = frozenset(
        entry for entry in deny_list if isinstance(entry, str)
    )

    # -----------------------------------------------------------------------
    # Check 1: Delegated patterns must NOT appear in deny
    # -----------------------------------------------------------------------
    rogue_denies = RUNTIME_POLICY_DELEGATED_BASH_PATTERNS & deny_set
    for pattern in sorted(rogue_denies):
        messages.append(
            f"bridge permissions.deny contains runtime-policy-delegated pattern "
            f"{pattern!r} — remove it so the runtime policy engine (bash_git_who) "
            f"can evaluate this operation. (DEC-CLAUDEX-BRIDGE-PERMISSIONS-001)"
        )

    # -----------------------------------------------------------------------
    # Check 2: Safety deny patterns MUST appear in deny
    # -----------------------------------------------------------------------
    missing_safety = SAFETY_DENY_PATTERNS - deny_set
    for pattern in sorted(missing_safety):
        messages.append(
            f"bridge permissions.deny is missing required safety pattern "
            f"{pattern!r} — this pattern protects against unrecoverable "
            f"destructive or secret-exposure operations and must remain present. "
            f"(DEC-CLAUDEX-BRIDGE-PERMISSIONS-001)"
        )

    # -----------------------------------------------------------------------
    # Check 3: Required hook wirings (PreToolUse + PostToolUse)
    #
    # Walk REQUIRED_PRETOOL_BASH_HOOKS and REQUIRED_POSTTOOL_BASH_HOOKS
    # together so the same traversal logic covers both events.
    # -----------------------------------------------------------------------
    hooks_block = settings.get("hooks", {})
    if not isinstance(hooks_block, dict):
        messages.append(
            "bridge settings: 'hooks' key is not a JSON object — "
            "PreToolUse/PostToolUse Bash wiring cannot be verified"
        )
        return messages

    _all_required_hooks = REQUIRED_PRETOOL_BASH_HOOKS + REQUIRED_POSTTOOL_BASH_HOOKS
    for event, matcher, adapter_suffix in _all_required_hooks:
        found = False
        event_entries = hooks_block.get(event, [])
        if not isinstance(event_entries, list):
            pass  # not found — fall through to error
        else:
            for block in event_entries:
                if not isinstance(block, dict):
                    continue
                block_matcher = block.get("matcher", "")
                if block_matcher != matcher:
                    continue
                hooks_in_block = block.get("hooks", [])
                if not isinstance(hooks_in_block, list):
                    continue
                for hook in hooks_in_block:
                    if not isinstance(hook, dict):
                        continue
                    cmd = hook.get("command", "")
                    if isinstance(cmd, str) and adapter_suffix in cmd:
                        found = True
                        break
                if found:
                    break
        if not found:
            messages.append(
                f"bridge settings: required {event} {matcher!r} hook wiring "
                f"to {adapter_suffix!r} is missing — {adapter_suffix} must be "
                f"wired so that the corresponding adapter is reachable for Bash "
                f"tool calls. (DEC-CLAUDEX-BRIDGE-PERMISSIONS-001)"
            )

    return messages


# ---------------------------------------------------------------------------
# Read-only broker-health + response-surface drift probes
# ---------------------------------------------------------------------------
# Added 2026-04-17 under the cc-policy-who-remediation cutover lane after the
# lane-seat diagnostic classified the long-running `waiting_for_codex`
# response-surface drift as `broker_or_cache_surface_mismatch`, sub-class
# `degraded_dead_pid_stale_socket` (HIGH confidence; env-divergence ruled
# out). These helpers make that classification surfacable via CLI so
# downstream supervisors and runbooks can distinguish broker-health drift
# from real response-delivery failures without re-running the manual
# forensic walk.
#
# Contract:
#   * Pure read-only: no filesystem writes, no subprocess spawn, no
#     runtime-DB writes.
#   * Fail-closed: missing on-disk artifacts produce a classified JSON
#     status, never a Python traceback. Only uncaught internal exceptions
#     should reach the CLI error path.
#   * State-gating nuance: `pending-review.json` is written when the run
#     enters `waiting_for_codex` and may be ABSENT during `inflight`.
#     Consumers MUST treat absence-during-inflight as a non-error
#     (`pending_absent_inflight_ok`).
#
# @decision-ref DEC-CLAUDEX-BRIDGE-PERMISSIONS-001 (same authority module;
# these probes are co-located shadow-only helpers, not a new authority).
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class BrokerHealthSnapshot:
    """Snapshot of broker daemon health at one point in time.

    ``status`` classification:

    * ``healthy`` — pidfile exists, process is alive, socket exists.
    * ``degraded_dead_pid_stale_socket`` — pidfile exists with a pid that
      does not resolve to a live process, AND the socket file still exists
      on disk. This is the dominant drift class observed 2026-04-17.
    * ``socket_missing`` — pidfile exists with a live pid, but the socket
      file is absent. (Not expected in practice; included for coverage.)
    * ``absent`` — no pidfile (broker never started, was torn down cleanly,
      or paths point at a non-existent braid root).
    """

    status: str
    braid_root: str
    pidfile_path: str
    socket_path: str
    braidd_pid: Optional[int]
    pid_alive: Optional[bool]
    socket_exists: bool
    recovery_hint: Optional[str]
    error_detail: Optional[str] = None

    def to_json_dict(self) -> Dict[str, Any]:
        return asdict(self)


@dataclass(frozen=True)
class ResponseSurfaceDiagnostic:
    """Classification of response-surface drift for a specific run id.

    ``status`` classification (authoritative set, checked in this order):

    * ``run_id_mismatch`` — caller passed a run_id that does not match the
      active run sentinel; the comparison is structurally invalid.
    * ``insufficient_evidence`` — target run directory missing or
      status.json unreadable; caller cannot trust any derived answer.
    * ``broker_cache_miss_stale_socket`` — broker health is
      ``degraded_dead_pid_stale_socket`` AND the lane-local
      ``pending-review.json`` reports a response is available with a
      readable response path. This is the 2026-04-17 classified drift.
    * ``pending_absent_inflight_ok`` — ``pending-review.json`` is absent
      while ``status.json.state == "inflight"``. Expected per state-gating;
      not a drift.
    * ``pending_absent_unexpected`` — ``pending-review.json`` is absent
      while ``status.json.state == "waiting_for_codex"``. Real drift.
    * ``agreed`` — ``pending-review.json`` is present, readable, run_id
      matches, broker is ``healthy``. Nothing to flag.
    """

    status: str
    run_id: str
    active_run_id: Optional[str]
    run_state: Optional[str]
    broker_health: Dict[str, Any]
    pending_review: Dict[str, Any]
    cursor: Dict[str, Any]
    env: Dict[str, Any]
    error_detail: Optional[str] = None

    def to_json_dict(self) -> Dict[str, Any]:
        return asdict(self)


def _resolve_braid_root(
    braid_root: Optional[str] = None,
) -> Path:
    """Resolve the BRAID_ROOT path from an explicit arg or the env.

    Returns a ``Path`` (not required to exist). The caller decides what to
    do when the resolved path is absent.
    """
    if braid_root:
        return Path(braid_root)
    env_value = os.environ.get("BRAID_ROOT")
    if env_value:
        return Path(env_value)
    # Fallback: empty path; absent-status will be surfaced by the probe.
    return Path("")


def _resolve_state_dir(
    state_dir: Optional[str] = None,
) -> Path:
    """Resolve ``$CLAUDEX_STATE_DIR`` from an explicit arg or the env."""
    if state_dir:
        return Path(state_dir)
    env_value = os.environ.get("CLAUDEX_STATE_DIR")
    if env_value:
        return Path(env_value)
    return Path("")


def _check_pid_alive(pid: int) -> Tuple[Optional[bool], Optional[str]]:
    """Return ``(alive, error_detail)``.

    Uses ``os.kill(pid, 0)`` — POSIX semantics: success means the process
    exists and the caller has permission to signal it. ``ProcessLookupError``
    means the process does not exist. ``PermissionError`` means the process
    exists but the caller cannot signal it (we treat that as alive because
    the process IS running; we just lack permission). Other ``OSError``
    values are unexpected and surface via ``error_detail`` with
    ``alive=None``.
    """
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False, None
    except PermissionError:
        return True, None
    except OSError as exc:
        return None, f"os.kill({pid}, 0) raised {type(exc).__name__}: {exc}"
    return True, None


def probe_broker_health(
    braid_root: Optional[str] = None,
) -> BrokerHealthSnapshot:
    """Return a frozen ``BrokerHealthSnapshot`` for the bridge broker.

    Pure read-only. Never raises on missing artifacts; classifies as
    ``absent`` instead.
    """
    root = _resolve_braid_root(braid_root)
    pidfile_path = root / "runs" / "braidd.pid"
    socket_path = root / "runs" / "braidd.sock"

    pidfile_exists = pidfile_path.is_file()
    socket_exists = socket_path.exists()

    if not pidfile_exists:
        return BrokerHealthSnapshot(
            status="absent",
            braid_root=str(root),
            pidfile_path=str(pidfile_path),
            socket_path=str(socket_path),
            braidd_pid=None,
            pid_alive=None,
            socket_exists=socket_exists,
            recovery_hint=(
                "braid up" if socket_exists else "braid up (no broker state)"
            ),
        )

    # Pidfile present — try to parse.
    try:
        raw = pidfile_path.read_text(encoding="utf-8").strip()
        pid = int(raw)
    except (OSError, ValueError) as exc:
        return BrokerHealthSnapshot(
            status="absent",
            braid_root=str(root),
            pidfile_path=str(pidfile_path),
            socket_path=str(socket_path),
            braidd_pid=None,
            pid_alive=None,
            socket_exists=socket_exists,
            recovery_hint="braid down && braid up",
            error_detail=f"failed to parse pidfile: {exc}",
        )

    alive, alive_error = _check_pid_alive(pid)

    if alive is True and socket_exists:
        status = "healthy"
        hint: Optional[str] = None
    elif alive is False and socket_exists:
        status = "degraded_dead_pid_stale_socket"
        hint = "braid down && braid up"
    elif alive is True and not socket_exists:
        status = "socket_missing"
        hint = "braid down && braid up"
    else:
        # alive is None or both False/absent
        status = "absent"
        hint = "braid down && braid up"

    return BrokerHealthSnapshot(
        status=status,
        braid_root=str(root),
        pidfile_path=str(pidfile_path),
        socket_path=str(socket_path),
        braidd_pid=pid,
        pid_alive=alive,
        socket_exists=socket_exists,
        recovery_hint=hint,
        error_detail=alive_error,
    )


def _read_json_safe(path: Path) -> Tuple[Optional[Any], Optional[str]]:
    """Best-effort JSON read. Returns ``(value, error_detail)``."""
    if not path.is_file():
        return None, None
    try:
        with path.open("r", encoding="utf-8") as fh:
            return json.load(fh), None
    except (OSError, json.JSONDecodeError) as exc:
        return None, f"failed to read {path}: {type(exc).__name__}: {exc}"


def probe_response_surface_drift(
    run_id: str,
    braid_root: Optional[str] = None,
    state_dir: Optional[str] = None,
) -> ResponseSurfaceDiagnostic:
    """Classify response-surface drift for ``run_id``.

    See ``ResponseSurfaceDiagnostic`` for the status taxonomy and
    precedence. Pure read-only. Never raises on missing artifacts;
    classifies as ``insufficient_evidence`` or ``pending_absent_*``
    instead.
    """
    root = _resolve_braid_root(braid_root)
    sdir = _resolve_state_dir(state_dir)

    active_run_path = root / "runs" / "active-run"
    active_run_id: Optional[str]
    if active_run_path.is_file():
        try:
            active_run_id = active_run_path.read_text(encoding="utf-8").strip() or None
        except OSError:
            active_run_id = None
    else:
        active_run_id = None

    # Env capture
    sentinel_path = sdir / "braid-root"
    braid_root_sentinel: Optional[str]
    if sentinel_path.is_file():
        try:
            braid_root_sentinel = (
                sentinel_path.read_text(encoding="utf-8").strip() or None
            )
        except OSError:
            braid_root_sentinel = None
    else:
        braid_root_sentinel = None

    env_match = (
        braid_root_sentinel is not None
        and braid_root_sentinel == str(root)
    )

    env_block: Dict[str, Any] = {
        "braid_root": str(root),
        "state_dir": str(sdir),
        "braid_root_sentinel": braid_root_sentinel,
        "env_match": env_match,
    }

    broker = probe_broker_health(str(root) if str(root) else None)
    broker_block: Dict[str, Any] = broker.to_json_dict()

    # Empty-input containers that precede precedence checks
    pending_block: Dict[str, Any] = {
        "present": False,
        "path": str(sdir / "pending-review.json"),
        "run_id": None,
        "response_available": None,
        "response_path": None,
        "response_path_readable": None,
    }
    cursor_block: Dict[str, Any] = {
        "instruction_id": None,
        "delivery_path": None,
        "recorded_at": None,
    }

    # Precedence 1: run-id mismatch.
    if active_run_id is not None and active_run_id != run_id:
        return ResponseSurfaceDiagnostic(
            status="run_id_mismatch",
            run_id=run_id,
            active_run_id=active_run_id,
            run_state=None,
            broker_health=broker_block,
            pending_review=pending_block,
            cursor=cursor_block,
            env=env_block,
        )

    # Precedence 2: insufficient evidence — missing run dir or status.json.
    run_dir = root / "runs" / run_id
    status_path = run_dir / "status.json"
    status_doc, status_err = _read_json_safe(status_path)
    if status_doc is None:
        return ResponseSurfaceDiagnostic(
            status="insufficient_evidence",
            run_id=run_id,
            active_run_id=active_run_id,
            run_state=None,
            broker_health=broker_block,
            pending_review=pending_block,
            cursor=cursor_block,
            env=env_block,
            error_detail=(
                status_err
                if status_err is not None
                else f"status.json not found at {status_path}"
            ),
        )

    run_state = (
        status_doc.get("state") if isinstance(status_doc, dict) else None
    )

    # Cursor (best-effort; not used in precedence)
    cursor_doc, _cursor_err = _read_json_safe(
        run_dir / "codex-review-cursor.json"
    )
    if isinstance(cursor_doc, dict):
        cursor_block = {
            "instruction_id": cursor_doc.get("instruction_id"),
            "delivery_path": cursor_doc.get("delivery_path"),
            "recorded_at": cursor_doc.get("recorded_at"),
        }

    # Pending-review artifact
    pending_path = sdir / "pending-review.json"
    pending_doc, pending_err = _read_json_safe(pending_path)
    pending_present = pending_path.is_file()
    pending_run_id: Optional[str] = None
    response_available: Optional[bool] = None
    response_path_str: Optional[str] = None
    response_path_readable: Optional[bool] = None

    if pending_present and isinstance(pending_doc, dict):
        pending_run_id = pending_doc.get("run_id")
        response_available = pending_doc.get("response_available")
        response_path_str = pending_doc.get("response_path")
        if isinstance(response_path_str, str) and response_path_str:
            try:
                response_path_readable = Path(response_path_str).is_file()
            except OSError:
                response_path_readable = False
        else:
            response_path_readable = False

    pending_block = {
        "present": pending_present,
        "path": str(pending_path),
        "run_id": pending_run_id,
        "response_available": response_available,
        "response_path": response_path_str,
        "response_path_readable": response_path_readable,
    }

    # Precedence 3: pending-review absent cases (state-gated).
    if not pending_present:
        if run_state == "inflight":
            classification = "pending_absent_inflight_ok"
        elif run_state == "waiting_for_codex":
            classification = "pending_absent_unexpected"
        else:
            classification = "insufficient_evidence"
        return ResponseSurfaceDiagnostic(
            status=classification,
            run_id=run_id,
            active_run_id=active_run_id,
            run_state=run_state,
            broker_health=broker_block,
            pending_review=pending_block,
            cursor=cursor_block,
            env=env_block,
            error_detail=pending_err,
        )

    # Precedence 4: pending-review present + broker degraded → cache miss.
    if (
        broker.status == "degraded_dead_pid_stale_socket"
        and response_available is True
        and response_path_readable is True
    ):
        return ResponseSurfaceDiagnostic(
            status="broker_cache_miss_stale_socket",
            run_id=run_id,
            active_run_id=active_run_id,
            run_state=run_state,
            broker_health=broker_block,
            pending_review=pending_block,
            cursor=cursor_block,
            env=env_block,
        )

    # Precedence 5: agreed baseline — pending present, readable, matches.
    if (
        response_available is True
        and response_path_readable is True
        and (pending_run_id is None or pending_run_id == run_id)
    ):
        return ResponseSurfaceDiagnostic(
            status="agreed",
            run_id=run_id,
            active_run_id=active_run_id,
            run_state=run_state,
            broker_health=broker_block,
            pending_review=pending_block,
            cursor=cursor_block,
            env=env_block,
        )

    # Fallthrough: pending present but fields don't match any positive case.
    return ResponseSurfaceDiagnostic(
        status="insufficient_evidence",
        run_id=run_id,
        active_run_id=active_run_id,
        run_state=run_state,
        broker_health=broker_block,
        pending_review=pending_block,
        cursor=cursor_block,
        env=env_block,
        error_detail=pending_err,
    )


__all__ = [
    "RUNTIME_POLICY_DELEGATED_BASH_PATTERNS",
    "SAFETY_DENY_PATTERNS",
    "REQUIRED_PRETOOL_BASH_HOOKS",
    "REQUIRED_POSTTOOL_BASH_HOOKS",
    "validate_bridge_settings",
    "BrokerHealthSnapshot",
    "ResponseSurfaceDiagnostic",
    "probe_broker_health",
    "probe_response_surface_drift",
]
