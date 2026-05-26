# v6 Release Readiness Record

Status: static/runtime gate passed; public push held pending live Claude Code dogfood
Date: 2026-05-24

## Findings from deploy review

1. **Hidden Stop gate conflict.** `settings.json` no longer wired the Codex stop-review hook, but the bundled Codex plugin manifest still auto-wired a `Stop` hook. This contradicted the v6 promise that critic/reviewer are first-order stages, not hidden regular Stop gates.
2. **Local artifacts were visible to git.** `.claude.json`, `.last-cleanup`, `mcp-needs-auth-cache.json`, `policy-limits.json`, and `runtime/dispatch-debug.jsonl` were untracked local/runtime artifacts and not release material.
3. **Critic path still had a manual seam.** Implementer completion produced a `critic` stage with `worker_pending`; docs told operators to keep `cc-policy stage critic-worker` running. That violated the “no manual workflow steps” goal.
4. **No public-safe cutover path.** The repo had an isolated launcher, but no backup/restore workflow for an existing `~/.claude` with conversation histories, sessions, project history, plugin state, and `~/.claude.json`.
5. **Defaults needed proof.** Broad Claude permissions are intentional only if deterministic hooks/policy own enforcement. The release needed tests proving that bypass-style Claude settings are backstopped by `pre-write`, `pre-bash`, `pre-agent`, ticket seating, v6 result submission, and runtime defaults.

## Fixes applied

- Removed plugin-level hidden regular `Stop` hook wiring from `plugins/marketplaces/openai-codex/plugins/codex/hooks/hooks.json`.
- Changed seeded enforcement defaults:
  - `review_gate_regular_stop=false` — hidden regular Stop review is explicit opt-in.
  - `review_gate_subagent_stop=true` — dispatch-stage review remains enabled.
  - `review_gate_provider=codex`.
- Made `hooks/v6-result-submit.sh` automatically invoke the v6 critic worker for the newly-created critic stage with a bounded timeout (`CLAUDE_CTRL_CRITIC_TIMEOUT`, default `60`).
- Made `worker_pending` critic actions non-ticketable until the worker either submits a valid external critic result or publishes an explicit adversarial critic fallback ticket.
- Added `scripts/claude-v6-migrate.sh` with safe `backup`, `verify-backup`, `install`, `restore`, and isolated `test` commands.
- Hardened isolated verification so `scripts/claude-v6.sh --verify-config` uses only flag settings (`--setting-sources ""`), disables persistence/tools, and creates a fresh per-run state DB. Repeated verify runs and `claude-v6-migrate.sh test` now prove bootstrap without leaking live stage state.
- Added `cc-policy schema exercise-upgrade` and `cc-policy doctor --exercise-schema-upgrade` so stale project DB recovery is validated by copying a stale DB, requiring archive/reset metadata, and leaving the live DB untouched. Manual deletion of `.claude/state.db` is not a valid upgrade test.
- Fixed `session-init.sh`/runtime bridge cleanup calls so SessionStart emits exactly one JSON object; Claude no longer logs hook JSON parse failures from multiple top-level JSON documents.
- Added release/default and backup/critic scenarios:
  - `tests/runtime/test_v6_release_defaults.py`
  - `tests/scenarios/test-v6-critic-auto.sh`
  - `tests/scenarios/test-v6-backup-restore.sh`
  - `tests/scenarios/test-schema-upgrade-exercise.sh`

## Backup / restore contract

Before cutover, run:

```bash
scripts/claude-v6-migrate.sh backup
```

The backup captures:

- existing `~/.claude` directory or symlink target;
- state-bearing history paths such as `projects/`, `sessions/`, `history.jsonl`, `shell-snapshots/`, `session-env/`, `state.db*`, and plugin state/cache;
- `~/.claude.json` when present;
- `manifest.json` describing source kind and restore metadata.

Dry-run install preparation:

```bash
scripts/claude-v6-migrate.sh install --backup-dir <backup-dir>
```

Actual cutover:

```bash
scripts/claude-v6-migrate.sh install --backup-dir <backup-dir> --yes
```

Restore:

```bash
scripts/claude-v6-migrate.sh restore <backup-dir> --yes
```

Restore backs up the current v6 state first under `~/.claude-ctrl-backups/restore-current-*`, then restores the selected backup and `~/.claude.json`.

## Current validation evidence

Static/runtime release gate passed on 2026-05-24. This is necessary but not sufficient for public push; live Claude Code dogfood in `docs/V6_LIVE_TESTING.md` is now the final gate.

```text
python3 -m py_compile runtime/cli.py runtime/core/*.py runtime/core/policies/*.py
bash -n hooks/*.sh scripts/*.sh tests/scenarios/*.sh
python3 -m pytest -q tests/runtime tests/scenarios
# 1514 passed, 1 xpassed

bash tests/scenarios/test-runner.sh
# 93 passed, 0 failed

cd plugins/marketplaces/openai-codex && npm test
# 86 passed

python3 runtime/cli.py doctor
# ok=true

TMP_VERIFY=$(mktemp -d /tmp/claude-v6-verify.XXXXXX)
git -C "$TMP_VERIFY" init -q
scripts/claude-v6.sh --verify-config "$TMP_VERIFY"
scripts/claude-v6.sh --verify-config "$TMP_VERIFY"
scripts/claude-v6-migrate.sh test "$TMP_VERIFY"
rm -rf "$TMP_VERIFY"
# PASS hook-output: V6_DISPATCH_READY observed on all 3 runs
# PASS hook-path: repo prompt-submit.sh observed on all 3 runs
```

## Live Claude Code gate

Prepared harness:

```bash
scripts/claude-v6-live-test.sh prepare
scripts/claude-v6-live-test.sh open
scripts/claude-v6-live-test.sh start
scripts/claude-v6-live-test.sh restore
```

Public push remains blocked until installed live dogfood passes and the latest run assesses clean.

Additional hygiene gate:

```text
git diff --check
# clean after whitespace cleanup
```
