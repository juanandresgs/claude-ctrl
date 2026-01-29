---
name: compact
description: Generate context preservation summary for compaction
---

# /compact - Context Preservation

Generate a structured context summary before compaction, preventing amnesia by capturing session state.

## What It Does

1. Scans the conversation for objectives, decisions, and state
2. Extracts active context from file operations and recent changes
3. Identifies constraints from user preferences and discarded approaches
4. Generates a structured 4-section summary for review before compaction

## Output Format

The command produces the exact 4-section format defined in `~/.claude/skills/context-preservation/SKILL.md`:

1. **Current Objective & Status** — Goal, status, immediate next step
2. **Active Context** — Absolute file paths, recent changes, key variables
3. **Constraints & Decisions** — Preferences, discarded approaches, architectural rules
4. **Continuity Handoff** — First actionable step for resumption

## When to Use

- Context window feels full
- Before switching tasks
- Manual checkpoint for long-running work
- Complex continuation across sessions
