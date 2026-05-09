"""Canonical issue/backlog capture pipeline.

This module is the runtime authority for durable issue capture that is broader
than bug filing: follow-ups, technical debt, tasks, questions, and bugs all
flow through one SQLite-first, deduplicated, retryable path before the GitHub
Issues adapter is invoked.

@decision DEC-ISSUE-CAPTURE-001
Title: General issue capture is the authority for backlog persistence
Status: accepted
Rationale: `/backlog` and Stop-time follow-up capture must not call
  `todo.sh add` directly. Direct calls bypass fingerprint deduplication,
  local retry state, audit events, and deterministic repo routing. This module
  owns classification and routing, then treats `todo.sh` as a narrow GitHub
  adapter.
"""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import time
from typing import Optional

import runtime.core.events as events


ALLOWED_ITEM_KINDS: frozenset[str] = frozenset(
    {"bug", "follow_up", "tech_debt", "task", "question"}
)
ALLOWED_SCOPES: frozenset[str] = frozenset({"auto", "project", "config", "global", "explicit"})
_FILED_DISPOSITIONS: frozenset[str] = frozenset({"filed", "duplicate"})
_DEFAULT_TODO_SH = str(Path.home() / ".claude" / "scripts" / "todo.sh")
_DEFAULT_CONFIG_ROOT = Path.home() / ".claude"


@dataclass(frozen=True)
class IssueRoute:
    """Resolved target for a captured issue."""

    scope: str
    repo: str
    cwd: str
    reason: str


def normalize_kind(item_kind: str) -> str:
    """Return the canonical item kind string."""
    kind = (item_kind or "task").strip().lower().replace("-", "_")
    return kind


def fingerprint(item_kind: str, source_component: str, title: str, file_path: str = "") -> str:
    """Compute a stable dedup fingerprint for a captured issue."""
    normalized_title = _normalize_text(title)
    normalized_source = _normalize_text(source_component)
    normalized_path = Path(file_path).name if file_path else ""
    raw = f"{normalize_kind(item_kind)}:{normalized_source}:{normalized_path}:{normalized_title}"
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()[:16]


def qualify(
    item_kind: str,
    title: str,
    evidence: str = "",
    fixed_now: bool = False,
) -> str:
    """Classify whether an issue should be captured."""
    if fixed_now:
        return "fixed_now"
    if normalize_kind(item_kind) not in ALLOWED_ITEM_KINDS:
        return "rejected_non_issue"
    if not title or not title.strip():
        return "rejected_non_issue"
    if normalize_kind(item_kind) == "bug" and not evidence.strip():
        return "rejected_non_issue"
    return "filed"


def resolve_route(
    scope: str = "auto",
    *,
    repo: str = "",
    project_root: str = "",
    file_path: str = "",
    source_component: str = "",
    config_root: Optional[Path] = None,
) -> IssueRoute:
    """Resolve the durable target for a captured issue.

    Routing rules:
      - explicit repo always wins.
      - global uses the configured global backlog repo through todo.sh.
      - config targets the Claude control-plane repo.
      - auto targets config when the implicated path is under ~/.claude,
        otherwise the active project.
    """
    explicit_repo = (repo or "").strip()
    if explicit_repo:
        return IssueRoute(
            scope="explicit",
            repo=explicit_repo,
            cwd=project_root or os.getcwd(),
            reason="explicit repo override",
        )

    requested_scope = (scope or "auto").strip().lower()
    if requested_scope not in ALLOWED_SCOPES:
        requested_scope = "auto"

    cfg_root = (config_root or _DEFAULT_CONFIG_ROOT).expanduser().resolve()
    root = Path(project_root).expanduser().resolve() if project_root else Path.cwd().resolve()

    if requested_scope == "auto":
        if _mentions_config_path(file_path, cfg_root) or _mentions_config_path(
            source_component, cfg_root
        ):
            requested_scope = "config"
        elif _is_within(root, cfg_root):
            requested_scope = "config"
        else:
            requested_scope = "project"

    if requested_scope == "global":
        return IssueRoute(scope="global", repo="", cwd=str(root), reason="global scope")

    if requested_scope == "config":
        return IssueRoute(
            scope="config",
            repo=_infer_github_repo(cfg_root),
            cwd=str(cfg_root),
            reason="config/control-plane scope",
        )

    return IssueRoute(scope="project", repo="", cwd=str(root), reason="project scope")


def get_by_fingerprint(conn: sqlite3.Connection, fp: str) -> Optional[dict]:
    """Return one captured issue by fingerprint."""
    row = conn.execute("SELECT * FROM issue_captures WHERE fingerprint = ?", (fp,)).fetchone()
    return dict(row) if row else None


def list_issues(
    conn: sqlite3.Connection,
    *,
    disposition: Optional[str] = None,
    item_kind: Optional[str] = None,
    limit: int = 50,
) -> list[dict]:
    """Return captured issues, newest first."""
    clauses: list[str] = []
    values: list[object] = []
    if disposition:
        clauses.append("disposition = ?")
        values.append(disposition)
    if item_kind:
        clauses.append("item_kind = ?")
        values.append(normalize_kind(item_kind))
    where = f"WHERE {' AND '.join(clauses)}" if clauses else ""
    values.append(limit)
    rows = conn.execute(
        f"SELECT * FROM issue_captures {where} ORDER BY id DESC LIMIT ?", values
    ).fetchall()
    return [dict(row) for row in rows]


def file_issue(
    conn: sqlite3.Connection,
    *,
    item_kind: str,
    title: str,
    body: str = "",
    scope: str = "auto",
    repo: str = "",
    source_component: str = "",
    file_path: str = "",
    evidence: str = "",
    project_root: str = "",
    fixed_now: bool = False,
    todo_sh_path: Optional[str] = None,
) -> dict:
    """Capture an issue through SQLite, then file it through todo.sh."""
    try:
        return _file_issue_impl(
            conn,
            item_kind=item_kind,
            title=title,
            body=body,
            scope=scope,
            repo=repo,
            source_component=source_component,
            file_path=file_path,
            evidence=evidence,
            project_root=project_root,
            fixed_now=fixed_now,
            todo_sh_path=todo_sh_path,
        )
    except Exception as exc:
        _emit_safe(conn, "issue_capture_failed", source_component, f"{title}: {exc}")
        return {
            "disposition": "failed_to_file",
            "fingerprint": "",
            "issue_url": None,
            "encounter_count": 0,
            "scope": scope or "auto",
            "repo": repo or "",
            "error": str(exc),
        }


def retry_failed(conn: sqlite3.Connection, todo_sh_path: Optional[str] = None) -> list[dict]:
    """Retry every issue capture row with disposition='failed_to_file'."""
    rows = conn.execute(
        "SELECT * FROM issue_captures WHERE disposition = 'failed_to_file' ORDER BY id"
    ).fetchall()
    results: list[dict] = []
    for row in rows:
        data = dict(row)
        results.append(
            file_issue(
                conn,
                item_kind=data["item_kind"],
                title=data["title"],
                body=data.get("body") or "",
                scope=data.get("scope") or "auto",
                repo=data.get("repo") or "",
                source_component=data.get("source_component") or "",
                file_path=data.get("file_path") or "",
                evidence=data.get("evidence") or "",
                todo_sh_path=todo_sh_path,
            )
        )
    return results


def _file_issue_impl(
    conn: sqlite3.Connection,
    *,
    item_kind: str,
    title: str,
    body: str,
    scope: str,
    repo: str,
    source_component: str,
    file_path: str,
    evidence: str,
    project_root: str,
    fixed_now: bool,
    todo_sh_path: Optional[str],
) -> dict:
    now = int(time.time())
    kind = normalize_kind(item_kind)
    disposition = qualify(kind, title, evidence, fixed_now=fixed_now)

    if disposition == "fixed_now":
        _emit_safe(conn, "issue_fixed_now", source_component, title)
        return _result("fixed_now", "", None, 0, scope, repo)
    if disposition == "rejected_non_issue":
        _emit_safe(conn, "issue_rejected", source_component, title)
        return _result("rejected_non_issue", "", None, 0, scope, repo)

    fp = fingerprint(kind, source_component, title, file_path)
    route = resolve_route(
        scope,
        repo=repo,
        project_root=project_root,
        file_path=file_path,
        source_component=source_component,
    )

    existing = get_by_fingerprint(conn, fp)
    if existing is not None and existing["disposition"] in _FILED_DISPOSITIONS:
        count = _upsert_issue(
            conn,
            fp=fp,
            item_kind=kind,
            title=title,
            body=body,
            scope=route.scope,
            repo=route.repo,
            source_component=source_component,
            file_path=file_path,
            evidence=evidence,
            disposition="duplicate",
            issue_number=existing.get("issue_number"),
            issue_url=existing.get("issue_url"),
            now=now,
        )
        _emit_safe(conn, "issue_duplicate", source_component, f"{fp}:{title}")
        return _result("duplicate", fp, existing.get("issue_url"), count, route.scope, route.repo)

    todo_sh = _resolve_todo_sh(todo_sh_path)
    issue_url: Optional[str] = None
    final_disposition = "failed_to_file"
    issue_number: Optional[int] = None

    if todo_sh:
        issue_url = _invoke_todo_sh(
            todo_sh,
            title,
            _issue_body(
                body,
                item_kind=kind,
                source_component=source_component,
                file_path=file_path,
                evidence=evidence,
                fingerprint_value=fp,
                route=route,
            ),
            route,
        )

    if issue_url:
        final_disposition = "filed"
        match = re.search(r"/issues/(\d+)", issue_url)
        issue_number = int(match.group(1)) if match else None

    count = _upsert_issue(
        conn,
        fp=fp,
        item_kind=kind,
        title=title,
        body=body,
        scope=route.scope,
        repo=route.repo,
        source_component=source_component,
        file_path=file_path,
        evidence=evidence,
        disposition=final_disposition,
        issue_number=issue_number,
        issue_url=issue_url,
        now=now,
    )

    event_type = "issue_filed" if final_disposition == "filed" else "issue_capture_failed"
    _emit_safe(conn, event_type, source_component, f"{fp}:{title}")
    return _result(final_disposition, fp, issue_url, count, route.scope, route.repo)


def _resolve_todo_sh(todo_sh_path: Optional[str]) -> Optional[str]:
    path = todo_sh_path or os.environ.get("CLAUDE_TODO_SH") or _DEFAULT_TODO_SH
    if path and os.path.isfile(path) and os.access(path, os.X_OK):
        return path
    return None


def _invoke_todo_sh(todo_sh: str, title: str, body: str, route: IssueRoute) -> Optional[str]:
    cmd = [todo_sh, "add"]
    if route.scope == "global":
        cmd.append("--global")
    elif route.repo:
        cmd.extend(["--repo", route.repo])
    cmd.append(title)
    if body:
        cmd.append(f"--body={body}")

    try:
        result = subprocess.run(
            cmd,
            cwd=route.cwd or None,
            capture_output=True,
            text=True,
            timeout=30,
        )
        if result.returncode != 0:
            return None
        url = (result.stdout or "").strip()
        return url or None
    except Exception:
        return None


def _upsert_issue(
    conn: sqlite3.Connection,
    *,
    fp: str,
    item_kind: str,
    title: str,
    body: str,
    scope: str,
    repo: str,
    source_component: str,
    file_path: str,
    evidence: str,
    disposition: str,
    issue_number: Optional[int],
    issue_url: Optional[str],
    now: int,
) -> int:
    with conn:
        try:
            conn.execute(
                """
                INSERT INTO issue_captures
                    (fingerprint, item_kind, title, body, scope, repo,
                     source_component, file_path, evidence, disposition,
                     issue_number, issue_url, first_seen_at, last_seen_at,
                     encounter_count)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,1)
                """,
                (
                    fp,
                    item_kind,
                    title,
                    body or "",
                    scope,
                    repo or "",
                    source_component or "",
                    file_path or "",
                    evidence or "",
                    disposition,
                    issue_number,
                    issue_url,
                    now,
                    now,
                ),
            )
            return 1
        except sqlite3.IntegrityError:
            conn.execute(
                """
                UPDATE issue_captures
                SET    disposition = ?,
                       issue_number = COALESCE(?, issue_number),
                       issue_url    = COALESCE(?, issue_url),
                       scope        = ?,
                       repo         = ?,
                       last_seen_at = ?,
                       encounter_count = encounter_count + 1
                WHERE  fingerprint = ?
                """,
                (disposition, issue_number, issue_url, scope, repo or "", now, fp),
            )
            row = conn.execute(
                "SELECT encounter_count FROM issue_captures WHERE fingerprint = ?", (fp,)
            ).fetchone()
            return row["encounter_count"] if row else 1


def _issue_body(
    body: str,
    *,
    item_kind: str,
    source_component: str,
    file_path: str,
    evidence: str,
    fingerprint_value: str,
    route: IssueRoute,
) -> str:
    parts: list[str] = []
    if body:
        parts.append(body)
    parts.append("---")
    parts.append(f"Kind: `{item_kind}`")
    parts.append(f"Route: `{route.scope}` ({route.reason})")
    if route.repo:
        parts.append(f"Repo: `{route.repo}`")
    if source_component:
        parts.append(f"Source: `{source_component}`")
    if file_path:
        parts.append(f"File: `{file_path}`")
    if evidence:
        parts.append("")
        parts.append("Evidence:")
        parts.append(evidence)
    parts.append("")
    parts.append(f"[fingerprint:{fingerprint_value}]")
    return "\n".join(parts)


def _result(
    disposition: str,
    fp: str,
    issue_url: Optional[str],
    encounter_count: int,
    scope: str,
    repo: str,
) -> dict:
    return {
        "disposition": disposition,
        "fingerprint": fp,
        "issue_url": issue_url,
        "encounter_count": encounter_count,
        "scope": scope,
        "repo": repo or "",
    }


def _normalize_text(value: str) -> str:
    normalized = (value or "").lower()
    normalized = re.sub(r"/[^\s]+/([^\s/]+)", r"\1", normalized)
    normalized = re.sub(r"\b\d{9,13}\b", "", normalized)
    normalized = re.sub(r"\b\d+\b", "", normalized)
    return " ".join(normalized.split())


def _mentions_config_path(value: str, config_root: Path) -> bool:
    if not value:
        return False
    expanded = value.replace("~/.claude", str(config_root))
    for token in re.split(r"[\s:]+", expanded):
        if not token:
            continue
        try:
            if _is_within(Path(token).expanduser().resolve(), config_root):
                return True
        except OSError:
            continue
    return False


def _is_within(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False


def _infer_github_repo(path: Path) -> str:
    try:
        result = subprocess.run(
            ["git", "-C", str(path), "remote", "get-url", "origin"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if result.returncode != 0:
            return ""
        return _repo_from_remote(result.stdout.strip())
    except Exception:
        return ""


def _repo_from_remote(remote_url: str) -> str:
    patterns = (
        r"github\.com[:/]([^/\s]+)/([^/\s]+?)(?:\.git)?$",
        r"^([^/\s]+/[^/\s]+?)(?:\.git)?$",
    )
    for pattern in patterns:
        match = re.search(pattern, remote_url)
        if match:
            if len(match.groups()) == 2:
                return f"{match.group(1)}/{match.group(2)}"
            return match.group(1)
    return ""


def _emit_safe(
    conn: sqlite3.Connection,
    event_type: str,
    source: Optional[str],
    detail: Optional[str],
) -> None:
    try:
        events.emit(conn, event_type, source=source or None, detail=detail or None)
    except Exception:
        pass

