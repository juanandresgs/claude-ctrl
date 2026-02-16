---
name: uplevel
description: Comprehensive repository health audit — security, docs, code quality, staleness, testing, standards. Produces scored report and GitHub Issues.
argument-hint: "[--quick] [--area security,docs,quality,staleness,testing,standards] [--fix] [--project /path]"
context: fork
agent: general-purpose
allowed-tools: Bash, Read, Write, Glob, Grep, WebSearch, Task, AskUserQuestion
---

# /uplevel — Repository Health Audit

Comprehensive, multi-area audit that scores repository health across 6 dimensions, produces a unified report, and creates GitHub Issues for actionable findings.

## Argument Parsing

Parse `$ARGUMENTS` for these flags:

| Flag | Effect | Default |
|------|--------|---------|
| `--quick` | Read-only mode: skip test execution, tool installation, double-runs | Off (aggressive) |
| `--area <list>` | Comma-separated areas to audit | All 6 areas |
| `--fix` | Attempt auto-fixes where safe (lockfile regen, .gitignore additions) | Off |
| `--project <path>` | Target a different repository path | Current working directory |

**Example invocations:**
- `/uplevel` — full audit of current repo
- `/uplevel --quick` — read-only scan, no test execution
- `/uplevel --area security,testing` — audit only security and testing
- `/uplevel --project /path/to/other/repo` — audit a different repo

## Execution Steps

### Step 1: Project Detection

Run the detection script to understand the target repository:

```bash
bash ~/.claude/skills/uplevel/scripts/detect_project.sh <repo_root>
```

This outputs JSON with: languages, frameworks, package managers, CI provider, test frameworks, file counts, git remote. Save this as `project_info` — every area agent needs it.

### Step 2: Prepare Report Directory

```bash
REPORT_DIR="<repo_root>/.claude/uplevel"
mkdir -p "$REPORT_DIR/history" "$REPORT_DIR/areas"
```

### Step 3: Launch Area Audits in Parallel

Launch up to 6 `Task` subagents simultaneously, one per area. Each agent receives:
1. The project detection JSON
2. The area-specific prompt from `~/.claude/skills/uplevel/prompts/{area}.md`
3. Whether `--quick` mode is enabled
4. The repo root path

**CRITICAL: Use `run_in_background: true` for all 6 agents to run them in parallel.**

For each enabled area, read the prompt file and launch:

```
Task(
  subagent_type="general-purpose",
  description="{area} audit",
  prompt=<contents of prompts/{area}.md> + project_info JSON + flags,
  run_in_background=true
)
```

The 6 areas and their prompt files:

| Area | Prompt File | Weight |
|------|-------------|--------|
| security | `prompts/security.md` | 25% |
| testing | `prompts/testing.md` | 20% |
| quality | `prompts/quality.md` | 20% |
| documentation | `prompts/documentation.md` | 15% |
| staleness | `prompts/staleness.md` | 10% |
| standards | `prompts/standards.md` | 10% |

### Step 4: Collect Area Reports

Poll each background agent until all complete. Each agent writes its results as a JSON area report to:
```
<repo_root>/.claude/uplevel/areas/{area}_report.json
```

Area report schema:
```json
{
  "area": "security",
  "score": 85,
  "findings": [
    {
      "id": "SEC-001",
      "severity": "medium",
      "title": "No branch protection on main",
      "location": "project-wide",
      "description": "The main branch has no protection rules configured.",
      "impact": "Unreviewed code can be pushed directly to main.",
      "remediation": "Enable branch protection via Settings > Branches > Add rule.",
      "effort": "small",
      "auto_fixable": false
    }
  ],
  "summary": {
    "critical": 0,
    "high": 0,
    "medium": 1,
    "low": 0,
    "info": 0
  }
}
```

### Step 5: Score & Aggregate

Run the scoring engine:

```bash
python3 ~/.claude/skills/uplevel/scripts/score.py \
  --areas-dir "<repo_root>/.claude/uplevel/areas" \
  --output "<repo_root>/.claude/uplevel/uplevel_report.json" \
  --project-info '<project_info_json>'
```

This computes the weighted overall score and merges all area reports into a unified report.

### Step 6: Generate Markdown Report

```bash
python3 ~/.claude/skills/uplevel/scripts/report.py \
  --input "<repo_root>/.claude/uplevel/uplevel_report.json" \
  --output "<repo_root>/.claude/uplevel/uplevel_report.md"
```

### Step 7: Create GitHub Issues

Only if the repo has a GitHub remote:

```bash
bash ~/.claude/skills/uplevel/scripts/create_issues.sh \
  --report "<repo_root>/.claude/uplevel/uplevel_report.json" \
  --repo "<owner>/<repo>"
```

This creates issues for HIGH and CRITICAL findings, with labels `uplevel`, `uplevel:{area}`, `severity:{level}`. It checks for existing issues by finding ID to avoid duplicates.

### Step 8: Save History & Display Results

1. Copy the JSON report to `history/<timestamp>.json`
2. Update `history/latest.json` symlink
3. If a previous report exists, compute trend (score delta per area)
4. Read the markdown report and display it to the user

## Output Format

Display the markdown report directly to the user. Key sections:
- Overall score with rating (Exemplary / Healthy / Needs Work / At Risk / Critical)
- Score summary table with visual bars per area
- Top 3-5 critical/high findings highlighted
- Per-area detail sections
- Remediation plan grouped by priority (Immediate / Short-term / Backlog)
- Trend comparison if previous report exists

## Score Interpretation

| Range | Rating | Meaning |
|-------|--------|---------|
| 90-100 | Exemplary | Well-maintained, professional repo |
| 70-89 | Healthy | Some areas need attention but fundamentals solid |
| 50-69 | Needs Work | Significant gaps in multiple areas |
| 30-49 | At Risk | Serious issues to address urgently |
| 0-29 | Critical | Fundamental problems across the board |

## Error Handling

- If a subagent fails or times out, score that area as 0 and note it as "audit failed" in the report
- If `gh` CLI is not available, skip issue creation and note it in the report
- If `--quick` mode is on, clearly mark which checks were skipped
- If the repo has no git remote, skip issue creation and remote-dependent checks

## Quick Mode Differences

When `--quick` is enabled, area agents MUST NOT:
- Run test suites
- Execute `npm audit` / `pip-audit` (use lockfile analysis only)
- Install any tools
- Run builds
- Execute double-runs for flaky detection
- Run any command that modifies the filesystem

Quick mode is read-only: Glob, Grep, Read, and non-destructive `git` commands only.

---

## Write Context Summary (MANDATORY — do this LAST)

Write a compact result summary so the parent session receives key findings:

```bash
cat > .claude/.skill-result.md << 'SKILLEOF'
## Uplevel Audit Result

**Health score:** [n]/100
**Issues created:** [n] GitHub issues

### Top Findings by Severity
- 🔴 Critical: [finding or "none"]
- 🟡 Warning: [finding count and summary]
- 🟢 Info: [finding count]

### Recommended Next Steps
1. [Highest priority action]
2. [Second priority action]
SKILLEOF
```

Keep under 2000 characters. This is consumed by a hook — the parent session will see it automatically.
