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

The skill requires at least one API key. Check `~/.config/deep-research/.env`:

### First-Time Setup

If no config exists, create it:

```bash
mkdir -p ~/.config/deep-research
cat > ~/.config/deep-research/.env << 'ENVEOF'
# Deep Research API Configuration
# All keys are optional — skill works with any subset

# OpenAI (o3-deep-research via Responses API)
OPENAI_API_KEY=

# Perplexity (sonar-deep-research via Chat Completions API)
PERPLEXITY_API_KEY=

# Gemini (deep-research-pro via Interactions API)
GEMINI_API_KEY=
ENVEOF

chmod 600 ~/.config/deep-research/.env
echo "Config created at ~/.config/deep-research/.env"
echo "Add at least one API key for deep research."
```

**DO NOT stop if the config doesn't exist.** Create it and tell the user to add keys.

---

## Research Execution

**Step 1: Run the deep research script**

**CRITICAL: This script takes 2-10 minutes.** Run it in the background so you can tell the user what's happening while it works.

```bash
# Run in background — use run_in_background: true on the Bash tool call
python3 ~/.claude/skills/deep-research/scripts/deep_research.py "$ARGUMENTS" --emit=json 2>&1
```

After launching, immediately tell the user:
> "Deep research launched across [N] providers. This typically takes 2-10 minutes. I'll synthesize the results when all providers report back."

Then use **TaskOutput** (with `block: true, timeout: 600000`) to wait for the result. When it returns, proceed to Step 2.

The script will:
- Detect which API keys are configured
- Launch available providers in parallel
- Poll async providers (OpenAI, Gemini) until complete
- Output structured JSON to stdout with progress to stderr

**IMPORTANT**: Deep research models take 2-10 minutes per provider. The script handles all polling internally. Do NOT interrupt it.

**Step 2: Parse the JSON output**

The output is a JSON object:
```json
{
  "topic": "the research topic",
  "provider_count": 3,
  "success_count": 3,
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

**Step 3: If any providers failed**, optionally supplement with WebSearch to fill gaps.

---

## Synthesis: Produce the Comparative Report

Read ALL provider reports carefully. Then produce a report in this structure:

```markdown
# Deep Research Report: [Topic]

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
- If only 1 provider succeeded: Skip comparative sections, note limited analysis
- If only 2 providers succeeded: Pairwise comparison instead of tri-model
- If 0 providers succeeded: Report the errors and suggest checking API keys

---

## Save All Outputs

Save everything to a dated directory:

```bash
mkdir -p ~/Documents/DeepResearch_[SafeTopic]_[YYYY-MM-DD]
```

Write these files:

| File | Contents |
|------|----------|
| `report.md` | Your comparative synthesis (the report above) |
| `raw_results.json` | The full JSON output from the script (copy verbatim) |
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

## After the Report

End with:
```
---
Deep Research complete.
- Providers: [n]/3 succeeded
- Total research time: [sum of elapsed]s
- Report saved to: ~/Documents/DeepResearch_[Topic]_[Date]/report.md

Want me to dig deeper into any specific finding?
```
