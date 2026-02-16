---
name: deep-research
description: Multi-model deep research with comparative assessment (OpenAI + Perplexity + Gemini). Queries 3 deep research providers in parallel and produces a comparative synthesis.
argument-hint: "[research topic or question]"
context: fork
agent: general-purpose
allowed-tools: Bash, Read, Write, AskUserQuestion, WebSearch
---

# Deep Research: Multi-Model Comparative Analysis

Query up to 3 deep research models (OpenAI o3-deep-research, Perplexity sonar-deep-research, Gemini deep-research-pro) in parallel, then produce a comparative assessment highlighting agreements, disagreements, and unique insights.

## Setup Check

The skill requires at least one API key. Check `~/.claude/.env`:

### First-Time Setup

If no config exists, create it:

```bash
cat > ~/.claude/.env << 'ENVEOF'
# Deep Research API Configuration
# All keys are optional — skill works with any subset

# OpenAI (o3-deep-research via Responses API)
OPENAI_API_KEY=

# Perplexity (sonar-deep-research via Chat Completions API)
PERPLEXITY_API_KEY=

# Gemini (deep-research-pro via Interactions API)
GEMINI_API_KEY=
ENVEOF

chmod 600 ~/.claude/.env
echo "Config created at ~/.claude/.env"
echo "Add at least one API key for deep research."
```

**DO NOT stop if the config doesn't exist.** Create it and tell the user to add keys.

---

## Research Execution

**Step 1: Run the deep research script**

**CRITICAL: This script takes 2-10 minutes.** It runs blocking — do NOT use `run_in_background`. This skill runs in a forked context, so blocking is correct.

Create the output directory and run the script:

```bash
# timeout must exceed script's internal 1800s timeout
# Output stays project-local at .claude/research/ so implementer can reference it
RESEARCH_DIR=".claude/research/DeepResearch_[SafeTopic]_[YYYY-MM-DD]"
mkdir -p "$RESEARCH_DIR" && \
python3 ~/.claude/skills/deep-research/scripts/deep_research.py "$ARGUMENTS" \
  --output-dir "$RESEARCH_DIR" 2>&1
```

Set `timeout: 1920000` on the Bash tool call (script's 1800s timeout + 120s buffer = 1920s = 32 min).

The script will:
- Detect which API keys are configured
- Launch available providers in parallel
- Poll async providers (OpenAI, Gemini) until complete
- Write `raw_results.json` to the output directory
- Print progress to stderr

**IMPORTANT**: Deep research models take 2-10 minutes per provider. The script handles all polling internally. Do NOT interrupt it.

**Step 2: Read and parse the results**

Use the **Read** tool to read `raw_results.json` from the output directory. The file is a JSON object:
```json
{
  "topic": "the research topic",
  "provider_count": 3,
  "success_count": 3,
  "warnings": [],
  "results": [
    {
      "provider": "openai",
      "success": true,
      "report": "full report text...",
      "citations": [{"url": "...", "title": "..."}],
      "model": "o3-deep-research-2025-06-26",
      "elapsed_seconds": 145.3,
      "error": null
    },
    ...
  ]
}
```

**Step 3: Check for provider failures**

**MANDATORY**: Before synthesis, check if `success_count < provider_count` (or check the `warnings` array in the JSON). If ANY providers failed:

1. **Immediately tell the user** with a `WARNING:` prefix — which providers failed, their error messages, and elapsed time
2. You **SHOULD** supplement failed providers with WebSearch to fill knowledge gaps
3. Note which findings in your synthesis came from WebSearch rather than deep research

Do NOT silently skip failed providers. The user must know about failures before reading the report.

---

## Synthesis: Produce the Comparative Report

Read ALL provider reports carefully. Then produce a report in this structure:

```markdown
# Deep Research Report: [Topic]

## Provider Status
| Provider | Status | Time | Notes |
|----------|--------|------|-------|
| OpenAI | OK | 145s | |
| Perplexity | OK | 89s | |
| Gemini | FAILED | 600s | HTTPError: timed out after 600s |

*(Always include this table. Green path: all OK. Failure path: makes problems immediately visible.)*

## Executive Summary
[3-5 sentence overview of the key findings across all models]

## Individual Model Reports

### OpenAI (o3-deep-research) — [elapsed]s
[Condensed key findings from OpenAI's report — preserve the important facts,
remove redundant prose. 200-400 words.]

### Perplexity (sonar-deep-research) — [elapsed]s
[Condensed key findings from Perplexity's report. 200-400 words.]

### Gemini (deep-research-pro) — [elapsed]s
[Condensed key findings from Gemini's report. 200-400 words.]

## Comparative Assessment

### Points of Agreement
[Claims made by 2+ models — these are highest confidence findings]

### Points of Disagreement
[Claims where models contradict each other — note which model says what]

### Unique Insights
[Findings that only one model reported — interesting but lower confidence]

### Confidence Assessment
| Finding | OpenAI | Perplexity | Gemini | Confidence |
|---------|--------|------------|--------|------------|
| [key claim 1] | ✓ | ✓ | ✓ | High |
| [key claim 2] | ✓ | ✓ | — | Medium |
| [key claim 3] | — | — | ✓ | Low |

### Source Quality Comparison
| Provider | Citations | Report Length | Depth |
|----------|-----------|-------------|-------|
| OpenAI | [n] sources | [n] words | [assessment] |
| Perplexity | [n] sources | [n] words | [assessment] |
| Gemini | [n] sources | [n] words | [assessment] |

## References

**CRITICAL: The report must be verifiable.** Include a numbered references section at the end using citations from all providers. Every factual claim in the report should be traceable to a source.

Build the references list by:
1. Collecting all citation URLs from the `citations` arrays in the JSON results
2. Deduplicating by URL (multiple providers may cite the same source)
3. Numbering them sequentially
4. Using inline reference numbers `[1]`, `[2]` etc. throughout the report body to link claims to sources

Format:
[1] Title or description — URL
[2] Title or description — URL
...

If a provider (like Gemini) returns no structured citations, note that its claims are unsourced and lower confidence. Prefer citing claims that have URLs backing them.
```

**Adaptation rules:**
- If only 1 provider succeeded: Skip comparative sections, note limited analysis. Begin Executive Summary with a note about which provider(s) failed and why.
- If only 2 providers succeeded: Pairwise comparison instead of tri-model. Begin Executive Summary with a note about which provider failed and why.
- If 0 providers succeeded: Report the errors and suggest checking API keys

---

## Save All Outputs

The output directory was already created in Step 1. The script already wrote `raw_results.json` there.

Write these additional files to the same directory:

| File | Contents |
|------|----------|
| `report.md` | Your comparative synthesis (the report above) |
| `openai.md` | OpenAI's full report text (from `results[].report` where provider=openai) |
| `perplexity.md` | Perplexity's full report text |
| `gemini.md` | Gemini's full report text |

Only write provider files for providers that succeeded. The raw individual reports are often 5-40K chars — preserve them in full, don't truncate.

Tell the user where the reports were saved and list the files.

---

## Graceful Degradation

| Keys Available | Behavior |
|---|---|
| 0 | Error with setup instructions |
| 1 | Single provider report, note limited comparison |
| 2 | Pairwise comparison |
| 3 | Full tri-model comparison |

---

## Write Context Summary (MANDATORY — do this LAST)

Write a compact result summary so the parent session receives key findings:

```bash
cat > .claude/.skill-result.md << 'SKILLEOF'
## Deep Research Result: [Topic]

**Status:** [n]/3 providers succeeded | [list any failures]
**Time:** [total elapsed]s
**Output:** .claude/research/DeepResearch_[Topic]_[Date]/report.md

### Key Findings (highest confidence)
1. [Finding supported by 2+ providers]
2. [Finding supported by 2+ providers]
3. [Additional key finding]

### Needs Attention
- [Any provider failures or gaps worth noting]
SKILLEOF
```

Keep under 2000 characters. This is consumed by a hook — the parent session will see it automatically.

---

## After the Report

End with:
```
---
Deep Research complete — [n]/3 providers succeeded.
WARNING: [provider names] failed — [brief error reasons] (only include this line if any failed)
- Total research time: [sum of elapsed]s
- Report saved to: .claude/research/DeepResearch_[Topic]_[Date]/report.md

Want me to dig deeper into any specific finding?
```
