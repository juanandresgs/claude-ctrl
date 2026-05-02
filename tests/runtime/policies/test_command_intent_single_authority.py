"""Mechanical pin for CUTOVER_PLAN Invariant #5.

@decision DEC-CLAUDEX-COMMAND-INTENT-SOLE-AUTHORITY-001
Title: runtime.core.command_intent is the sole authority for Bash command-semantics parsing in policies
Status: proposed
Rationale: CUTOVER_PLAN.md Invariant #5 requires that "no policy module reparses
  command semantics already supplied by runtime intent objects." The runtime
  module ``runtime/core/command_intent.py`` owns Bash command-semantics
  classification (subcommand, flags, paths, git_invocation) and is exposed to
  policies via the typed ``PolicyRequest.command_intent`` attribute.  A future
  policy author who imports ``shlex``, calls ``.split(`` on the raw
  ``tool_input["command"]`` string, or otherwise reconstructs parsing logic
  inside a policy module silently creates parallel-parser drift — a class of
  defect identical in shape to the ``bash_workflow_scope`` staged-index and
  ``bash_git_who`` shell-bypass gaps the earlier waves of the cutover already
  closed at neighboring surfaces.

  This test is a scanner: it walks every ``runtime/core/policies/*.py`` module
  with the ``ast`` module and fails if any of three rules is violated:

  - **Rule A (strict):** no policy module imports ``shlex`` (either
    ``import shlex`` or ``from shlex import ...``).
  - **Rule B (strict):** no policy module calls ``.split(`` on a local variable
    whose binding traces back (via simple intraprocedural assignment scan) to
    ``tool_input["command"]`` or ``tool_input.get("command", ...)``.
  - **Rule C (consume-the-authority):** if a policy module accesses raw command
    text via ``tool_input["command"]`` / ``tool_input.get("command", ...)`` AT
    ALL, it MUST also consume the ``command_intent`` authority — either by
    importing ``runtime.core.command_intent`` directly OR by reading
    ``request.command_intent`` as an attribute access. A module that accesses
    only the ``command_intent`` attribute (never the raw text) passes
    trivially; a module that accesses the raw text without any consumption of
    the typed intent fails.

  Three positive synthetic fixtures (shlex-import, tokenizing-split, raw-access-
  without-consume) plus one negative fixture (clean module) prove the scanner
  cannot silently regress.

Adjacent authorities:
  - ``runtime/core/command_intent.py`` — the sole declarative authority; its
    module docstring already calls itself "the single authority for deriving
    structured intent from a raw Bash command string" (verified 2026-04-17).
  - ``MASTER_PLAN.md`` decision log — the release record this pin complements.
  - Invariant #11 mechanical pin at
    ``tests/runtime/test_decision_ref_resolution.py`` — same shape
    (stdlib-only, AST/regex scan, no SQLite / network / subprocess
    dependency).

Shadow-only discipline: this test is stdlib-only (``ast``, ``pathlib``).  It
does not touch ``.claude/state.db``, git, network, or subprocess. An empty
``_KNOWN_EXEMPT_MODULES`` allowlist is provided for explicit, dated exception
entries added by a future follow-on slice; it MUST remain empty unless a
dated comment explains the deferral.
"""

from __future__ import annotations

import ast
import textwrap
from pathlib import Path
from typing import Dict, FrozenSet, List, Set, Tuple

import pytest


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

_POLICIES_DIR = (
    Path(__file__).resolve().parents[3] / "runtime" / "core" / "policies"
)

# Files under _POLICIES_DIR to skip (package plumbing; never a "policy module").
_SKIP_BASENAMES: FrozenSet[str] = frozenset({"__init__.py"})

# Sanctioned-exception allowlist — Rule C exemptions only. Rules A and B
# are absolute (no shlex imports, no .split on raw command) and apply to
# every policy module regardless of this list. Each entry MUST carry a
# dated inline rationale comment explaining why the module accesses raw
# command text without consuming command_intent; the default posture is
# minimum exceptions.
#
# Each exempt module's rationale is captured both here and enforced
# structurally by `test_known_exempt_modules_are_documented` below.
_KNOWN_EXEMPT_MODULES: FrozenSet[str] = frozenset({
    # bash_tmp_safety.py (2026-04-17, DEC-CLAUDEX-COMMAND-INTENT-SOLE-AUTHORITY-001):
    # reads raw `tool_input["command"]` only for literal-substring pattern
    # detection (searches for "/tmp/" and "/private/tmp/" prefixes and
    # rewrites them in a suggested-replacement string). Performs NO
    # command-semantics parsing (no subcommand extraction, no flag parsing,
    # no tokenization). The spirit of Invariant #5 is "don't reparse
    # command semantics already supplied by runtime intent objects";
    # literal-string membership/replace does not meet that bar. Refactoring
    # this module to import `command_intent` would add coupling without
    # changing its behavior. Exempted explicitly rather than silently.
    "bash_tmp_safety.py",
})

# Per-module rationale tokens that MUST appear in the test-file source
# above, keyed by exempt module basename. This test-file-level pin
# ensures a future author cannot silently add to `_KNOWN_EXEMPT_MODULES`
# without carrying a dated rationale comment alongside the entry.
_EXEMPT_MODULE_RATIONALE_TOKENS: Dict[str, str] = {
    "bash_tmp_safety.py": "literal-substring pattern detection",
}

# Module name the `from runtime.core.command_intent import ...` and
# `import runtime.core.command_intent` forms must match.
_COMMAND_INTENT_MODULE = "runtime.core.command_intent"

# Attribute access pattern the runtime exposes on PolicyRequest.
_COMMAND_INTENT_ATTR = "command_intent"


# ---------------------------------------------------------------------------
# AST helpers — pure stdlib, no imports of runtime.core or policies.
# ---------------------------------------------------------------------------


def _iter_policy_files(root: Path = _POLICIES_DIR) -> List[Path]:
    """Return sorted .py files directly under the policies directory,
    excluding `__init__.py` and any `__pycache__` entries. Deterministic
    for stable test output.
    """
    files: List[Path] = []
    for path in sorted(root.iterdir()):
        if not path.is_file():
            continue
        if path.suffix != ".py":
            continue
        if path.name in _SKIP_BASENAMES:
            continue
        files.append(path)
    return files


def _parse(path: Path) -> ast.AST:
    return ast.parse(path.read_text(encoding="utf-8"), filename=str(path))


def _parse_source(source: str, filename: str = "<fixture>") -> ast.AST:
    return ast.parse(textwrap.dedent(source), filename=filename)


def _imports_shlex(tree: ast.AST) -> List[Tuple[int, str]]:
    """Return (lineno, import_form) pairs for any ``import shlex`` or
    ``from shlex import ...`` occurrences in the module.
    """
    hits: List[Tuple[int, str]] = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                if alias.name == "shlex" or alias.name.startswith("shlex."):
                    hits.append((node.lineno, f"import {alias.name}"))
        elif isinstance(node, ast.ImportFrom):
            if node.module == "shlex":
                hits.append((node.lineno, f"from shlex import ..."))
    return hits


def _imports_command_intent(tree: ast.AST) -> bool:
    """True if the module imports ``runtime.core.command_intent`` in any form."""
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                if alias.name == _COMMAND_INTENT_MODULE:
                    return True
        elif isinstance(node, ast.ImportFrom):
            if node.module == _COMMAND_INTENT_MODULE:
                return True
    return False


def _accesses_command_intent_attribute(tree: ast.AST) -> bool:
    """True if the module reads ``request.command_intent`` (or any attribute
    named ``command_intent``) anywhere. This is the "consume the typed
    authority" pathway policies normally use.
    """
    for node in ast.walk(tree):
        if isinstance(node, ast.Attribute) and node.attr == _COMMAND_INTENT_ATTR:
            return True
    return False


def _is_tool_input_command_expr(node: ast.AST) -> bool:
    """True if ``node`` is an expression that evaluates to the raw command
    string from a tool-input mapping. Recognized forms:

      - ``tool_input["command"]``
      - ``tool_input.get("command")``
      - ``tool_input.get("command", <default>)``
      - ``request.tool_input["command"]``
      - ``request.tool_input.get("command")`` / with default

    The receiver must be an attribute/name chain ending in ``tool_input``.
    """
    # Subscript form: tool_input["command"] / request.tool_input["command"]
    if isinstance(node, ast.Subscript):
        if not _chain_ends_with_name(node.value, "tool_input"):
            return False
        key = _constant_string_of_slice(node.slice)
        return key == "command"

    # Call form: tool_input.get("command", ...) / request.tool_input.get("command", ...)
    if isinstance(node, ast.Call):
        func = node.func
        if not isinstance(func, ast.Attribute):
            return False
        if func.attr != "get":
            return False
        if not _chain_ends_with_name(func.value, "tool_input"):
            return False
        if not node.args:
            return False
        first = node.args[0]
        return isinstance(first, ast.Constant) and first.value == "command"

    return False


def _chain_ends_with_name(node: ast.AST, name: str) -> bool:
    """True if ``node`` is ``Name(name)`` or ``Attribute(..., attr=name)``."""
    if isinstance(node, ast.Name) and node.id == name:
        return True
    if isinstance(node, ast.Attribute) and node.attr == name:
        return True
    return False


def _constant_string_of_slice(slice_node: ast.AST) -> str:
    """Return the string value of a subscript slice, or '' if not a constant."""
    # On Python 3.9+, the slice is the node itself (no Index wrapper).
    if isinstance(slice_node, ast.Constant) and isinstance(slice_node.value, str):
        return slice_node.value
    return ""


def _raw_command_access_sites(tree: ast.AST) -> List[int]:
    """Return line numbers where the module accesses raw command text via
    ``tool_input["command"]`` / ``.get("command", ...)``.
    """
    hits: List[int] = []
    for node in ast.walk(tree):
        if _is_tool_input_command_expr(node):
            hits.append(getattr(node, "lineno", -1))
    return hits


def _raw_command_bindings(tree: ast.AST) -> Dict[str, int]:
    """Map local variable names to the lineno of their LAST assignment from a
    raw-command-access expression. Supports simple patterns:

        command = request.tool_input.get("command", "")
        cmd = tool_input["command"]

    Tuple / augmented / annotated / walrus assignments are NOT traced; the
    rule is intentionally strict in the other direction — a developer who
    needs tokenization MUST go through the typed intent, so the scanner
    conservatively misses exotic assignment forms rather than flagging them.
    """
    bindings: Dict[str, int] = {}
    for node in ast.walk(tree):
        if not isinstance(node, ast.Assign):
            continue
        if not _is_tool_input_command_expr(node.value):
            continue
        for target in node.targets:
            if isinstance(target, ast.Name):
                bindings[target.id] = node.lineno
    return bindings


def _tokenizing_split_sites(tree: ast.AST) -> List[Tuple[int, str]]:
    """Return (lineno, receiver_name) for every ``.split(`` call whose receiver
    is a local name bound to a raw-command-access expression. Also catches
    ``tool_input["command"].split(...)`` / ``tool_input.get("command").split(...)``
    used inline.
    """
    bindings = _raw_command_bindings(tree)
    hits: List[Tuple[int, str]] = []
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        if not isinstance(node.func, ast.Attribute) or node.func.attr != "split":
            continue
        receiver = node.func.value
        # Inline form: <raw-command-expr>.split(...)
        if _is_tool_input_command_expr(receiver):
            hits.append((node.lineno, "<inline tool_input command>"))
            continue
        # Bound-variable form: cmd.split(...) where cmd came from raw command.
        if isinstance(receiver, ast.Name) and receiver.id in bindings:
            hits.append((node.lineno, receiver.id))
    return hits


# ---------------------------------------------------------------------------
# Live-repo tests
# ---------------------------------------------------------------------------


class TestNoPolicyImportsShlex:
    """Rule A: no policy module imports shlex.

    This rule is ABSOLUTE: `_KNOWN_EXEMPT_MODULES` does NOT apply here.
    Exemptions are Rule C only. A future author accidentally granting
    shlex-import exemption by adding a module to the allowlist must not be
    able to bypass this scan.
    """

    def test_no_policy_imports_shlex(self) -> None:
        violations: List[str] = []
        for path in _iter_policy_files():
            # Intentionally NOT checking _KNOWN_EXEMPT_MODULES: Rule A is
            # absolute per the module-docstring contract.
            for lineno, form in _imports_shlex(_parse(path)):
                violations.append(f"{path.name}:{lineno}: {form}")
        assert not violations, (
            "Rule A violation — policy modules must not import shlex (raw Bash "
            "tokenization belongs in runtime/core/command_intent.py, not in "
            "policies). Use `request.command_intent` instead. Rule A is "
            "absolute and is NOT suppressed by _KNOWN_EXEMPT_MODULES.\n"
            + "\n".join(f"  - {v}" for v in violations)
        )


class TestNoPolicySplitsRawCommand:
    """Rule B: no policy module calls .split( on raw command text.

    This rule is ABSOLUTE: `_KNOWN_EXEMPT_MODULES` does NOT apply here.
    Exemptions are Rule C only. Tokenization of raw command text in a
    policy module reintroduces parallel-parser drift regardless of any
    allowlist.
    """

    def test_no_policy_splits_raw_command(self) -> None:
        violations: List[str] = []
        for path in _iter_policy_files():
            # Intentionally NOT checking _KNOWN_EXEMPT_MODULES: Rule B is
            # absolute per the module-docstring contract.
            for lineno, receiver in _tokenizing_split_sites(_parse(path)):
                violations.append(
                    f"{path.name}:{lineno}: .split( called on {receiver}"
                )
        assert not violations, (
            "Rule B violation — policy modules must not tokenize raw command "
            "text with .split(). Consume the pre-parsed structure via "
            "`request.command_intent` (subcommand, flags, paths, git_invocation) "
            "instead of reimplementing tokenization. Rule B is absolute and is "
            "NOT suppressed by _KNOWN_EXEMPT_MODULES.\n"
            + "\n".join(f"  - {v}" for v in violations)
        )


class TestPoliciesThatAccessRawCommandConsumeCommandIntent:
    """Rule C: if a policy accesses raw command text, it must consume
    ``command_intent`` (either via direct import of
    ``runtime.core.command_intent`` or via attribute access on the request
    object: ``request.command_intent``).
    """

    def test_policies_that_access_raw_command_consume_command_intent(self) -> None:
        violations: List[str] = []
        for path in _iter_policy_files():
            if path.name in _KNOWN_EXEMPT_MODULES:
                continue
            tree = _parse(path)
            access_lines = _raw_command_access_sites(tree)
            if not access_lines:
                continue
            if _imports_command_intent(tree):
                continue
            if _accesses_command_intent_attribute(tree):
                continue
            violations.append(
                f"{path.name}: accesses raw command text at line(s) "
                f"{access_lines} but does not consume command_intent "
                "(neither imports runtime.core.command_intent nor reads "
                "request.command_intent)."
            )
        assert not violations, (
            "Rule C violation — policy modules that read raw "
            "`tool_input['command']` must also consume the typed "
            "`command_intent` authority so command-semantics parsing is "
            "centralized. Either import `runtime.core.command_intent` or "
            "read `request.command_intent` on the PolicyRequest.\n"
            + "\n".join(f"  - {v}" for v in violations)
        )


# ---------------------------------------------------------------------------
# Synthetic fixtures — prove the scanner catches violations AND accepts
# clean modules. These run against in-memory AST strings, never writing to
# disk or mutating real policy modules.
# ---------------------------------------------------------------------------


_CLEAN_FIXTURE = """
    from runtime.core.command_intent import CommandIntent
    from runtime.core.policy_engine import PolicyDecision, PolicyRequest

    def check(request):
        intent = request.command_intent
        if intent is None:
            return None
        if intent.git_invocation and intent.git_invocation.subcommand == "commit":
            return PolicyDecision(action="allow", reason="", policy_name="synth")
        return None
"""


_SHLEX_IMPORT_FIXTURE = """
    import shlex
    from runtime.core.policy_engine import PolicyDecision

    def check(request):
        tokens = shlex.split(request.tool_input.get("command", ""))
        return None
"""


_SPLIT_ON_RAW_COMMAND_FIXTURE = """
    from runtime.core.policy_engine import PolicyDecision

    def check(request):
        command = request.tool_input.get("command", "")
        parts = command.split()
        if parts and parts[0] == "git":
            return None
        return None
"""


_SPLIT_INLINE_ON_RAW_COMMAND_FIXTURE = """
    from runtime.core.policy_engine import PolicyDecision

    def check(request):
        first = request.tool_input["command"].split()[0]
        return None
"""


_RAW_ACCESS_WITHOUT_CONSUME_FIXTURE = """
    from runtime.core.policy_engine import PolicyDecision

    def check(request):
        command = request.tool_input.get("command", "")
        if "dangerous" in command:
            return PolicyDecision(action="deny", reason="", policy_name="synth")
        return None
"""


class TestScannerCatchesSyntheticViolations:
    """Positive fixtures — the scanner must detect each class of drift."""

    def test_catches_shlex_import(self) -> None:
        tree = _parse_source(_SHLEX_IMPORT_FIXTURE)
        assert _imports_shlex(tree), (
            "scanner failed to detect `import shlex` in synthetic fixture"
        )

    def test_catches_split_on_bound_raw_command(self) -> None:
        tree = _parse_source(_SPLIT_ON_RAW_COMMAND_FIXTURE)
        sites = _tokenizing_split_sites(tree)
        assert sites, (
            "scanner failed to detect .split() on a variable bound to "
            "tool_input.get('command') in synthetic fixture"
        )
        # And the receiver name should match the synthetic binding.
        assert any(r == "command" for _, r in sites), (
            f"expected receiver 'command' in tokenizing split sites; got {sites}"
        )

    def test_catches_split_inline_on_raw_command(self) -> None:
        tree = _parse_source(_SPLIT_INLINE_ON_RAW_COMMAND_FIXTURE)
        sites = _tokenizing_split_sites(tree)
        assert sites, (
            "scanner failed to detect inline `tool_input['command'].split()` "
            "in synthetic fixture"
        )

    def test_catches_raw_access_without_command_intent_consumption(self) -> None:
        tree = _parse_source(_RAW_ACCESS_WITHOUT_CONSUME_FIXTURE)
        access_lines = _raw_command_access_sites(tree)
        assert access_lines, (
            "scanner failed to detect raw tool_input command access in "
            "synthetic fixture"
        )
        assert not _imports_command_intent(tree)
        assert not _accesses_command_intent_attribute(tree)


class TestScannerAcceptsCleanModule:
    """Negative fixture — a clean module must pass all three rules."""

    def test_clean_module_passes_all_rules(self) -> None:
        tree = _parse_source(_CLEAN_FIXTURE)
        assert not _imports_shlex(tree)
        assert not _tokenizing_split_sites(tree)
        # Clean module does not access raw command text; Rule C is trivially met.
        assert not _raw_command_access_sites(tree)
        # And for belt-and-suspenders: direct import IS present, so Rule C
        # would pass even if raw access existed.
        assert _imports_command_intent(tree)


class TestModuleSurface:
    """Sanity pin so the scanner itself cannot silently return empty sets."""

    def test_scanner_finds_at_least_one_policy_module(self) -> None:
        files = _iter_policy_files()
        assert len(files) >= 10, (
            f"scanner only found {len(files)} policy modules under "
            f"{_POLICIES_DIR}; the policies directory is expected to contain "
            "at least 10 concrete policy modules. Scanner may be broken."
        )

    def test_known_exempt_modules_are_documented(self) -> None:
        """Every entry in _KNOWN_EXEMPT_MODULES must carry a corresponding
        entry in _EXEMPT_MODULE_RATIONALE_TOKENS, and that rationale token
        must appear verbatim in this test file's source. This guards against
        a future author silently expanding the allowlist without recording
        a dated rationale comment.
        """
        own_source = Path(__file__).read_text(encoding="utf-8")
        for module_name in _KNOWN_EXEMPT_MODULES:
            assert module_name in _EXEMPT_MODULE_RATIONALE_TOKENS, (
                f"_KNOWN_EXEMPT_MODULES contains {module_name!r} but "
                f"_EXEMPT_MODULE_RATIONALE_TOKENS has no entry for it. Every "
                "exempt module must carry a documented rationale."
            )
            rationale_token = _EXEMPT_MODULE_RATIONALE_TOKENS[module_name]
            assert rationale_token in own_source, (
                f"Exempt module {module_name!r} names rationale token "
                f"{rationale_token!r}, but that token does not appear in "
                f"this test file. Add a dated inline rationale comment "
                "explaining the exemption."
            )

    def test_exempt_rationale_tokens_have_matching_allowlist_entries(self) -> None:
        """Inverse pin: every key in _EXEMPT_MODULE_RATIONALE_TOKENS must
        correspond to a real entry in _KNOWN_EXEMPT_MODULES. Prevents
        stale rationale entries from persisting after the allowlist is
        tightened.
        """
        stale = [
            name for name in _EXEMPT_MODULE_RATIONALE_TOKENS
            if name not in _KNOWN_EXEMPT_MODULES
        ]
        assert not stale, (
            f"_EXEMPT_MODULE_RATIONALE_TOKENS has stale entries no longer "
            f"in _KNOWN_EXEMPT_MODULES: {stale}. Remove them."
        )


class TestRuleABAbsoluteNoExemptBypass:
    """Scanner-self invariant: Rules A and B MUST scan every policy module
    regardless of ``_KNOWN_EXEMPT_MODULES``. Exemptions are Rule C only.

    A prior version of this test file incorrectly included
    ``if path.name in _KNOWN_EXEMPT_MODULES: continue`` at the top of Rule A
    and Rule B loops, which silently allowed any exempt module to import
    ``shlex`` or call ``.split(`` on raw command text without being caught.
    These tests pin the corrected behavior by static analysis of this file's
    own source: the Rule A / Rule B test bodies must NOT consult the exempt
    allowlist. A future regression that reintroduces the `continue`-on-exempt
    pattern inside those test bodies will fail here.
    """

    def _parse_own_source(self) -> ast.Module:
        source = Path(__file__).read_text(encoding="utf-8")
        return ast.parse(source, filename=__file__)

    def _find_test_function(
        self, module: ast.Module, class_name: str, method_name: str
    ) -> ast.FunctionDef:
        for node in module.body:
            if isinstance(node, ast.ClassDef) and node.name == class_name:
                for item in node.body:
                    if (
                        isinstance(item, ast.FunctionDef)
                        and item.name == method_name
                    ):
                        return item
        raise AssertionError(
            f"Could not find {class_name}.{method_name} in "
            f"{Path(__file__).name}; scanner-self invariant is broken."
        )

    def _body_references_known_exempt_modules(self, func: ast.FunctionDef) -> bool:
        """Return True if any Name('_KNOWN_EXEMPT_MODULES') appears in the
        function body's AST. Catches both `in _KNOWN_EXEMPT_MODULES` checks
        and any other read of the allowlist.
        """
        for node in ast.walk(func):
            if isinstance(node, ast.Name) and node.id == "_KNOWN_EXEMPT_MODULES":
                return True
        return False

    def test_rule_a_does_not_reference_known_exempt_modules(self) -> None:
        module = self._parse_own_source()
        func = self._find_test_function(
            module, "TestNoPolicyImportsShlex", "test_no_policy_imports_shlex"
        )
        assert not self._body_references_known_exempt_modules(func), (
            "Rule A regression: test_no_policy_imports_shlex() must NOT "
            "reference _KNOWN_EXEMPT_MODULES in its body. Rule A is absolute "
            "per the module-docstring contract. If you intended to exempt a "
            "module from Rule A, do NOT — Rules A and B have no allowlist "
            "bypass by design."
        )

    def test_rule_b_does_not_reference_known_exempt_modules(self) -> None:
        module = self._parse_own_source()
        func = self._find_test_function(
            module, "TestNoPolicySplitsRawCommand", "test_no_policy_splits_raw_command"
        )
        assert not self._body_references_known_exempt_modules(func), (
            "Rule B regression: test_no_policy_splits_raw_command() must NOT "
            "reference _KNOWN_EXEMPT_MODULES in its body. Rule B is absolute "
            "per the module-docstring contract. If you intended to exempt a "
            "module from Rule B, do NOT — Rules A and B have no allowlist "
            "bypass by design."
        )

    def test_rule_c_does_reference_known_exempt_modules(self) -> None:
        """Counterpart pin: Rule C IS where exemptions apply. If the Rule C
        test body stops consulting `_KNOWN_EXEMPT_MODULES`, the allowlist
        becomes dead code and the exemption contract degrades. This test
        keeps the allowlist wired to Rule C specifically.
        """
        module = self._parse_own_source()
        func = self._find_test_function(
            module,
            "TestPoliciesThatAccessRawCommandConsumeCommandIntent",
            "test_policies_that_access_raw_command_consume_command_intent",
        )
        assert self._body_references_known_exempt_modules(func), (
            "Rule C wiring regression: "
            "test_policies_that_access_raw_command_consume_command_intent() "
            "must reference _KNOWN_EXEMPT_MODULES in its body (that is the "
            "only rule that honors the allowlist). If the reference has been "
            "removed, the allowlist is now dead code and the exemption "
            "contract no longer applies."
        )
