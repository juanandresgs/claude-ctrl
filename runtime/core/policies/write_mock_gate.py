"""write_mock_gate policy — escalating internal-mock detection gate.

Port of hooks/mock-gate.sh (184 lines).

Only inspects test files. Non-test source files are always allowed.
Test files with @mock-exempt annotation are always allowed.
Test files with only external-boundary mocks are allowed.
Test files with internal mocks get escalating strikes.

Logic:
  - Non-test files → ALLOW
  - @mock-exempt annotation → ALLOW
  - External-boundary mocks only → ALLOW
  - Internal mocks detected:
      Strike 1 → ALLOW with advisory feedback
      Strike 2+ → DENY

@decision DEC-PE-W5-003
Title: write_mock_gate is a Python port of mock-gate.sh, registered at priority 750
Status: accepted
Rationale: mock-gate.sh enforced Sacred Practice #5 (real tests, not mocks) by
  scanning test-file writes for internal mocking patterns. PE-W5 migrates this
  to a PolicyRegistry-registered Python policy. The policy reads content from
  tool_input directly (no I/O) and manages a strikes flat file under project_root.
  Priority 750 places it after test_gate_pretool (650) and doc_gate (700).
  The original shell hook stays as a no-op adapter — settings.json wiring unchanged.
"""

from __future__ import annotations

import os
import re
import time
from typing import Optional

from runtime.core.policy_engine import PolicyDecision, PolicyRequest
from runtime.core.policy_utils import PATH_KIND_OTHER, PATH_KIND_SOURCE, classify_policy_path

# ---------------------------------------------------------------------------
# Test file detection
# ---------------------------------------------------------------------------


def _is_test_file(file_path: str) -> bool:
    """Return True if file_path looks like a test file."""
    return (
        ".test." in file_path
        or ".spec." in file_path
        or "__tests__/" in file_path
        or file_path.endswith("_test.go")
        or file_path.endswith("_test.py")
        or os.path.basename(file_path).startswith("test_")
        or "/tests/" in file_path
        or "/test/" in file_path
    )


# ---------------------------------------------------------------------------
# External boundary patterns — these are always OK to mock
# ---------------------------------------------------------------------------

# Python: external module paths commonly mocked at service boundaries
_PY_EXTERNAL_RE = re.compile(
    r"(requests\.|httpx\.|redis\.|psycopg|sqlalchemy\.|urllib\.|http\.client"
    r"|smtplib\.|socket\.|subprocess\.|os\.environ|boto3\.|botocore\.|aiohttp\."
    r"|httplib2\.|pymongo\.|mysql\.|sqlite3\.|psutil\.|paramiko\.|ftplib\.)",
    re.IGNORECASE,
)

# JS/TS: external libraries commonly mocked
_JS_EXTERNAL_RE = re.compile(
    r"(axios|node-fetch|cross-fetch|undici|['\"]http['\"]|['\"]https['\"]"
    r"|['\"]fs['\"]|['\"]net['\"]|['\"]dns['\"]|child_process|nodemailer"
    r"|ioredis|['\"]pg['\"]|mysql|mongodb|aws-sdk|@aws-sdk|googleapis"
    r"|stripe|twilio)",
    re.IGNORECASE,
)

# Test framework libraries that replace real boundaries (always OK)
_BOUNDARY_LIB_RE = re.compile(
    r"(pytest-httpx|httpretty|responses\.|respx\.|nock\(|msw|@mswjs"
    r"|wiremock|testcontainers|dockertest)",
    re.IGNORECASE,
)

# Python internal mock patterns
_PY_MOCK_IMPORT_RE = re.compile(
    r"(from\s+unittest\.mock\s+import|from\s+unittest\s+import\s+mock"
    r"|MagicMock|@patch\b|mock\.patch|mocker\.patch)"
)

_PY_PATCH_TARGET_RE = re.compile(r"""(?:@patch|mock\.patch|mocker\.patch)\(['"]([\w.]+)""")

# JS/TS internal mock patterns
_JS_MOCK_RE = re.compile(
    r"(jest\.mock\(|vi\.mock\(|\.mockImplementation|\.mockReturnValue"
    r"|\.mockResolvedValue|sinon\.stub|sinon\.mock)"
)

_JS_MOCK_TARGET_RE = re.compile(r"""(?:jest|vi)\.mock\(['"]([\w./@-]+)""")


# ---------------------------------------------------------------------------
# Mock detection helpers
# ---------------------------------------------------------------------------


def _has_internal_py_mock(content: str) -> bool:
    """Return True if content contains Python mocks targeting internal code."""
    if not _PY_MOCK_IMPORT_RE.search(content):
        return False

    # Find patch targets
    targets = _PY_PATCH_TARGET_RE.findall(content)
    if targets:
        # If ALL targets are external boundaries, allow
        for target in targets:
            if not _PY_EXTERNAL_RE.search(target):
                return True  # at least one internal target
        return False  # all external

    # MagicMock or bare mock import without @patch — likely internal
    if re.search(r"MagicMock", content):
        return True

    # Has mock import but no determinable targets
    return True


def _has_internal_js_mock(content: str) -> bool:
    """Return True if content contains JS/TS mocks targeting internal code."""
    if not _JS_MOCK_RE.search(content):
        return False

    # Find jest.mock/vi.mock targets
    targets = _JS_MOCK_TARGET_RE.findall(content)
    if targets:
        for target in targets:
            if not _JS_EXTERNAL_RE.search(target):
                return True  # at least one internal target
        # All targets were external — but check for implementation mocks
    else:
        # No mock() targets found but has .mockImplementation etc. — likely internal
        if re.search(r"\.mockImplementation|\.mockReturnValue|\.mockResolvedValue", content):
            return True

    return False


def _has_go_mock(content: str) -> bool:
    """Return True if content contains Go internal mock patterns."""
    return bool(re.search(r"(gomock\.|mockgen|NewMockController|EXPECT\(\)\.)", content))


def _has_internal_mock(content: str) -> bool:
    """Return True if content has internal mock patterns not covered by boundary libs."""
    # Boundary-only test libraries are always OK
    if _BOUNDARY_LIB_RE.search(content):
        # If ONLY boundary libs and no internal mock patterns, allow
        if not _has_internal_py_mock(content) and not _has_internal_js_mock(content):
            return False

    return _has_internal_py_mock(content) or _has_internal_js_mock(content) or _has_go_mock(content)


# ---------------------------------------------------------------------------
# Strikes file helpers
# ---------------------------------------------------------------------------


def _strikes_path(project_root: str) -> str:
    return os.path.join(project_root, ".claude", ".mock-gate-strikes")


def _read_strikes(project_root: str) -> int:
    path = _strikes_path(project_root)
    try:
        raw = open(path).read().strip()
        return int(raw.split("|")[0])
    except Exception:
        return 0


def _write_strikes(project_root: str, count: int) -> None:
    path = _strikes_path(project_root)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(f"{count}|{int(time.time())}")


# ---------------------------------------------------------------------------
# Policy function
# ---------------------------------------------------------------------------


def mock_gate(request: PolicyRequest) -> Optional[PolicyDecision]:
    """Detect internal mocking patterns in test file writes.

    Skip conditions (return None):
      - No file_path in tool_input
      - File is not a test file
      - No content in tool_input
      - @mock-exempt annotation present
      - Only external-boundary mocks detected

    Escalating action when internal mocks detected:
      Strike 1 → feedback (advisory)
      Strike 2+ → deny
    """
    file_path: str = request.tool_input.get("file_path", "")
    if not file_path:
        return None

    info = classify_policy_path(
        file_path,
        project_root=request.context.project_root or "",
        worktree_path=request.context.worktree_path or "",
        scratch_roots=request.context.scratchlane_roots,
    )
    if info.kind not in {PATH_KIND_SOURCE, PATH_KIND_OTHER}:
        return None

    # Only inspect test files
    if not _is_test_file(file_path):
        return None

    # Get content from Write or Edit tool input
    content: str = request.tool_input.get("content", "") or request.tool_input.get("new_string", "")
    if not content:
        return None

    # @mock-exempt annotation bypasses all detection
    if "@mock-exempt" in content:
        return None

    # Check for internal mock patterns
    if not _has_internal_mock(content):
        return None

    # Internal mock detected — apply escalating strikes
    project_root = request.context.project_root or ""
    current_strikes = _read_strikes(project_root) if project_root else 0
    new_strikes = current_strikes + 1
    if project_root:
        _write_strikes(project_root, new_strikes)

    if new_strikes >= 2:
        return PolicyDecision(
            action="deny",
            reason=(
                f"Sacred Practice #5: Tests must use real implementations, not mocks. "
                f"This test file uses mocks for internal code (strike {new_strikes}). "
                "Refactor to use fixtures, factories, or in-memory implementations for internal "
                "code. Mocks are only permitted for external service boundaries (HTTP APIs, "
                "databases, third-party services). Add '# @mock-exempt: <reason>' if mocking "
                "is truly necessary here."
            ),
            policy_name="mock_gate",
        )

    # Strike 1: advisory feedback
    return PolicyDecision(
        action="feedback",
        reason=(
            "Sacred Practice #5: This test uses mocks for internal code. "
            "Prefer real implementations — use fixtures, factories, or in-memory implementations. "
            "Mocks are acceptable only for external boundaries (HTTP, DB, third-party APIs). "
            "Next mock-heavy test write will be blocked. "
            "Add '# @mock-exempt: <reason>' if mocking is truly necessary."
        ),
        policy_name="mock_gate",
    )
