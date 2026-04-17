"""Policy: bash_workflow_scope — enforce workflow binding + scope on commit/merge.

Port of guard.sh lines 368-422 (Check 12).

@decision DEC-PE-W3-010
Title: bash_workflow_scope uses context.binding and context.scope as sole authorities
Status: accepted
Rationale: guard.sh Check 12 queries the DB for binding and scope, then runs
  git diff to get changed files, then calls rt_workflow_scope_check.
  build_context() has already loaded binding and scope into PolicyContext.
  The changed-file list still requires a git subprocess (it is dynamic, not
  pre-loaded) but is the only I/O this policy performs.

  check_scope_compliance() from workflows.py requires a DB connection — we
  cannot call it in a pure policy function. Instead we replicate the matching
  logic inline using the scope data already loaded into context.scope. This
  avoids introducing a conn dependency into the policy layer. The logic is
  simple enough (fnmatch + forbidden-first) to duplicate safely.

  If either binding or scope is missing, we deny with guidance. This mirrors
  guard.sh sub-checks A and B before the compliance check.
"""

from __future__ import annotations

import fnmatch
import subprocess
from typing import Optional

from runtime.core.leases import GitInvocation
from runtime.core.policy_engine import PolicyDecision, PolicyRequest
from runtime.core.policy_utils import (
    current_workflow_id,
    extract_merge_ref,
    sanitize_token,
)


def _resolve_workflow_id(
    request: PolicyRequest, invocation: GitInvocation, target_dir: str
) -> str:
    lease = request.context.lease
    if lease:
        wf = lease.get("workflow_id", "")
        if wf:
            return wf
    # Merge: try the merge ref
    if invocation.subcommand == "merge":
        merge_ref = extract_merge_ref(" ".join(invocation.argv))
        if merge_ref:
            return sanitize_token(merge_ref)
    return current_workflow_id(target_dir)


def _get_staged_files(target_dir: str) -> list[str]:
    """Return files in the staged index for the commit path.

    @decision DEC-PE-W3-010-STAGED-GATE-001
    Title: bash_workflow_scope inspects the staged index on the commit path
    Status: accepted
    Rationale: The prior implementation ran ``git diff --name-only
      base_branch...HEAD`` for both commit and merge, which validates
      branch-ahead history rather than the staged/indexed bundle about to
      be committed. That gap lets a first new staged file evade scope
      validation at PreToolUse commit time (it only shows up in the check
      after it has already been committed into branch-ahead history, by
      which point enforcement is too late for that specific commit).

      The commit path now inspects ``git diff --cached --name-only`` so the
      policy gates exactly the file set that is about to enter the commit.
      Branch-ahead history is not re-checked on commit — it was scope-
      checked at its own commit time. Tightening scope later does not
      retroactively block new commits just because prior commits existed
      under a looser scope; that was the anti-pattern the branch-history
      check induced during the WHO-remediation landing.

      Merge-path behaviour is preserved via :func:`_get_branch_ahead_files`
      and still uses ``base_branch...HEAD`` — merge semantics is about
      incorporating prior history, not about a staged index, so the
      existing discipline remains correct there.
    """
    try:
        r = subprocess.run(
            ["git", "-C", target_dir, "diff", "--cached", "--name-only"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if r.returncode == 0:
            return [f for f in r.stdout.strip().splitlines() if f]
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        pass
    return []


def _get_branch_ahead_files(target_dir: str, base_branch: str) -> list[str]:
    """Return files in branch-ahead commits (merge path).

    See :func:`_get_staged_files` for why the commit path no longer uses
    this function. Kept for the merge path, which inspects the commits
    that would be absorbed by the merge.
    """
    try:
        r = subprocess.run(
            ["git", "-C", target_dir, "diff", "--name-only", f"{base_branch}...HEAD"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if r.returncode == 0:
            return [f for f in r.stdout.strip().splitlines() if f]
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        pass
    return []


def _get_tracked_modifications(target_dir: str) -> list[str]:
    """Return tracked modified/deleted files that ``git commit -a/--all`` auto-stages.

    @decision DEC-PE-W3-010-STAGED-GATE-002
    Title: bash_workflow_scope covers commit -a / --all auto-stage semantics
    Status: accepted
    Rationale: The staged-index gate (DEC-PE-W3-010-STAGED-GATE-001) inspects
      ``git diff --cached --name-only`` — correct for plain ``git commit`` but
      incomplete for ``git commit -a`` / ``git commit --all``. Those
      invocations tell git to auto-stage every tracked file with uncommitted
      modifications or deletions before writing the commit. At PreToolUse time
      those files are not yet in the index, so the staged-index-only check
      would miss them and let a tracked out-of-scope edit slip past.

      This helper returns the tracked modified/deleted set (``git diff
      --name-only`` against the index, which by default excludes untracked
      files). The commit-path branch in :func:`check` unions it with the
      staged-index set when the invocation carries ``-a`` / ``--all`` / any
      short-flag bundle containing ``a``. Untracked files are NEVER pulled
      in — ``git commit -a`` itself does not stage untracked files, and the
      scope policy must not over-sweep beyond what git will actually commit.
    """
    try:
        r = subprocess.run(
            ["git", "-C", target_dir, "diff", "--name-only"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if r.returncode == 0:
            return [f for f in r.stdout.strip().splitlines() if f]
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        pass
    return []


_COMMIT_SHORT_VALUE_FLAGS = frozenset({"-m", "-F", "-c", "-C", "-t"})
"""Short flags that consume the next positional arg as their value.

Only includes flags that ALWAYS take a value. ``-u`` and ``-S`` take optional
values and when standalone do not consume the next arg — they are treated
as valueless here, which is conservative: at worst a pathspec following a
bare ``-u`` is swept into the check, which is already a safer direction
than leaving tracked out-of-scope files un-gated.
"""

_COMMIT_LONG_VALUE_FLAGS = frozenset({
    "--message", "--file", "--reuse-message", "--reedit-message",
    "--fixup", "--squash", "--author", "--date", "--cleanup",
    "--template", "--untracked-files", "--trailer",
    "--pathspec-from-file",
    # --gpg-sign takes an OPTIONAL arg; treated as valueless — see comment
    # above for the conservative rationale.
})
"""Long flags (without inline ``=``) that consume the next positional arg.

Includes ``--pathspec-from-file`` so the separated form
``git commit --pathspec-from-file paths.txt`` does NOT treat ``paths.txt``
as a literal pathspec entry. The filename is extracted separately by
:func:`_extract_pathspec_file_info`, and the file's contents are resolved
into pathspec entries by :func:`_read_pathspec_file`.
"""

_COMMIT_PATHSPEC_SEP = "--"
"""POSIX end-of-options sentinel. Everything after this is pathspec."""


def _parse_commit_pathspec(args: tuple[str, ...]) -> tuple[list[str], bool, bool]:
    """Parse ``git commit`` args into (pathspec, has_include, has_only).

    @decision DEC-PE-W3-010-STAGED-GATE-003
    Title: bash_workflow_scope models commit pathspec / --only / --include
    Status: accepted
    Rationale: ``git commit [<pathspec>...]`` implicitly enables ``--only``
      mode: git commits the contents of the pathspec-matched tracked files
      (both staged and unstaged changes to those files), NOT unrelated
      staged changes elsewhere. ``--include`` unions staged with the
      pathspec. Neither was modelled by the `-a/--all` handling in
      DEC-PE-W3-010-STAGED-GATE-002, so a tracked out-of-scope file could
      still slip past via ``git commit out-of-scope.py`` as long as it was
      not pre-staged. This parser lets :func:`check` route to the correct
      file set for each invocation flavour.

      Pathspec is every positional arg that is NOT a flag and NOT a flag's
      value. We detect value-taking flags by name (short and long
      variants); we honour the POSIX ``--`` end-of-options sentinel; we
      handle ``--flag=value`` inline form. Short-flag bundles whose last
      character is a value-taking flag (``-am "msg"`` where ``m`` takes
      ``"msg"``) are recognised so the bundle's value arg is not mistaken
      for pathspec. Unknown long options are assumed valueless (git will
      error on the real commit; our job is to classify, not emulate).

      Over-inclusion of pathspec is the safe direction: it can only cause
      the scope gate to check MORE files, never fewer. The no-oversweep
      invariant (untracked files excluded) is enforced separately by
      :func:`_get_pathspec_commit_files`, which intersects the parsed
      pathspec with real tracked modifications via ``git diff HEAD``.
    """
    pathspec: list[str] = []
    has_include = False
    has_only = False
    pathspec_mode = False  # True after we see ``--``
    skip_next = False

    for tok in args:
        if skip_next:
            skip_next = False
            continue
        if pathspec_mode:
            pathspec.append(tok)
            continue
        if tok == _COMMIT_PATHSPEC_SEP:
            pathspec_mode = True
            continue
        if tok in ("--include", "-i"):
            has_include = True
            continue
        if tok in ("--only", "-o"):
            has_only = True
            continue
        # Long option with inline ``=value`` form is self-contained.
        if tok.startswith("--") and "=" in tok:
            continue
        # Long option that consumes the next positional arg.
        if tok in _COMMIT_LONG_VALUE_FLAGS:
            skip_next = True
            continue
        # Any other long option: assume valueless.
        if tok.startswith("--"):
            continue
        # Short flag or short-flag bundle.
        if tok.startswith("-") and len(tok) > 1:
            # Standalone short flag that takes a value (``-m foo``).
            if tok in _COMMIT_SHORT_VALUE_FLAGS:
                skip_next = True
                continue
            # Short-flag bundle (``-am``, ``-avm``, ``-amF``). Git parses the
            # chars left-to-right; if any char is a value-taking flag, the
            # rest of the bundle is that flag's value (inline). In that
            # case no following positional arg is consumed. Only when the
            # LAST char is a value-taking flag and there's nothing after
            # it inline does the NEXT positional arg become the value.
            value_taking_chars = {f[1:] for f in _COMMIT_SHORT_VALUE_FLAGS}
            last_char = tok[-1]
            # Walk inner chars (except the last) — if any is value-taking,
            # everything after it is an inline value and we do NOT skip_next.
            consumed_inline = False
            for ch in tok[1:-1]:
                if ch in value_taking_chars:
                    consumed_inline = True
                    break
            if not consumed_inline and last_char in value_taking_chars:
                skip_next = True
            continue
        # Positional argument — pathspec.
        pathspec.append(tok)

    return pathspec, has_include, has_only


def _extract_pathspec_file_info(
    args: tuple[str, ...],
) -> tuple[Optional[str], bool]:
    """Extract (filename, nul_separator) from --pathspec-from-file / --pathspec-file-nul.

    @decision DEC-PE-W3-010-STAGED-GATE-004
    Title: bash_workflow_scope models --pathspec-from-file
    Status: accepted
    Rationale: ``git commit --pathspec-from-file=<file>`` reads pathspec
      entries from a file (one per line, or NUL-separated when combined
      with ``--pathspec-file-nul``). The previous parser skipped the
      filename as if the flag were valueless, and in the separated form
      ``--pathspec-from-file paths.txt`` treated ``paths.txt`` as a
      literal pathspec. Either way, a tracked out-of-scope file listed
      in the pathspec file could bypass the scope gate when nothing was
      staged.

      This helper scans ``invocation.args`` for both inline
      (``--pathspec-from-file=foo``) and separated
      (``--pathspec-from-file foo``) forms, and the paired boolean flag
      ``--pathspec-file-nul``. Returns ``(filename, nul_separator)``;
      ``filename`` is ``None`` when the flag is absent. The separated
      form's filename is captured correctly because the parser in
      :func:`_parse_commit_pathspec` has ``--pathspec-from-file`` in
      ``_COMMIT_LONG_VALUE_FLAGS``, so it is not misclassified as
      pathspec there either.

      ``--pathspec-file-nul`` takes no value and is a simple long flag.
      We do not emulate ``--pathspec-from-file=-`` (stdin) — the scope
      gate runs at PreToolUse and cannot read the future stdin of the
      git commit process. If the caller points at stdin, the helper
      returns an empty pathspec-entry list and the gate falls back to
      the other pathspec / staged / tracked signals.
    """
    filename: Optional[str] = None
    nul_separator = False
    skip_next = False
    for i, tok in enumerate(args):
        if skip_next:
            skip_next = False
            continue
        if tok == "--pathspec-file-nul":
            nul_separator = True
            continue
        if tok == "--pathspec-from-file":
            # Separated form: next arg is the filename.
            if i + 1 < len(args):
                filename = args[i + 1]
                skip_next = True
            continue
        if tok.startswith("--pathspec-from-file="):
            filename = tok.split("=", 1)[1]
            continue
    return filename, nul_separator


def _read_pathspec_file(
    target_dir: str, filename: str, nul_separator: bool
) -> list[str]:
    """Read pathspec entries from ``filename`` in the given target directory.

    Entries are split by NUL when ``nul_separator`` is True, else by
    newlines. Blank entries are filtered. Returns an empty list when the
    file does not exist, cannot be read, or refers to stdin (``-``) —
    the gate cannot observe future stdin at PreToolUse, so stdin-backed
    pathspec is treated as unknown and the policy falls through to the
    other signals (which are still conservative).

    Paths are intentionally NOT validated against the filesystem here —
    matching them against tracked files is left to
    :func:`_get_pathspec_commit_files` which uses ``git diff HEAD`` to
    resolve tracked-and-modified entries from the combined pathspec.
    """
    if not filename or filename == "-":
        return []
    # Resolve relative filename against target_dir; keep absolute paths as-is.
    import os
    if not os.path.isabs(filename):
        full = os.path.join(target_dir, filename)
    else:
        full = filename
    try:
        with open(full, "rb") as fh:
            raw = fh.read()
    except (OSError, FileNotFoundError):
        return []
    text = raw.decode("utf-8", errors="replace")
    sep = "\x00" if nul_separator else "\n"
    entries = [e.strip() for e in text.split(sep)]
    return [e for e in entries if e]


def _get_pathspec_commit_files(
    target_dir: str, pathspec: list[str]
) -> list[str]:
    """Return tracked files that would be included by a pathspec commit.

    Uses ``git diff HEAD --name-only -- <pathspec>`` to resolve which
    tracked files that differ from HEAD match the pathspec. This captures
    both staged and unstaged contents for pathspec-matched tracked files
    — exactly the set ``git commit <pathspec>`` / ``--only`` / ``--include``
    would commit for those paths.

    Never sweeps in untracked files: ``git diff HEAD`` is tracked-only by
    design. Directories and globs in pathspec are expanded by git itself.
    Empty pathspec returns an empty list.
    """
    if not pathspec:
        return []
    try:
        r = subprocess.run(
            ["git", "-C", target_dir, "diff", "HEAD", "--name-only", "--"]
            + list(pathspec),
            capture_output=True,
            text=True,
            timeout=10,
        )
        if r.returncode == 0:
            return [f for f in r.stdout.strip().splitlines() if f]
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        pass
    return []


def _commit_stages_all(args: tuple[str, ...]) -> bool:
    """Return True iff the commit invocation will auto-stage tracked changes.

    Detects ``--all`` (exact long flag) and any short-flag bundle containing
    ``a`` (``-a``, ``-am``, ``-av``, ``-avm``, …). Long options other than
    ``--all`` are skipped — notably ``--amend`` does NOT imply auto-staging,
    so it must not be matched here. Positional args are skipped.

    Kept as a separate pure helper so tests can pin the flag-detection
    surface without spinning up a real git repo.
    """
    for tok in args:
        if tok == "--all":
            return True
        if tok.startswith("--"):
            continue  # other long options do not auto-stage
        if not tok.startswith("-") or len(tok) < 2:
            continue  # positional args / bare "-"
        # Short-flag bundle: characters after the leading dash.
        if "a" in tok[1:]:
            return True
    return False


def _check_compliance(scope: dict, changed_files: list[str]) -> tuple[bool, list[str]]:
    """Replicate workflows.check_scope_compliance logic using pre-loaded scope dict.

    Returns (compliant, violations_list).
    forbidden_paths take strict precedence per DEC-WF-002.
    """
    import json

    def _parse_list(val) -> list[str]:
        if isinstance(val, list):
            return val
        if isinstance(val, str):
            try:
                parsed = json.loads(val)
                return parsed if isinstance(parsed, list) else []
            except (json.JSONDecodeError, TypeError):
                return []
        return []

    allowed = _parse_list(scope.get("allowed_paths", []))
    forbidden = _parse_list(scope.get("forbidden_paths", []))

    violations: list[str] = []
    for f in changed_files:
        if any(fnmatch.fnmatch(f, pat) for pat in forbidden):
            violations.append(f"FORBIDDEN: {f}")
            continue
        if allowed and not any(fnmatch.fnmatch(f, pat) for pat in allowed):
            violations.append(f"OUT_OF_SCOPE: {f}")

    return len(violations) == 0, violations


def check(request: PolicyRequest) -> Optional[PolicyDecision]:
    """Deny git commit/merge when workflow binding or scope is missing,
    or when changed files violate the scope manifest.

    Sub-checks:
      A. Binding must exist.
      B. Scope must exist.
      C. Changed files must comply with scope.

    Source: guard.sh lines 368-422 (Check 12).
    """
    intent = request.command_intent
    if intent is None:
        return None

    invocation = intent.git_invocation
    if invocation is None or invocation.subcommand not in ("commit", "merge"):
        return None

    # Meta-repo bypass.
    if request.context.is_meta_repo:
        return None

    target_dir = request.context.project_root or intent.target_cwd or request.cwd or ""
    workflow_id = _resolve_workflow_id(request, invocation, target_dir)

    # Sub-check A: binding must exist.
    if not request.context.binding:
        return PolicyDecision(
            action="deny",
            reason=(
                f"No workflow binding for '{workflow_id}'. "
                f"Bind workflow before committing: "
                f"cc-policy workflow bind {workflow_id} <worktree_path> <branch>"
            ),
            policy_name="bash_workflow_scope",
        )

    # Sub-check B: scope must exist.
    if not request.context.scope:
        return PolicyDecision(
            action="deny",
            reason=(
                f"No scope manifest for workflow '{workflow_id}'. "
                f"Set scope before committing: "
                f"cc-policy workflow scope-set {workflow_id} "
                f"--allowed '[...]' --forbidden '[...]'"
            ),
            policy_name="bash_workflow_scope",
        )

    # Sub-check C: changed files must comply with scope.
    # DEC-PE-W3-010-STAGED-GATE-001: commit gates on the staged index; merge
    # gates on branch-ahead history.
    # DEC-PE-W3-010-STAGED-GATE-002: ``-a`` / ``--all`` unions staged with
    # tracked-modifications (no untracked sweep).
    # DEC-PE-W3-010-STAGED-GATE-003: ``git commit <pathspec>`` (implicit
    # ``--only``) and ``--only <pathspec>`` commit only the pathspec files;
    # ``--include <pathspec>`` commits staged ∪ pathspec. See
    # :func:`_parse_commit_pathspec` for the rationale and parser contract.
    if invocation.subcommand == "commit":
        staged = set(_get_staged_files(target_dir))
        pathspec, has_include, has_only = _parse_commit_pathspec(invocation.args)
        # DEC-PE-W3-010-STAGED-GATE-004: merge pathspec from
        # --pathspec-from-file / --pathspec-file-nul into the pathspec
        # list before resolving the commit file set. The filename is NOT
        # treated as a pathspec entry itself (the parser recognises
        # --pathspec-from-file as a value-taking flag).
        #
        # DEC-PE-W3-010-STAGED-GATE-005: --pathspec-from-file=- reads
        # pathspec entries from the commit process's future stdin.
        # PreToolUse cannot inspect that stream, so the scope gate
        # cannot validate which files would actually be committed. Fail
        # closed explicitly rather than soft-pass — otherwise a caller
        # could feed out-of-scope tracked paths on stdin and bypass the
        # gate while inline/staged signals look clean.
        _ps_file, _ps_nul = _extract_pathspec_file_info(invocation.args)
        if _ps_file == "-":
            return PolicyDecision(
                action="deny",
                reason=(
                    f"Scope violation for workflow '{workflow_id}'. "
                    "git commit --pathspec-from-file=- reads pathspec "
                    "entries from stdin, which the PreToolUse scope gate "
                    "cannot inspect pre-execution. Write the pathspec "
                    "entries to a file (e.g. tmp/commit-paths.txt) and "
                    "use --pathspec-from-file=<path> so scope can be "
                    "validated before commit. See "
                    "DEC-PE-W3-010-STAGED-GATE-005."
                ),
                policy_name="bash_workflow_scope",
            )
        if _ps_file:
            pathspec = list(pathspec) + _read_pathspec_file(
                target_dir, _ps_file, _ps_nul
            )
        if _commit_stages_all(invocation.args):
            # -a / --all: staged ∪ all tracked modifications (no untracked).
            tracked = set(_get_tracked_modifications(target_dir))
            changed_set = staged | tracked
            # Pathspec alongside -a still only commits the pathspec files,
            # but gate conservatively on the union so no auto-staged
            # tracked file escapes scope.
            if pathspec:
                changed_set |= set(_get_pathspec_commit_files(target_dir, pathspec))
        elif pathspec:
            pathspec_files = set(_get_pathspec_commit_files(target_dir, pathspec))
            if has_include:
                # --include: staged ∪ pathspec.
                changed_set = staged | pathspec_files
            else:
                # --only (explicit or implicit): pathspec only. Unrelated
                # staged changes are NOT committed on this invocation and
                # must not factor into the scope gate.
                changed_set = pathspec_files
        else:
            # Plain commit — staged index only.
            changed_set = staged
        changed_files = sorted(changed_set)
    else:  # merge
        base_branch = request.context.binding.get("base_branch", "main") or "main"
        changed_files = _get_branch_ahead_files(target_dir, base_branch)

    if changed_files:
        compliant, violations = _check_compliance(request.context.scope, changed_files)
        if not compliant:
            viols_str = ", ".join(violations)
            return PolicyDecision(
                action="deny",
                reason=(
                    f"Scope violation for workflow '{workflow_id}'. "
                    f"Unauthorized files changed: {viols_str}"
                ),
                policy_name="bash_workflow_scope",
            )

    return None


def register(registry) -> None:
    """Register bash_workflow_scope into the given PolicyRegistry."""
    registry.register(
        "bash_workflow_scope",
        check,
        event_types=["Bash", "PreToolUse"],
        priority=1000,
    )
