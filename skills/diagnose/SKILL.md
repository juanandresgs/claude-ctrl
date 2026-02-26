---
name: diagnose
description: Validate hook integrity, state file consistency, and system health for the ~/.claude configuration.
visibility: public
context: fork
agent: general-purpose
allowed-tools:
  - Bash
  - Read
  - Glob
  - Grep
---

# /diagnose — Hook & State Health Check

Validates the entire hook/state system is healthy. Run this when hooks behave unexpectedly, after configuration changes, or as a periodic sanity check.

## Process

### Step 1: Run the diagnostic script

```bash
bash ~/.claude/skills/diagnose/scripts/diagnose.sh
```

The script checks:
1. **Hook file integrity** — all scripts referenced in settings.json exist and are executable
2. **Shared library health** — log.sh and context-lib.sh source without errors
3. **State file validation** — .plan-drift, .proof-status, .test-status formats
4. **Settings consistency** — valid JSON, no duplicate hook registrations
5. **MASTER_PLAN.md status** — phase statuses, DEC-ID format, REQ-ID format
6. **Git health** — orphaned worktrees, uncommitted changes

### Step 2: Interpret results

- **PASS** — check passed, no action needed
- **WARN** — non-critical issue; explain the risk to the user
- **FAIL** — critical issue; suggest specific remediation steps

### Step 3: Remediation

For any FAILs, provide the user with:
- What is broken and why it matters
- The exact command or edit to fix it
- Whether the fix requires a worktree (Sacred Practice #2)

For WARNs, explain:
- What the risk is if left unaddressed
- Whether it is safe to ignore for now
