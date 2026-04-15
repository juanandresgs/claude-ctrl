# Runtime Payload Capture

This directory contains tooling for capturing the raw JSON payloads that the
Claude runtime delivers to hooks. The purpose is to validate the actual
contract between the installed Claude version and the hook scripts — not rely
on assumptions.

## Why This Exists

The hooks parse specific JSON fields (`.agent_type`, `.tool_input.command`,
`.tool_input.file_path`, etc.). If the runtime changes those field names or
structures, hooks silently break. TKT-001 establishes a capture mechanism so
the real payloads can be observed, documented, and used as the basis for
synthetic test payloads in TKT-002.

DEC-FORK-006: The current Claude runtime contract is treated as a
compatibility surface that must be revalidated now.

## Files

| File | Purpose |
|------|---------|
| `capture-wrapper.sh` | Passthrough hook that logs raw stdin JSON to `payloads/` |
| `install-capture.sh` | Generates `settings.capture.json` with the wrapper prepended to every hook chain |
| `payloads/` | Where captured JSON files land (gitignored by default) |
| `PAYLOAD_CONTRACT.md` | Documented field schema derived from captures and hook source |

## Running a Capture Session

### Step 1: Generate the capture settings

```bash
cd tests/scenarios/capture
./install-capture.sh
# Writes: $REPO_ROOT/settings.capture.json
```

You can also specify paths explicitly:

```bash
./install-capture.sh /path/to/settings.json /path/to/output.json
```

### Step 2: Activate the capture settings

```bash
# Back up your live settings first
cp ~/.claude/settings.json ~/.claude/settings.json.bak

# Activate capture
cp $REPO_ROOT/settings.capture.json ~/.claude/settings.json
```

### Step 3: Run a Claude session

Start a Claude session and exercise these actions to capture each event type:

| Action | Event captured |
|--------|---------------|
| Start Claude / `/clear` | `SessionStart` |
| Type any prompt | `UserPromptSubmit` |
| Spawn a subagent (Task tool) | `SubagentStart` |
| Subagent completes | `SubagentStop` |
| Write a file | `PreToolUse` (Write) |
| Edit a file | `PreToolUse` (Edit) |
| Run a bash command | `PreToolUse` (Bash) |
| After a file write | `PostToolUse` (Write) |
| Claude stops responding | `Stop` |

### Step 4: Inspect captures

```bash
ls tests/scenarios/capture/payloads/
# e.g.: SessionStart_20260323T120000Z.json
#       PreToolUse_20260323T120001Z.json

cat tests/scenarios/capture/payloads/SubagentStart_*.json
```

### Step 5: Restore live settings

```bash
cp ~/.claude/settings.json.bak ~/.claude/settings.json
```

## Fields to Look For

When reviewing captured payloads, check these fields against what the hooks
parse:

**SubagentStart** — hooks/subagent-start.sh reads:
- `.agent_type` — string: `planner`, `Plan`, `implementer`, `reviewer`,
  `guardian`, `Bash`, `Explore`, or other. Phase 8 Slice 11 retired the legacy
  `tester` value; it must not appear in new captures (DEC-PHASE8-SLICE11-001).

**SubagentStop** — hooks/check-*.sh reads:
- `.agent_type` — same values as SubagentStart
- `.response` — may or may not be present; needs verification

**PreToolUse (Write)** — hooks/pre-write.sh → cc-policy evaluate reads:
- `.tool_name` — string: `"Write"`
- `.tool_input.file_path` — absolute path string
- `.tool_input.content` — full file content string

**PreToolUse (Edit)** — hooks/pre-write.sh → cc-policy evaluate reads:
- `.tool_name` — string: `"Edit"`
- `.tool_input.file_path` — absolute path string
- `.tool_input.old_string` — the text being replaced
- `.tool_input.new_string` — the replacement text

**PreToolUse (Bash)** — hooks/pre-bash.sh reads:
- `.tool_name` — string: `"Bash"`
- `.tool_input.command` — the full shell command string
- `.cwd` — current working directory (used for git target detection)

**SessionStart** — hooks/session-init.sh reads:
- No specific fields required; the hook derives context from the filesystem

**UserPromptSubmit** — hooks/prompt-submit.sh reads:
- `.prompt` — the user's prompt text string

**Stop** — hooks/surface.sh, session-summary.sh, forward-motion.sh read:
- No specific fields required from the payload

## Captured Payload Storage

Payloads are written to `payloads/<event_type>_<timestamp>.json`. The
`payloads/` directory should be added to `.gitignore` if it isn't already,
since captures may contain sensitive project content.
