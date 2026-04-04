"""write_doc_gate policy — enforce documentation headers and @decision annotations.

Port of hooks/doc-gate.sh (246 lines).

Enforces two properties on source file writes:
  1. Every source file must start with a documentation header comment.
  2. Files 50+ lines must contain a @decision annotation.

For Write tool: checks tool_input.content directly.
For Edit tool: advisory only — the file already exists and may be receiving a fix.
Markdown files in project root that are not operational docs receive feedback
(Sacred Practice #9 — deferred work belongs in GitHub issues).

@decision DEC-PE-W5-001
Title: write_doc_gate is a Python port of doc-gate.sh, registered at priority 700
Status: accepted
Rationale: doc-gate.sh enforced header and @decision requirements via bash.
  PE-W5 migrates this logic to a PolicyRegistry-registered Python policy so
  that it fires automatically when pre-write.sh calls cc-policy evaluate.
  The shell hook remains as a no-op adapter (settings.json wiring unchanged).
  Priority 700 places it after WHO/plan/decision-log checks but before end of chain.
  Edit tool logic is advisory only (feedback, never deny) — the edit might
  BE adding the header or annotation. Only Write (creating new file content)
  issues hard denies for missing headers on source files.
"""

from __future__ import annotations

import os
import re
from typing import Optional

from runtime.core.policy_engine import PolicyDecision, PolicyRequest
from runtime.core.policy_utils import is_skippable_path, is_source_file

# ---------------------------------------------------------------------------
# Operational markdown files in project root — always allowed
# ---------------------------------------------------------------------------

_OPERATIONAL_MD = frozenset(
    {
        "CLAUDE.md",
        "README.md",
        "MASTER_PLAN.md",
        "AGENTS.md",
        "CHANGELOG.md",
        "LICENSE.md",
        "CONTRIBUTING.md",
        "HOOKS.md",
    }
)

# ---------------------------------------------------------------------------
# @decision detection pattern
# ---------------------------------------------------------------------------

_DECISION_RE = re.compile(r"@decision|# DECISION:|// DECISION:")

# ---------------------------------------------------------------------------
# Header detection patterns by extension
# ---------------------------------------------------------------------------


def _has_doc_header(content: str, ext: str) -> bool:
    """Return True if content starts with an appropriate documentation header.

    Mirrors has_doc_header() in doc-gate.sh.
    """
    lines = content.splitlines()
    # Strip blank lines and shebangs to find first meaningful line
    first_meaningful = ""
    for line in lines:
        stripped = line.strip()
        if not stripped:
            continue
        if stripped.startswith("#!"):
            continue
        first_meaningful = stripped
        break

    if not first_meaningful:
        return False

    if ext == "py":
        # Python: triple-quote docstring or # comment
        return bool(re.match(r'("""|\'\'\'|#\s*\S)', first_meaningful))
    elif ext in ("ts", "tsx", "js", "jsx"):
        # JS/TS: /** or //
        return bool(re.match(r"(/\*\*|//\s*\S)", first_meaningful))
    elif ext == "go":
        return bool(re.match(r"//\s*\S", first_meaningful))
    elif ext == "rs":
        return bool(re.match(r"//(!\s*\S|/?\s*\S)", first_meaningful))
    elif ext in ("sh", "bash", "zsh"):
        return bool(re.match(r"#\s*\S", first_meaningful))
    elif ext in ("c", "cpp", "h", "hpp", "cs"):
        return bool(re.match(r"(/\*\*|//\s*\S)", first_meaningful))
    elif ext in ("java", "kt", "swift"):
        return bool(re.match(r"(/\*\*|//\s*\S)", first_meaningful))
    elif ext == "rb":
        return bool(re.match(r"#\s*\S", first_meaningful))
    else:
        return bool(re.match(r"(/\*|//|#)\s*\S", first_meaningful))


def _has_decision(content: str) -> bool:
    """Return True if content contains a @decision annotation."""
    return bool(_DECISION_RE.search(content))


# ---------------------------------------------------------------------------
# Policy function
# ---------------------------------------------------------------------------


def doc_gate(request: PolicyRequest) -> Optional[PolicyDecision]:
    """Enforce documentation headers and @decision annotations on source writes.

    Skip conditions (return None):
      - No file_path in tool_input
      - File is under {project_root}/.claude/
      - File is not a source file (markdown, JSON, etc.)
      - File is a skippable path (vendor, node_modules, etc.)
      - Edit tool on non-source file

    Markdown in project root (Write of new non-operational .md):
      - Return "feedback" advisory (Sacred Practice #9)

    Write of source file:
      - Deny if no doc header
      - Deny if 50+ lines and no @decision

    Edit of source file:
      - Advisory "feedback" only (never deny) — edit may be adding the header
    """
    file_path: str = request.tool_input.get("file_path", "")
    if not file_path:
        return None

    project_root = request.context.project_root or ""

    # Skip meta-infrastructure
    if project_root and file_path.startswith(os.path.join(project_root, ".claude") + os.sep):
        return None

    tool_name = request.tool_name  # "Write" or "Edit"
    ext = file_path.rsplit(".", 1)[-1].lower() if "." in file_path else ""

    # --- Markdown in project root advisory ---
    if file_path.endswith(".md") and tool_name == "Write":
        file_dir = os.path.dirname(file_path)
        if project_root and os.path.normpath(file_dir) == os.path.normpath(project_root):
            file_name = os.path.basename(file_path)
            if file_name not in _OPERATIONAL_MD and not os.path.exists(file_path):
                return PolicyDecision(
                    action="feedback",
                    reason=(
                        f"Creating new markdown file '{file_name}' in project root. "
                        "Sacred Practice #9: Track deferred work in GitHub issues, not standalone "
                        "files. Consider: gh issue create --title '...' instead."
                    ),
                    policy_name="doc_gate",
                )
        return None

    # Only enforce on source files
    if not is_source_file(file_path):
        return None

    # Skip vendor, node_modules, etc.
    if is_skippable_path(file_path):
        return None

    if tool_name == "Write":
        content: str = request.tool_input.get("content", "")
        if not content:
            return None

        if not _has_doc_header(content, ext):
            return PolicyDecision(
                action="deny",
                reason=(
                    f"File {file_path} missing documentation header. "
                    "Every source file must start with a documentation comment describing "
                    "purpose and rationale."
                ),
                policy_name="doc_gate",
            )

        line_count = content.count("\n") + (1 if content and not content.endswith("\n") else 0)
        if line_count >= 50 and not _has_decision(content):
            return PolicyDecision(
                action="deny",
                reason=(
                    f"File {file_path} is {line_count} lines but has no @decision annotation. "
                    "Significant files (50+ lines) require a @decision annotation. "
                    "See CLAUDE.md for format examples."
                ),
                policy_name="doc_gate",
            )

        return None

    if tool_name == "Edit":
        # Advisory only for edits — the edit may be adding the header/annotation
        # Return None (no opinion) — the Edit hook in the shell was advisory anyway
        return None

    return None
