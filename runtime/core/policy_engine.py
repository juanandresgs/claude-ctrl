"""Policy engine core — registry, evaluation, and context building.

This module is the authoritative entry point for all policy decisions.
Hooks call cc-policy evaluate (via cli.py), which builds a PolicyContext,
constructs a PolicyRequest, and calls default_registry().evaluate().

Architecture:
  PolicyRegistry  — stores policy functions, evaluates them in priority order
  PolicyContext   — all resolved state needed for a policy decision
  PolicyRequest   — event type + tool input + context, passed to each policy fn
  PolicyDecision  — the verdict: allow | deny | feedback
  PolicyInfo      — metadata about a registered policy (for list/introspection)
  PolicyEvaluation — per-policy result record for explain()

Evaluation semantics (matches guard.sh short-circuit behavior):
  - Policies run in ascending priority order (lower number = earlier)
  - Policies that don't match event_type are skipped
  - Disabled policies are skipped
  - None return → "no opinion", continue
  - action="deny" → stop immediately, return that decision
  - action="feedback" → record, continue (last feedback wins if no deny)
  - No deny or feedback → default allow

explain() is evaluate() without short-circuiting: all matching policies run
and return their individual PolicyEvaluation records.

@decision DEC-PE-004
Title: PolicyRegistry is the sole dispatch point for all policy decisions
Status: accepted
Rationale: Previous architecture had policy logic scattered across guard.sh,
  branch-guard.sh, doc-gate.sh, and plan-guard.sh as ad-hoc bash checks.
  Centralizing into PolicyRegistry gives a single location where all active
  policies are enumerable, testable, and introspectable via cc-policy policy
  list/explain. The registry is stateless — it holds only callables and
  metadata. State flows in via PolicyContext, which is resolved once per
  request by build_context(). This separation lets policy functions be pure:
  given a PolicyRequest they return a decision without side effects.

@decision DEC-PE-005
Title: build_context() resolves all SQLite state in one shot
Status: accepted
Rationale: Each policy function would otherwise need its own DB connection
  and individual queries. Centralizing state resolution in build_context()
  means policies are pure functions that never do I/O — they receive a
  fully-populated PolicyContext and return a decision. This is testable
  without a database (inject a hand-crafted PolicyContext). The tradeoff is
  that build_context() loads fields that some policies won't use; the load
  is cheap (indexed point reads) and the simplicity wins.
"""

from __future__ import annotations

import sqlite3
from dataclasses import dataclass
from typing import Callable, Optional

from runtime.core.policy_utils import (
    current_workflow_id,
    detect_project_root,
    is_claude_meta_repo,
)

# ---------------------------------------------------------------------------
# Data types
# ---------------------------------------------------------------------------


@dataclass
class PolicyContext:
    """All resolved state needed to make a policy decision.

    Built once per request by build_context(). Policy functions receive this
    as part of PolicyRequest — they must not perform additional I/O.
    """

    actor_role: str  # "implementer", "planner", "guardian", etc.
    actor_id: str  # agent_id from lease or marker
    workflow_id: str  # from lease or branch derivation
    worktree_path: str  # from lease or CWD
    branch: str  # current git branch (abbrev-ref)
    project_root: str  # git root
    is_meta_repo: bool  # True if ~/.claude
    lease: Optional[dict]  # active lease record, or None
    scope: Optional[dict]  # workflow_scope record, or None
    eval_state: Optional[dict]  # evaluation_state record, or None
    test_state: Optional[dict]  # test_state record, or None
    binding: Optional[dict]  # workflow_binding record, or None
    dispatch_phase: Optional[str]  # derived from completions, or None


@dataclass
class PolicyRequest:
    """One hook invocation packaged for policy evaluation.

    event_type  — "PreToolUse", "PostToolUse", "SubagentStop", etc.
    tool_name   — "Write", "Edit", "Bash", etc. (empty string for lifecycle events)
    tool_input  — raw tool_input dict from Claude hook JSON
    context     — fully resolved PolicyContext
    cwd         — the CWD at hook invocation time
    """

    event_type: str
    tool_name: str
    tool_input: dict
    context: PolicyContext
    cwd: str


@dataclass
class PolicyDecision:
    """The verdict returned by a policy function or the registry.

    action      — "allow", "deny", or "feedback"
    reason      — human-readable explanation
    policy_name — which policy produced this decision
    effects     — optional side effects the CLI handler should apply
    metadata    — optional introspection data
    """

    action: str
    reason: str
    policy_name: str
    effects: Optional[dict] = None
    metadata: Optional[dict] = None


@dataclass
class PolicyInfo:
    """Metadata about a registered policy (returned by list_policies())."""

    name: str
    priority: int
    event_types: list[str]
    enabled: bool


@dataclass
class PolicyEvaluation:
    """Per-policy result record for explain().

    result is one of: "deny", "allow", "feedback", "skip", "no_opinion"
    """

    policy_name: str
    result: str
    reason: Optional[str]
    decision: Optional[PolicyDecision]


# ---------------------------------------------------------------------------
# Internal registry entry
# ---------------------------------------------------------------------------


@dataclass
class _PolicyEntry:
    name: str
    fn: Callable[[PolicyRequest], Optional[PolicyDecision]]
    event_types: list[str]
    priority: int
    enabled: bool


# ---------------------------------------------------------------------------
# PolicyRegistry
# ---------------------------------------------------------------------------


class PolicyRegistry:
    """Ordered collection of policy functions with evaluation semantics.

    Usage:
      reg = PolicyRegistry()
      reg.register("my-policy", my_fn, event_types=["PreToolUse"], priority=10)
      decision = reg.evaluate(request)
    """

    def __init__(self) -> None:
        self._entries: list[_PolicyEntry] = []

    def register(
        self,
        name: str,
        fn: Callable[[PolicyRequest], Optional[PolicyDecision]],
        *,
        event_types: list[str],
        priority: int,
        enabled: bool = True,
    ) -> None:
        """Register a policy function.

        name        — unique identifier for this policy
        fn          — callable(PolicyRequest) → Optional[PolicyDecision]
        event_types — list of event types this policy applies to
        priority    — lower number = runs first (ascending order)
        enabled     — False = skip during evaluate/explain
        """
        self._entries.append(
            _PolicyEntry(
                name=name,
                fn=fn,
                event_types=list(event_types),
                priority=priority,
                enabled=enabled,
            )
        )
        # Keep sorted by priority so evaluation is O(n) with no sorting overhead
        self._entries.sort(key=lambda e: e.priority)

    def list_policies(self) -> list[PolicyInfo]:
        """Return metadata for all registered policies in priority order."""
        return [
            PolicyInfo(
                name=e.name,
                priority=e.priority,
                event_types=e.event_types,
                enabled=e.enabled,
            )
            for e in self._entries
        ]

    def evaluate(self, request: PolicyRequest) -> PolicyDecision:
        """Evaluate all matching policies and return the final decision.

        Semantics (mirrors guard.sh short-circuit behavior):
          - Disabled policies are skipped
          - Policies not matching request.event_type are skipped
          - None return → no opinion, continue to next
          - action="deny" → stop, return immediately
          - action="feedback" → record, continue (last feedback wins)
          - No deny and no feedback → default allow
        """
        last_feedback: Optional[PolicyDecision] = None

        for entry in self._entries:
            if not entry.enabled:
                continue
            if request.event_type not in entry.event_types:
                continue

            result = entry.fn(request)

            if result is None:
                continue

            if result.action == "deny":
                return result

            if result.action == "feedback":
                last_feedback = result
                continue

            # action="allow" from a policy — treat as no opinion (continue)
            # so downstream policies still run. A policy that wants to
            # unconditionally allow should return None instead.

        if last_feedback is not None:
            return last_feedback

        return PolicyDecision(
            action="allow",
            reason="all policies passed",
            policy_name="default",
        )

    def explain(self, request: PolicyRequest) -> list[PolicyEvaluation]:
        """Run all matching policies without short-circuiting.

        Returns a PolicyEvaluation for every matching policy so callers
        can see the full decision trace. Disabled/non-matching policies
        are included as result="skip".
        """
        evaluations: list[PolicyEvaluation] = []

        for entry in self._entries:
            if not entry.enabled:
                evaluations.append(
                    PolicyEvaluation(
                        policy_name=entry.name,
                        result="skip",
                        reason="policy disabled",
                        decision=None,
                    )
                )
                continue

            if request.event_type not in entry.event_types:
                evaluations.append(
                    PolicyEvaluation(
                        policy_name=entry.name,
                        result="skip",
                        reason=f"event_type {request.event_type!r} not in {entry.event_types}",
                        decision=None,
                    )
                )
                continue

            result = entry.fn(request)

            if result is None:
                evaluations.append(
                    PolicyEvaluation(
                        policy_name=entry.name,
                        result="no_opinion",
                        reason=None,
                        decision=None,
                    )
                )
            else:
                evaluations.append(
                    PolicyEvaluation(
                        policy_name=entry.name,
                        result=result.action,
                        reason=result.reason,
                        decision=result,
                    )
                )

        return evaluations


# ---------------------------------------------------------------------------
# Context builder
# ---------------------------------------------------------------------------


def build_context(
    conn: sqlite3.Connection,
    *,
    cwd: str,
    actor_role: str = "",
    actor_id: str = "",
) -> PolicyContext:
    """Resolve all SQLite state into a PolicyContext in one shot.

    Queries (all indexed point-reads, cheap):
      - leases: find active lease for actor_id or cwd
      - markers: fallback role/id if lease absent
      - workflow_bindings: find binding for resolved workflow_id
      - workflow_scope: scope manifest for the workflow
      - evaluation_state: current eval status
      - test_state: last test run status
      - completions: derive dispatch_phase from latest completion

    actor_role and actor_id are overrides — the caller (cli.py) passes them
    from the JSON payload. If not provided, they're inferred from the DB.
    """
    project_root = detect_project_root(cwd)
    is_meta = is_claude_meta_repo(project_root)

    # --- Resolve active lease ---
    lease: Optional[dict] = None
    if actor_id:
        row = conn.execute(
            "SELECT * FROM dispatch_leases WHERE agent_id = ? AND status = 'active' LIMIT 1",
            (actor_id,),
        ).fetchone()
        if row:
            lease = dict(row)

    if lease is None:
        # Try finding by worktree_path = cwd or project_root
        row = conn.execute(
            "SELECT * FROM dispatch_leases WHERE status = 'active' AND (worktree_path = ? OR worktree_path = ?) LIMIT 1",
            (cwd, project_root),
        ).fetchone()
        if row:
            lease = dict(row)

    # --- Resolve role / agent_id from lease or marker ---
    resolved_role = actor_role
    resolved_id = actor_id

    if lease:
        if not resolved_role:
            resolved_role = lease.get("role", "")
        if not resolved_id:
            resolved_id = lease.get("agent_id", "")

    if not resolved_role or not resolved_id:
        marker_row = conn.execute(
            "SELECT agent_id, role FROM agent_markers WHERE is_active = 1 ORDER BY started_at DESC LIMIT 1",
        ).fetchone()
        if marker_row:
            if not resolved_role:
                resolved_role = marker_row["role"] or ""
            if not resolved_id:
                resolved_id = marker_row["agent_id"] or ""

    # --- Workflow ID ---
    workflow_id = ""
    if lease:
        workflow_id = lease.get("workflow_id", "")
    if not workflow_id:
        workflow_id = current_workflow_id(project_root)

    # --- Workflow binding ---
    binding: Optional[dict] = None
    if workflow_id:
        row = conn.execute(
            "SELECT * FROM workflow_bindings WHERE workflow_id = ? LIMIT 1",
            (workflow_id,),
        ).fetchone()
        if row:
            binding = dict(row)

    # --- Worktree path ---
    worktree_path = cwd
    if lease:
        worktree_path = lease.get("worktree_path", cwd) or cwd
    elif binding:
        worktree_path = binding.get("worktree_path", cwd) or cwd

    # --- Branch ---
    branch = ""
    if lease:
        branch = lease.get("branch", "") or ""
    if not branch and binding:
        branch = binding.get("branch", "") or ""
    if not branch:
        try:
            import subprocess

            r = subprocess.run(
                ["git", "-C", project_root, "rev-parse", "--abbrev-ref", "HEAD"],
                capture_output=True,
                text=True,
                timeout=5,
            )
            if r.returncode == 0:
                branch = r.stdout.strip()
        except Exception:
            pass

    # --- Scope ---
    scope: Optional[dict] = None
    if workflow_id:
        row = conn.execute(
            "SELECT * FROM workflow_scope WHERE workflow_id = ? LIMIT 1",
            (workflow_id,),
        ).fetchone()
        if row:
            scope = dict(row)

    # --- Evaluation state ---
    eval_state: Optional[dict] = None
    if workflow_id:
        row = conn.execute(
            "SELECT * FROM evaluation_state WHERE workflow_id = ? LIMIT 1",
            (workflow_id,),
        ).fetchone()
        if row:
            eval_state = dict(row)

    # --- Test state ---
    test_state: Optional[dict] = None
    row = conn.execute(
        "SELECT * FROM test_state WHERE project_root = ? LIMIT 1",
        (project_root,),
    ).fetchone()
    if row:
        test_state = dict(row)

    # --- Dispatch phase from completions ---
    dispatch_phase: Optional[str] = None
    row = conn.execute(
        "SELECT role, verdict FROM completion_records ORDER BY created_at DESC LIMIT 1",
    ).fetchone()
    if row:
        dispatch_phase = f"{row['role']}:{row['verdict']}"

    return PolicyContext(
        actor_role=resolved_role,
        actor_id=resolved_id,
        workflow_id=workflow_id,
        worktree_path=worktree_path,
        branch=branch,
        project_root=project_root,
        is_meta_repo=is_meta,
        lease=lease,
        scope=scope,
        eval_state=eval_state,
        test_state=test_state,
        binding=binding,
        dispatch_phase=dispatch_phase,
    )


# ---------------------------------------------------------------------------
# Default registry
# ---------------------------------------------------------------------------


def default_registry() -> PolicyRegistry:
    """Return a PolicyRegistry with all registered policies loaded.

    In W1 this returns an empty registry — policies will be added in W2/W3.
    Importing runtime.core.policies populates the registry via register_all().
    """
    reg = PolicyRegistry()
    # Import here to avoid circular imports; register_all() adds W2/W3 policies
    try:
        from runtime.core import policies as _policies_pkg

        _policies_pkg.register_all(reg)
    except ImportError:
        pass
    return reg
