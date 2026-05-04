"""Guardian Admission custody classifier.

Guardian Admission is the pre-workflow authority that decides whether an
implementation-shaped request belongs in durable project custody or in a
task-local scratchlane. It does not add a canonical workflow stage; it produces
the next authority for the existing planner -> guardian -> implementer chain.
"""

from __future__ import annotations

import json
import os
import re
import sqlite3
import subprocess
from pathlib import Path
from typing import Any

from runtime.core import events
from runtime.core import scratchlanes
from runtime.core.policy_engine import PolicyContext, build_context
from runtime.core.policy_utils import (
    PATH_KIND_ARTIFACT,
    PATH_KIND_ARTIFACT_CANDIDATE,
    PATH_KIND_OTHER,
    PATH_KIND_SOURCE,
    PATH_KIND_TMP_SOURCE_CANDIDATE,
    classify_policy_path,
    normalize_path,
    resolve_path_from_base,
    sanitize_token,
    scratchlane_root,
    suggest_scratchlane_task_slug,
)

VERDICT_READY_FOR_IMPLEMENTER = "ready_for_implementer"
VERDICT_GUARDIAN_PROVISION_REQUIRED = "guardian_provision_required"
VERDICT_PLANNER_REQUIRED = "planner_required"
VERDICT_WORKFLOW_BOOTSTRAP_REQUIRED = "workflow_bootstrap_required"
VERDICT_PROJECT_ONBOARDING_REQUIRED = "project_onboarding_required"
VERDICT_SCRATCHLANE_AUTHORIZED = "scratchlane_authorized"
VERDICT_USER_DECISION_REQUIRED = "user_decision_required"

ADMISSION_VERDICTS = frozenset(
    {
        VERDICT_READY_FOR_IMPLEMENTER,
        VERDICT_GUARDIAN_PROVISION_REQUIRED,
        VERDICT_PLANNER_REQUIRED,
        VERDICT_WORKFLOW_BOOTSTRAP_REQUIRED,
        VERDICT_PROJECT_ONBOARDING_REQUIRED,
        VERDICT_SCRATCHLANE_AUTHORIZED,
        VERDICT_USER_DECISION_REQUIRED,
    }
)

NEXT_AUTHORITY_BY_VERDICT = {
    VERDICT_READY_FOR_IMPLEMENTER: "implementer",
    VERDICT_GUARDIAN_PROVISION_REQUIRED: "guardian:provision",
    VERDICT_PLANNER_REQUIRED: "planner",
    VERDICT_WORKFLOW_BOOTSTRAP_REQUIRED: "workflow_bootstrap",
    VERDICT_PROJECT_ONBOARDING_REQUIRED: "workflow_bootstrap",
    VERDICT_SCRATCHLANE_AUTHORIZED: "scratchlane",
    VERDICT_USER_DECISION_REQUIRED: "user",
}

_SCRATCH_PROMPT_RE = re.compile(
    r"\b(scratchlane|scratch lane|scratch|temporary|temp|tmp/|one[- ]off|"
    r"ad[- ]hoc|throwaway|quick script|helper script|experiment|spike)\b",
    re.IGNORECASE,
)
_DURABLE_PROMPT_RE = re.compile(
    r"\b(project|repo|repository|source|src/|implementation|implement|feature|"
    r"fix|bug|production|tests?|integrate|refactor|module|package)\b",
    re.IGNORECASE,
)


def _git(args: list[str], *, cwd: str) -> subprocess.CompletedProcess[str] | None:
    try:
        return subprocess.run(
            ["git", "-C", cwd, *args],
            capture_output=True,
            text=True,
            timeout=5,
        )
    except (FileNotFoundError, OSError, subprocess.TimeoutExpired):
        return None


def _existing_parent(path: str) -> str:
    if not path:
        return ""
    candidate = Path(path).expanduser()
    if candidate.is_dir():
        return normalize_path(str(candidate))
    if candidate.is_file():
        return normalize_path(str(candidate.parent))
    for parent in (candidate.parent, *candidate.parents):
        if parent.is_dir():
            return normalize_path(str(parent))
    return ""


def _git_root(path: str) -> str:
    base = _existing_parent(path) or (normalize_path(path) if path else "")
    if not base:
        return ""
    result = _git(["rev-parse", "--show-toplevel"], cwd=base)
    if result is not None and result.returncode == 0 and result.stdout.strip():
        return normalize_path(result.stdout.strip())
    return ""


def _is_same_or_descendant(path: str, root: str) -> bool:
    if not path or not root:
        return False
    try:
        Path(path).resolve().relative_to(Path(root).resolve())
        return True
    except (OSError, ValueError):
        return False


def _admission_git_root(
    *,
    project_root: str,
    target_path: str,
    cwd: str,
    explicit_project_root: bool,
) -> str:
    """Resolve the git root without letting explicit non-git roots inherit parents."""
    git_root = _git_root(target_path or cwd or project_root)
    if not git_root or not explicit_project_root:
        return git_root
    if _is_same_or_descendant(git_root, project_root):
        return git_root
    return ""


def _git_branch(path: str) -> str:
    base = _existing_parent(path) or (normalize_path(path) if path else "")
    if not base:
        return ""
    for args in (
        ["symbolic-ref", "--short", "HEAD"],
        ["rev-parse", "--abbrev-ref", "HEAD"],
    ):
        result = _git(args, cwd=base)
        if result is not None and result.returncode == 0 and result.stdout.strip():
            branch = result.stdout.strip()
            return "" if branch == "HEAD" else branch
    return ""


def _resolve_target_path(payload: dict[str, Any], *, project_root: str, cwd: str) -> str:
    raw = str(payload.get("target_path") or payload.get("file_path") or "")
    if not raw:
        tool_input = payload.get("tool_input")
        if isinstance(tool_input, dict):
            raw = str(tool_input.get("file_path") or "")
    if not raw:
        return ""
    if os.path.isabs(raw):
        return normalize_path(raw)
    base = cwd or project_root or os.getcwd()
    return normalize_path(resolve_path_from_base(base, raw))


def resolve_project_root(payload: dict[str, Any]) -> str:
    """Resolve the target project root without falling back to HOME."""
    explicit = str(payload.get("project_root") or "")
    if explicit and Path(explicit).expanduser().is_dir():
        return normalize_path(explicit)

    env_root = os.environ.get("CLAUDE_PROJECT_DIR", "")
    if env_root and Path(env_root).expanduser().is_dir():
        return normalize_path(env_root)

    cwd = str(payload.get("cwd") or os.getcwd())
    target = _resolve_target_path(payload, project_root="", cwd=cwd)
    for candidate in (target, cwd):
        root = _git_root(candidate)
        if root:
            return root

    return _existing_parent(target or cwd)


def _prompt_flags(prompt: str) -> tuple[bool, bool]:
    scratch_like = bool(_SCRATCH_PROMPT_RE.search(prompt or ""))
    durable_like = bool(_DURABLE_PROMPT_RE.search(prompt or ""))
    return scratch_like, durable_like


def _slug_from_prompt(prompt: str) -> str:
    words = re.findall(r"[A-Za-z0-9][A-Za-z0-9._-]*", prompt or "")
    stop = {
        "a",
        "an",
        "and",
        "for",
        "in",
        "of",
        "the",
        "this",
        "to",
        "with",
        "scratch",
        "scratchlane",
        "temporary",
        "tmp",
    }
    selected = [word for word in words if word.lower() not in stop][:5]
    return sanitize_token("-".join(selected) if selected else "ad-hoc")


def _scratchlane_identity(
    *,
    project_root: str,
    target_path: str,
    path_info,
    prompt: str,
    requested_task_slug: str = "",
) -> dict[str, str]:
    slug = sanitize_token(requested_task_slug) if requested_task_slug else path_info.task_slug or ""
    if not slug and target_path:
        slug = suggest_scratchlane_task_slug(target_path)
    if not slug:
        slug = _slug_from_prompt(prompt)
    root = scratchlane_root(project_root, slug) if project_root else ""
    return {
        "task_slug": slug,
        "root_path": root,
        "relative_path": f"tmp/{slug}/",
    }


def _active_implementer_lease(
    conn: sqlite3.Connection,
    *,
    workflow_id: str,
    worktree_path: str,
) -> dict | None:
    clauses = ["status = 'active'", "role = 'implementer'"]
    params: list[object] = []
    if workflow_id:
        clauses.append("workflow_id = ?")
        params.append(workflow_id)
    if worktree_path:
        clauses.append("worktree_path = ?")
        params.append(normalize_path(worktree_path))
    row = conn.execute(
        f"""
        SELECT *
        FROM dispatch_leases
        WHERE {' AND '.join(clauses)}
        ORDER BY issued_at DESC, lease_id DESC
        LIMIT 1
        """,
        params,
    ).fetchone()
    return dict(row) if row else None


def facts_from_context(
    context: PolicyContext,
    payload: dict[str, Any],
) -> dict[str, Any]:
    """Build admission facts from an already-resolved policy context."""
    cwd = normalize_path(str(payload.get("cwd") or context.worktree_path or context.project_root or os.getcwd()))
    project_root = normalize_path(str(payload.get("project_root") or context.project_root or cwd))
    target_path = _resolve_target_path(payload, project_root=project_root, cwd=cwd)
    git_root = _admission_git_root(
        project_root=project_root,
        target_path=target_path,
        cwd=cwd,
        explicit_project_root=bool(payload.get("_explicit_project_root")),
    )
    branch = (context.branch or _git_branch(git_root)) if git_root else ""
    if target_path:
        path_info = classify_policy_path(
            target_path,
            project_root=project_root,
            worktree_path=context.worktree_path or "",
            scratch_roots=context.scratchlane_roots,
        )
    else:
        class _NoTargetPathInfo:
            repo_relative_path = None
            kind = PATH_KIND_OTHER
            task_slug = ""
            scratch_root = ""

        path_info = _NoTargetPathInfo()
    prompt = str(payload.get("user_prompt") or payload.get("prompt") or "")
    scratch_like, durable_like = _prompt_flags(prompt)
    scratchlane = _scratchlane_identity(
        project_root=project_root,
        target_path=target_path,
        path_info=path_info,
        prompt=prompt,
        requested_task_slug=str(payload.get("task_slug") or ""),
    )
    attached_lease = context.lease if isinstance(context.lease, dict) else None
    implementer_attached = bool(
        attached_lease
        and str(attached_lease.get("role") or "") == "implementer"
        and (not context.workflow_id or str(attached_lease.get("workflow_id") or "") == context.workflow_id)
    )
    return {
        "trigger": str(payload.get("trigger") or "manual"),
        "project_root": project_root,
        "cwd": cwd,
        "target_path": target_path,
        "repo_relative_path": path_info.repo_relative_path,
        "path_kind": path_info.kind,
        "has_git": bool(git_root),
        "git_root": git_root,
        "branch": branch,
        "on_main": branch in {"main", "master"},
        "workflow_id": str(payload.get("workflow_id") or context.workflow_id or ""),
        "has_workflow_binding": context.binding is not None,
        "has_workflow_scope": context.scope is not None,
        "has_context_lease": attached_lease is not None,
        "has_implementer_lease": implementer_attached,
        "actor_role": context.actor_role,
        "scratch_like_prompt": scratch_like,
        "durable_like_prompt": durable_like,
        "scratchlane_active": path_info.kind == PATH_KIND_ARTIFACT,
        "scratchlane": scratchlane,
    }


def collect_facts(conn: sqlite3.Connection, payload: dict[str, Any]) -> dict[str, Any]:
    """Collect full admission facts from a raw payload and runtime DB."""
    project_root = resolve_project_root(payload)
    cwd = normalize_path(str(payload.get("cwd") or project_root or os.getcwd()))
    target_path = _resolve_target_path(payload, project_root=project_root, cwd=cwd)
    workflow_id = str(
        payload.get("workflow_id")
        or payload.get("actor_workflow_id")
        or ""
    )
    context = build_context(
        conn,
        cwd=cwd,
        actor_role=str(payload.get("actor_role") or ""),
        actor_id=str(payload.get("actor_id") or ""),
        actor_workflow_id=workflow_id,
        session_id=str(payload.get("session_id") or ""),
        project_root=project_root,
    )
    facts = facts_from_context(
        context,
        {
            **payload,
            "cwd": cwd,
            "project_root": project_root,
            "_explicit_project_root": bool(payload.get("project_root")),
            "target_path": target_path,
            "workflow_id": workflow_id or context.workflow_id,
        },
    )
    active_impl = _active_implementer_lease(
        conn,
        workflow_id=str(facts.get("workflow_id") or ""),
        worktree_path=str(context.worktree_path or project_root),
    )
    if active_impl is not None:
        facts["has_implementer_lease"] = True
        facts["implementer_lease_id"] = active_impl.get("lease_id")
    else:
        facts["implementer_lease_id"] = ""
    return facts


def _decision(verdict: str, reason: str, facts: dict[str, Any]) -> dict[str, Any]:
    scratchlane = facts.get("scratchlane") if isinstance(facts.get("scratchlane"), dict) else {}
    return {
        "verdict": verdict,
        "next_authority": NEXT_AUTHORITY_BY_VERDICT[verdict],
        "reason": reason,
        "facts": facts,
        "project_root": facts.get("project_root", ""),
        "target_path": facts.get("target_path", ""),
        "scratchlane": scratchlane,
    }


def classify_facts(facts: dict[str, Any]) -> dict[str, Any]:
    """Classify pre-implementation custody from collected facts."""
    path_kind = str(facts.get("path_kind") or "")
    trigger = str(facts.get("trigger") or "manual")
    scratch_like = bool(facts.get("scratch_like_prompt"))
    durable_like = bool(facts.get("durable_like_prompt"))
    target_path = str(facts.get("target_path") or "")
    has_git = bool(facts.get("has_git"))

    if path_kind == PATH_KIND_ARTIFACT:
        return _decision(
            VERDICT_SCRATCHLANE_AUTHORIZED,
            "Target is already inside an active Guardian-custodied scratchlane.",
            facts,
        )

    if path_kind in {PATH_KIND_ARTIFACT_CANDIDATE, PATH_KIND_TMP_SOURCE_CANDIDATE}:
        return _decision(
            VERDICT_SCRATCHLANE_AUTHORIZED,
            "Target is an obvious task-local tmp scratchlane candidate.",
            facts,
        )

    if scratch_like and path_kind == PATH_KIND_SOURCE:
        return _decision(
            VERDICT_USER_DECISION_REQUIRED,
            "Prompt asks for scratch work but targets durable project source.",
            facts,
        )

    if scratch_like and not target_path:
        return _decision(
            VERDICT_SCRATCHLANE_AUTHORIZED,
            "Prompt is explicitly temporary and has no durable source target.",
            facts,
        )

    source_like = path_kind == PATH_KIND_SOURCE or trigger in {
        "implementer_dispatch",
        "source_write",
        "bash_file_mutation",
    }

    if not has_git:
        if source_like or durable_like:
            return _decision(
                VERDICT_PROJECT_ONBOARDING_REQUIRED,
                "Durable source work is targeting a non-git project root.",
                facts,
            )
        return _decision(
            VERDICT_USER_DECISION_REQUIRED,
            "Guardian Admission cannot determine whether this non-git work is durable project work or scratchlane work.",
            facts,
        )

    if (
        facts.get("has_workflow_binding")
        and facts.get("has_workflow_scope")
        and facts.get("has_implementer_lease")
        and not facts.get("on_main")
    ):
        return _decision(
            VERDICT_READY_FOR_IMPLEMENTER,
            "Existing workflow binding, scope, branch, and implementer lease already establish custody.",
            facts,
        )

    if not facts.get("has_workflow_binding"):
        return _decision(
            VERDICT_WORKFLOW_BOOTSTRAP_REQUIRED,
            "Git repo has no runtime workflow binding for this work.",
            facts,
        )

    if not facts.get("has_workflow_scope"):
        return _decision(
            VERDICT_PLANNER_REQUIRED,
            "Workflow is bound but has no scope manifest or planned work item.",
            facts,
        )

    return _decision(
        VERDICT_GUARDIAN_PROVISION_REQUIRED,
        "Workflow exists but implementer custody is not currently provisioned.",
        facts,
    )


def classify_payload(conn: sqlite3.Connection, payload: dict[str, Any]) -> dict[str, Any]:
    return classify_facts(collect_facts(conn, payload))


def classify_context(context: PolicyContext, payload: dict[str, Any]) -> dict[str, Any]:
    return classify_facts(facts_from_context(context, payload))


def apply_payload(conn: sqlite3.Connection, payload: dict[str, Any]) -> dict[str, Any]:
    """Apply the admission decision when it authorizes scratchlane custody."""
    result = classify_payload(conn, payload)
    verdict = str(result.get("verdict") or "")
    source = f"admission:{result.get('next_authority', 'unknown')}"
    detail = {
        "verdict": verdict,
        "next_authority": result.get("next_authority", ""),
        "project_root": result.get("project_root", ""),
        "target_path": result.get("target_path", ""),
        "scratchlane": result.get("scratchlane", {}),
        "reason": result.get("reason", ""),
    }

    if verdict != VERDICT_SCRATCHLANE_AUTHORIZED:
        events.emit(
            conn,
            "guardian_admission.classified",
            source=source,
            detail=json.dumps(detail, sort_keys=True),
        )
        return {**result, "applied": False, "permit": None}

    scratch = result.get("scratchlane") if isinstance(result.get("scratchlane"), dict) else {}
    project_root = str(result.get("project_root") or "")
    task_slug = str(scratch.get("task_slug") or "")
    if not project_root or not task_slug:
        return {
            **result,
            "applied": False,
            "permit": None,
            "apply_error": "scratchlane_authorized without project_root/task_slug",
        }

    existing = scratchlanes.get_active(conn, project_root, task_slug)
    if existing is not None and existing.get("granted_by") == "guardian_admission":
        detail["permit_id"] = existing.get("id")
        detail["root_path"] = existing.get("root_path")
        detail["idempotent"] = True
        events.emit(
            conn,
            "guardian_admission.scratchlane_granted",
            source=source,
            detail=json.dumps(detail, sort_keys=True),
        )
        return {**result, "applied": True, "permit": existing, "idempotent": True}

    permit = scratchlanes.grant(
        conn,
        project_root,
        task_slug,
        granted_by="guardian_admission",
        note=str(result.get("reason") or ""),
        session_id=str(payload.get("session_id") or ""),
        workflow_id=str(payload.get("workflow_id") or result.get("facts", {}).get("workflow_id") or ""),
        work_item_id=str(payload.get("work_item_id") or ""),
        attempt_id=str(payload.get("attempt_id") or ""),
    )
    detail["permit_id"] = permit.get("id")
    detail["root_path"] = permit.get("root_path")
    events.emit(
        conn,
        "guardian_admission.scratchlane_granted",
        source=source,
        detail=json.dumps(detail, sort_keys=True),
    )
    return {**result, "applied": True, "permit": permit}


def format_admission_reason(result: dict[str, Any]) -> str:
    """Return a stable denial/explanation string for policy gates."""
    verdict = str(result.get("verdict") or VERDICT_USER_DECISION_REQUIRED)
    next_authority = str(result.get("next_authority") or NEXT_AUTHORITY_BY_VERDICT[VERDICT_USER_DECISION_REQUIRED])
    reason = str(result.get("reason") or "")
    target = str(result.get("target_path") or "")
    scratch = result.get("scratchlane") if isinstance(result.get("scratchlane"), dict) else {}
    lane = str(scratch.get("relative_path") or "")
    parts = [
        f"ADMISSION_REQUIRED: Guardian Admission verdict={verdict}; next_authority={next_authority}.",
    ]
    if target:
        parts.append(f"Target: `{target}`.")
    if lane:
        parts.append(f"Scratchlane: `{lane}`.")
    if reason:
        parts.append(reason)
    if verdict == VERDICT_SCRATCHLANE_AUTHORIZED:
        parts.append(
            "The runtime has Guardian authority to grant this scratchlane; retry the work under the scratchlane root, not at the original durable-source path."
        )
    elif next_authority == "user":
        parts.append("Ask the user only for this custody decision; do not guess.")
    else:
        parts.append(f"Route to `{next_authority}` before implementation or source writes continue.")
    return " ".join(parts)
