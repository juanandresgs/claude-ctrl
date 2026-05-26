# v6 Live Claude Code Testing

Status: required before public push
Date: 2026-05-24

Static/runtime tests are not the release gate. Public push requires live Claude Code dogfood through the installed hook/runtime path.

## One-command fixture setup

```bash
scripts/claude-v6-live-test.sh prepare
```

This creates a disposable git repo under `tmp/live-claude-v6/latest/workspace` with a tiny Python fixture and a live prompt.

## Live passes

### 1. Isolated live Claude Code

```bash
scripts/claude-v6-live-test.sh open
```

Uses `scripts/claude-v6.sh` with rendered repo settings and a fresh fixture. No `~/.claude` cutover.

### 2. Installed live Claude Code

```bash
scripts/claude-v6-live-test.sh start
```

Backs up current `~/.claude` + `~/.claude.json`, installs this repo as `~/.claude`, then opens normal `claude` in the fixture. This is the real local cutover dogfood.

Rollback:

```bash
scripts/claude-v6-live-test.sh restore
```

## Acceptance

The live session must prove:

- prompt hook emits `V6_DISPATCH_READY`;
- Claude loaded this repo's `hooks/prompt-submit.sh`;
- no hook JSON parse failures appear in Claude debug logs;
- root/orchestrator does not implement directly;
- no manual ticket creation is needed;
- planner → guardian/provision → implementer → critic → reviewer path progresses as runtime directs;
- critic path is automatic or fails into an explicit v6 critic fallback ticket;
- fixture tests pass with `python3 -m unittest discover -s tests -q`;
- installed mode can be restored from backup without losing prior Claude state.

After Claude exits, the harness runs:

```bash
scripts/claude-v6-live-test.sh assess
```

The latest run state is available with:

```bash
scripts/claude-v6-live-test.sh status
```
