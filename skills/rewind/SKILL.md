---
name: rewind
description: List and restore to a named checkpoint from the current session. Use when the agent has gone off track and you need to recover to a previous good state.
---

# /rewind — Session Checkpoint Recovery

You help the user recover to a previous checkpoint in the current session.

Checkpoints are created automatically by `hooks/checkpoint.sh` during implementer sessions:
- Every 5 file writes (threshold-based)
- On the first modification of any new file in the session

Each checkpoint is a git ref at `refs/checkpoints/<branch>/<N>` pointing to a commit object that snapshots the working directory state at that moment, without affecting HEAD or the branch pointer.

## Protocol

### Step 1 — List checkpoints for the current branch

```bash
BRANCH=$(git branch --show-current)
git for-each-ref "refs/checkpoints/${BRANCH}/" \
  --format='%(refname:short) %(subject)' \
  --sort=version:refname
```

### Step 2 — Present checkpoints to the user

Format each checkpoint as:
```
[N] <timestamp> — before modifying <filename>
    ref: checkpoints/<branch>/<N>
    SHA: <sha>
```

Extract from the subject line `checkpoint:EPOCH:before:FILENAME`:
- `EPOCH` → convert to human-readable time (`date -r EPOCH` or `date -d @EPOCH`)
- `FILENAME` → the file that was about to be modified

If no checkpoints exist, inform the user:
> No checkpoints found for branch `<branch>`. Checkpoints are created automatically during implementer sessions — every 5 writes or on the first modification of a new file.

### Step 3 — On user selection, restore the checkpoint

```bash
# Get the checkpoint SHA
SHA=$(git rev-parse "refs/checkpoints/${BRANCH}/<N>")

# Show what will change before restoring
git diff HEAD "$SHA" --stat

# Restore working tree to checkpoint state (does NOT move HEAD)
git checkout "$SHA" -- .
```

Show the diff stat to the user before restoring, and ask for confirmation:
> This will restore N files to checkpoint state. HEAD stays at its current commit. Proceed?

### Step 4 — Log the rewind event

```bash
source ~/.claude/hooks/context-lib.sh
PROJECT_ROOT=$(detect_project_root)
append_session_event "rewind" \
  "{\"ref\":\"refs/checkpoints/${BRANCH}/<N>\",\"target\":\"${SHA}\"}" \
  "$PROJECT_ROOT"
```

### Step 5 — Report what changed

```bash
git diff --stat HEAD
```

Show the user:
- Which files were restored
- What the diff looks like (`git diff HEAD` for key files)
- Next steps: "You're now at checkpoint N. The agent's recent changes have been reverted. You can continue from this state."

## Important Notes

- **Checkpoints are READ-ONLY snapshots.** Restoring does NOT change HEAD or the branch pointer. Only working-tree files are affected via `git checkout SHA -- .`
- **Only checkpoints for the CURRENT branch are shown.** Refs are scoped to `refs/checkpoints/<branch>/`.
- **Checkpoint refs survive garbage collection** because they are named refs (not loose objects).
- **After merge**, checkpoint refs for the merged branch are cleaned up by Guardian as part of the merge process.
- **Counter state**: The checkpoint counter is stored in `.claude/.checkpoint-counter` and is reset when a new implementer session starts.
