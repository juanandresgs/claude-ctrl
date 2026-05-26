#!/usr/bin/env bash
set -euo pipefail

CONFIG_ROOT="${CLAUDE_CTRL_CONFIG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}"
LIVE_ROOT="${CLAUDE_CTRL_LIVE_TEST_ROOT:-$CONFIG_ROOT/tmp/live-claude-v6}"
LATEST_LINK="$LIVE_ROOT/latest"
MIGRATE="$CONFIG_ROOT/scripts/claude-v6-migrate.sh"
LAUNCHER="$CONFIG_ROOT/scripts/claude-v6.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") <command>

Commands:
  prepare        Create a disposable live-test repo and prompt. No ~/.claude changes.
  open           Open live Claude Code with isolated v6 settings against latest test repo.
  start          Backup/install v6 as ~/.claude, then open normal live Claude Code.
  assess         Assess latest live-test workspace/debug log after Claude exits.
  restore        Restore the backup created by start.
  status         Print latest test workspace, prompt, backup, and restore command.

Recommended local dogfood path:
  $(basename "$0") prepare
  $(basename "$0") open      # isolated live Claude Code
  $(basename "$0") start     # full installed ~/.claude cutover test
  $(basename "$0") restore   # rollback when done
EOF
}

say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

require_claude_flags() {
  local help
  help="$(claude --help 2>&1 || true)"
  for flag in --settings --setting-sources --debug-file; do
    grep -q -- "$flag" <<<"$help" || die "installed claude does not support $flag"
  done
}

json_get() {
  local key="$1" file="$2"
  python3 - "$key" "$file" <<'PY'
import json, sys
key, path = sys.argv[1:]
try:
    data = json.load(open(path, encoding="utf-8"))
except FileNotFoundError:
    print("")
    raise SystemExit(0)
value = data
for part in key.split('.'):
    if isinstance(value, dict):
        value = value.get(part, "")
    else:
        value = ""
print(value if value is not None else "")
PY
}

write_manifest() {
  local run_dir="$1" workspace="$2" prompt_file="$3" debug_file="$4" mode="${5:-prepared}" backup="${6:-}"
  python3 - "$run_dir" "$workspace" "$prompt_file" "$debug_file" "$mode" "$backup" "$CONFIG_ROOT" <<'PY'
import json, os, sys, time
run_dir, workspace, prompt_file, debug_file, mode, backup, config_root = sys.argv[1:]
manifest = {
    "schema": "claude-ctrl-v6-live-test/v1",
    "created_at": int(time.time()),
    "mode": mode,
    "run_dir": run_dir,
    "workspace": workspace,
    "prompt_file": prompt_file,
    "debug_file": debug_file,
    "backup_dir": backup,
    "config_root": config_root,
    "restore_command": f"{config_root}/scripts/claude-v6-live-test.sh restore" if backup else "",
}
with open(os.path.join(run_dir, "manifest.json"), "w", encoding="utf-8") as f:
    json.dump(manifest, f, indent=2, sort_keys=True)
    f.write("\n")
PY
  ln -sfn "$run_dir" "$LATEST_LINK"
}

latest_manifest() {
  [[ -L "$LATEST_LINK" || -d "$LATEST_LINK" ]] || die "no live-test run yet; run: $(basename "$0") prepare"
  local manifest="$LATEST_LINK/manifest.json"
  [[ -f "$manifest" ]] || die "missing manifest: $manifest"
  printf '%s\n' "$manifest"
}

prepare_cmd() {
  require_cmd git
  require_cmd python3
  require_cmd jq
  require_cmd claude
  require_claude_flags
  [[ -x "$LAUNCHER" ]] || die "missing launcher: $LAUNCHER"
  mkdir -p "$LIVE_ROOT"

  local ts run_dir workspace prompt_file debug_file
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  run_dir="$LIVE_ROOT/$ts"
  workspace="$run_dir/workspace"
  prompt_file="$run_dir/live-prompt.md"
  debug_file="$run_dir/claude-debug.log"
  mkdir -p "$workspace/tests" "$workspace/.claude"

  git -C "$workspace" init -q
  git -C "$workspace" config user.name "claude-ctrl live test"
  git -C "$workspace" config user.email "live-test@example.invalid"

  cat > "$workspace/mathbox.py" <<'PY'
"""Tiny module for claude-ctrl v6 live dogfood."""


def add(a: int, b: int) -> int:
    return a + b


def subtract(a: int, b: int) -> int:
    return a - b
PY

  cat > "$workspace/tests/test_mathbox.py" <<'PY'
import unittest

from mathbox import add, subtract


class MathboxTests(unittest.TestCase):
    def test_add(self):
        self.assertEqual(add(2, 3), 5)

    def test_subtract(self):
        self.assertEqual(subtract(7, 4), 3)


if __name__ == "__main__":
    unittest.main()
PY

  cat > "$workspace/README.md" <<'MD'
# claude-ctrl v6 live test fixture

This disposable repo is intentionally tiny. The live Claude Code task is to add
`multiply(a, b)` to `mathbox.py`, add unittest coverage, run tests, and complete
through the v6 planner → guardian → implementer → critic → reviewer path.
MD

  cat > "$workspace/MASTER_PLAN.md" <<'MD'
# Live Test Fixture Plan

Status: live dogfood fixture

## Acceptance

- Add `multiply(a, b)` in `mathbox.py`.
- Add `unittest` coverage in `tests/test_mathbox.py`.
- `python3 -m unittest discover -s tests -q` passes.
- The root Claude session must use v6 runtime dispatch; it must not implement as root.
MD

  cat > "$prompt_file" <<'PROMPT'
Live-test claude-ctrl v6 on this disposable fixture.

Goal: add `multiply(a, b)` to `mathbox.py`, add unittest coverage in `tests/test_mathbox.py`, run `python3 -m unittest discover -s tests -q`, and finish through the v6 dispatch pipeline.

Important live-test requirements:
- Do not implement directly as the root/orchestrator.
- Use the `V6_DISPATCH_READY` ticket emitted by the prompt hook to launch the canonical planner.
- Continue the canonical path planner → guardian:provision → implementer → critic → reviewer → guardian:land as far as the runtime directs.
- Do not ask me to manually create tickets or run long commands.
- If the path stalls, explain the exact hook/runtime reason visible in context.
PROMPT

  git -C "$workspace" add .
  git -C "$workspace" commit -m "seed live v6 fixture" -q
  (cd "$workspace" && python3 -m unittest discover -s tests -q) >/dev/null
  "$LAUNCHER" --show-config "$workspace" >/dev/null

  write_manifest "$run_dir" "$workspace" "$prompt_file" "$debug_file" "prepared" ""
  say "LIVE_TEST_READY=$run_dir"
  say "WORKSPACE=$workspace"
  say "PROMPT=$prompt_file"
  say "OPEN=$CONFIG_ROOT/scripts/claude-v6-live-test.sh open"
  say "START_INSTALLED=$CONFIG_ROOT/scripts/claude-v6-live-test.sh start"
}

update_manifest_mode() {
  local manifest="$1" mode="$2" backup="${3:-}"
  python3 - "$manifest" "$mode" "$backup" <<'PY'
import json, sys
path, mode, backup = sys.argv[1:]
data = json.load(open(path, encoding="utf-8"))
data["mode"] = mode
if backup:
    data["backup_dir"] = backup
    data["restore_command"] = f'{data["config_root"]}/scripts/claude-v6-live-test.sh restore'
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, sort_keys=True)
    f.write("\n")
PY
}

run_live_claude() {
  local mode="$1" manifest workspace prompt_file debug_file prompt rc
  manifest="$(latest_manifest)"
  workspace="$(json_get workspace "$manifest")"
  prompt_file="$(json_get prompt_file "$manifest")"
  debug_file="$(json_get debug_file "$manifest")"
  [[ -d "$workspace" ]] || die "workspace missing: $workspace"
  [[ -f "$prompt_file" ]] || die "prompt missing: $prompt_file"
  prompt="$(cat "$prompt_file")"
  rm -f "$debug_file"

  say "LIVE_TEST_MODE=$mode"
  say "WORKSPACE=$workspace"
  say "DEBUG_FILE=$debug_file"
  say "If Claude shows a workspace setup/trust screen, choose the option to trust this disposable workspace. Do not reconfigure Claude Code."
  say "When Claude opens, let the initial prompt run. Exit Claude when the live path is done; this script will assess the run."

  set +e
  if [[ "$mode" == "isolated" ]]; then
    "$LAUNCHER" "$workspace" --debug --debug-file "$debug_file" "$prompt"
    rc=$?
  else
    (cd "$workspace" && CLAUDE_PROJECT_DIR="$workspace" claude --debug --debug-file "$debug_file" "$prompt")
    rc=$?
  fi
  set -e
  assess_cmd || true
  return "$rc"
}

open_cmd() {
  if [[ ! -e "$LATEST_LINK" ]]; then
    prepare_cmd
  fi
  update_manifest_mode "$(latest_manifest)" "isolated-open" ""
  run_live_claude isolated
}

start_cmd() {
  if [[ ! -e "$LATEST_LINK" ]]; then
    prepare_cmd
  fi
  [[ -x "$MIGRATE" ]] || die "missing migrate script: $MIGRATE"
  local manifest backup
  manifest="$(latest_manifest)"
  backup="$(json_get backup_dir "$manifest")"
  if [[ -z "$backup" ]]; then
    backup="$($MIGRATE backup)"
    "$MIGRATE" install --backup-dir "$backup" --yes >/dev/null
    update_manifest_mode "$manifest" "installed-open" "$backup"
  fi
  say "INSTALLED_BACKUP=$backup"
  say "RESTORE=$CONFIG_ROOT/scripts/claude-v6-live-test.sh restore"
  run_live_claude installed
}

assess_cmd() {
  local manifest workspace debug_file failures=0
  manifest="$(latest_manifest)"
  workspace="$(json_get workspace "$manifest")"
  debug_file="$(json_get debug_file "$manifest")"
  say "== live-test assessment =="
  say "WORKSPACE=$workspace"
  say "DEBUG_FILE=$debug_file"

  if [[ -f "$debug_file" ]]; then
    if grep -q "V6_DISPATCH_READY" "$debug_file"; then
      say "PASS hook-output: V6_DISPATCH_READY observed"
    else
      say "PENDING hook-output: V6_DISPATCH_READY not observed in debug log"
      failures=$((failures + 1))
    fi
    if grep -q "$CONFIG_ROOT/hooks/prompt-submit.sh" "$debug_file"; then
      say "PASS hook-path: repo prompt-submit.sh observed"
    else
      say "PENDING hook-path: repo prompt-submit.sh not observed"
      failures=$((failures + 1))
    fi
    cancel_count=$(python3 - "$debug_file" <<'PY'
import json
import sys

count = 0
with open(sys.argv[1], encoding="utf-8", errors="replace") as handle:
    for line in handle:
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        attachment = event.get("attachment") or {}
        if attachment.get("type") == "hook_cancelled" and (
            attachment.get("hookName") == "UserPromptSubmit"
            or attachment.get("hookEvent") == "UserPromptSubmit"
        ):
            count += 1
print(count)
PY
)
    if [[ "${cancel_count:-0}" == "0" ]]; then
      say "PASS hook-cancelled: no UserPromptSubmit cancellations observed"
    else
      say "FAIL hook-cancelled: UserPromptSubmit cancelled ${cancel_count} time(s); v6 dispatch was disabled"
      failures=$((failures + 1))
    fi
    if grep -q "Failed to parse hook output as JSON" "$debug_file"; then
      say "FAIL hook-json: Claude logged hook JSON parse failures"
      failures=$((failures + 1))
    else
      say "PASS hook-json: no hook JSON parse failures observed"
    fi
  else
    say "PENDING debug log missing"
    failures=$((failures + 1))
  fi

  if [[ -d "$workspace" ]]; then
    if (cd "$workspace" && python3 -m unittest discover -s tests -q >/tmp/claude-v6-live-unittest.$$ 2>&1); then
      say "PASS fixture-tests: python3 -m unittest discover -s tests -q"
    else
      say "PENDING fixture-tests: python3 -m unittest discover -s tests -q failed"
      sed 's/^/  /' "/tmp/claude-v6-live-unittest.$$" || true
      failures=$((failures + 1))
    fi
    rm -f "/tmp/claude-v6-live-unittest.$$"
    say "GIT_STATUS:"
    (cd "$workspace" && git status --short) | sed 's/^/  /'
  fi

  if [[ "$failures" -eq 0 ]]; then
    say "LIVE_TEST_ASSESSMENT=pass"
  else
    say "LIVE_TEST_ASSESSMENT=pending_or_fail($failures)"
  fi
}

restore_cmd() {
  local manifest backup
  manifest="$(latest_manifest)"
  backup="$(json_get backup_dir "$manifest")"
  [[ -n "$backup" ]] || die "latest run has no backup_dir; nothing to restore"
  "$MIGRATE" restore "$backup" --yes
  update_manifest_mode "$manifest" "restored" "$backup"
}

status_cmd() {
  local manifest
  manifest="$(latest_manifest)"
  say "MANIFEST=$manifest"
  python3 - "$manifest" <<'PY'
import json, sys
data=json.load(open(sys.argv[1], encoding="utf-8"))
for key in ["mode","run_dir","workspace","prompt_file","debug_file","backup_dir","restore_command"]:
    print(f"{key.upper()}={data.get(key,'')}")
PY
}

cmd="${1:-}"; shift || true
case "$cmd" in
  prepare) prepare_cmd "$@" ;;
  open) open_cmd "$@" ;;
  start) start_cmd "$@" ;;
  assess) assess_cmd "$@" ;;
  restore) restore_cmd "$@" ;;
  status) status_cmd "$@" ;;
  -h|--help|help|"") usage ;;
  *) die "unknown command: $cmd" ;;
esac
