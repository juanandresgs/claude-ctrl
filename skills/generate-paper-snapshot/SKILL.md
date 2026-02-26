---
name: generate-paper-snapshot
description: Generate a high-fidelity PaperSnapshot JSON for a paper in the LLM Study Guide curriculum. Extracts verbatim quotes, document structure, coverage map, argument flow, and editorial assessment.
argument-hint: "[paper-slug] e.g. attention-is-all-you-need"
visibility: private
context: fork
agent: general-purpose
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Glob
  - Grep
  - WebFetch
  - WebSearch
  - AskUserQuestion
---

# Generate Paper Snapshot

Produce a `snapshot.json` file for a paper in the LLM Study Guide curriculum. The output conforms to the `PaperSnapshot` TypeScript interface and contains verbatim quotes, structural analysis, and labeled editorial — all traceable to the source.

**Why this exists:** The LLM Study Guide needs high-fidelity paper analysis, not AI-generated summaries. Every claim must be traceable to a verbatim quote with a page/section reference. Editorial interpretation is always labeled and separated from source material.

**Output:** `content/papers/{slug}/snapshot.json` in the LLM Study Guide project.

---

## Known Limitation: The Verbatim Problem

Claude reads text into context, then writes from context. Every "quote" is a reconstruction, not a mechanical copy. Subtle word substitutions can occur.

**Mitigation:** This skill uses a Read-Write-Verify pipeline (Phases 2-6). Phase 6 verification is MANDATORY.

---

## Phase 0: Resolve Paper

Parse `$ARGUMENTS` to get the paper slug.

1. Read `content/papers/{slug}/metadata.json` from the LLM Study Guide project at `/Users/turla/Desktop/LLM_Study_Guide/.worktrees/content-pipeline/` (or `/Users/turla/Desktop/LLM_Study_Guide/` if no worktree).
2. Extract `arxivUrl` (or `blogUrl` if no arxiv) — this is the source URL.
3. If no URL found, use `AskUserQuestion` to get a source URL or file path.

**Project root detection:** Check if `.worktrees/content-pipeline` exists. If yes, use that path. If no, use the main project root.

---

## Phase 1: Ingest Source Material

### For arXiv papers:
- Construct PDF URL: replace `abs` with `pdf` in the arxiv URL (e.g., `https://arxiv.org/pdf/1706.03762`)
- Download with Bash: `curl -L -o tmp/{slug}.pdf "{pdf_url}"`
- Read with `Read` tool using `pages` parameter in 10-page batches
- Note total page count

### For blog posts / HTML sources:
- Use `WebFetch` to retrieve content
- If fetch fails: report failure, ask user for alternative

### For local files:
- Read directly with `Read` tool

Store ingested content reference for subsequent passes.

---

## Phase 2: Structure Discovery (First Pass)

Read through the entire source to build structural understanding. Do NOT extract quotes yet.

Identify:
- All sections/chapters with page ranges
- The paper's own abstract/summary
- The conclusion/discussion section
- Key figures/tables referenced

Write the `documentStructure` array:
```json
[
  {
    "section": "1. Introduction",
    "pageRange": "1-2",
    "description": "Motivates the need for attention-based architectures"
  }
]
```

---

## Phase 3: Section-by-Section Content Extraction

**Critical constraint:** Read one section, extract quotes, write them immediately. Do NOT accumulate multiple sections before writing.

For each section in documentStructure:
1. Re-read just that section from the source
2. Extract 1-3 verbatim quotes (prefer 1-3 sentences each)
3. Tag each with a relevance label (2-3 words)
4. Write to a temporary file `tmp/{slug}-quotes.json` before moving to next section

Build the `selectedContent` array:
```json
[
  {
    "sectionTitle": "1. Introduction",
    "relevanceTag": "Core Motivation",
    "quotes": [
      {
        "text": "The dominant sequence transduction models are based on complex recurrent or convolutional neural networks...",
        "cite": "Section 1, p.1"
      }
    ],
    "context": "Brief editorial bridge between quotes if needed"
  }
]
```

Track coverage as you go — which sections got quotes, which were skipped and why.

---

## Phase 4: Argument Flow Extraction

Trace the paper's logical argument in 5-8 steps. Each step identifies:
- What the paper claims
- How they support the claim
- A key quote (if available)

```json
[
  {
    "step": 1,
    "claim": "Recurrent models are fundamentally limited by sequential computation",
    "evidence": "Authors cite O(n) sequential operations as bottleneck for parallelization",
    "quote": "Recurrent models typically factor computation along the symbol positions...",
    "cite": "Section 1, p.1"
  }
]
```

---

## Phase 5: Connections, Editorial, and Summary

### Connections
Read `content/papers/*/metadata.json` to find related papers. Identify 2-5 connections:
```json
[
  {
    "paperId": "bert",
    "relationship": "inspired by",
    "description": "BERT uses the Transformer encoder architecture introduced in this paper"
  }
]
```

Valid relationship types: "builds on", "contradicts", "extends", "inspired by", "implements", "simplifies", "scales"

### Analyst Assessment
Write a max 250-word editorial synthesis. Rules:
- Distinguish inference from paper content
- No new facts not grounded in the source
- Focus on significance, impact, and limitations

### Representation Assessment
Write 4-6 bullets evaluating:
- How representative this snapshot is of the full paper
- What sections are emphasized/underrepresented
- The paper's own perspective or potential biases
- Any significant content omitted and why

### Summary
Write the summary object:
```json
{
  "oneLiner": "Single sentence capturing the paper's contribution",
  "whyItMatters": "2-3 sentences on significance and impact",
  "keyTakeaways": ["4-6 specific takeaway bullets"],
  "keyConceptsIntroduced": ["List of novel concepts/techniques"]
}
```

### Coverage Map
Build from the tracking done in Phase 3:
```json
[
  {
    "section": "1. Introduction",
    "covered": true,
    "quoteCount": 2,
    "notes": ""
  },
  {
    "section": "References",
    "covered": false,
    "quoteCount": 0,
    "notes": "Reference list, no extractable content"
  }
]
```

---

## Phase 6: Verify ALL Quotes & Assemble

**This phase is MANDATORY. Do not skip it.**

### Quote Verification

For EVERY quote in the extracted content:
1. Re-read the cited page/section from the source
2. Search for the quoted text
3. Compare:
   - **Found verbatim:** mark verified
   - **Found with differences:** correct the quote, note the correction
   - **Not found:** remove the quote, note in coverage

### Assemble snapshot.json

Combine all sections into the final PaperSnapshot:

```json
{
  "generatedAt": "2026-02-13T...",
  "sourceUrl": "https://arxiv.org/abs/...",
  "summary": { ... },
  "documentStructure": [ ... ],
  "coverageMap": [ ... ],
  "selectedContent": [ ... ],
  "argumentFlow": [ ... ],
  "analystAssessment": "...",
  "representationAssessment": [ ... ],
  "connections": [ ... ]
}
```

Write to: `content/papers/{slug}/snapshot.json`

### Rebuild Index

Run from the project root:
```bash
node scripts/generate-papers-index.mjs
```

This regenerates `src/lib/papers/papers-index.ts` to include the new snapshot.

### Verification Log

Print a summary:
```
Snapshot generated: content/papers/{slug}/snapshot.json
- Quotes: [N] verified, [M] corrected, [K] removed
- Coverage: [X]/[Y] sections covered
- Argument flow: [Z] steps
- Connections: [W] papers linked
- Assessment: [word count]/250 words
```

---

## Enforcement Rules

1. **Quotes are verbatim** — never paraphrased. If uncertain, re-read the source.
2. **Every quote includes a cite** — page/section reference.
3. **No invented data.** If a fact isn't in the source, it doesn't appear outside analystAssessment.
4. **analystAssessment clearly labeled as editorial.**
5. **Coverage map accounts for every section** in documentStructure.
6. **Read-then-write, not accumulate-then-write** — extract quotes immediately after reading each section.
7. **Phase 6 verification is mandatory** — never skip it.
8. **Output is valid JSON** conforming to PaperSnapshot interface.

---

## Edge Cases

| Scenario | Handling |
|----------|----------|
| Paper behind paywall | Try arxiv PDF first. If unavailable, ask user for local copy |
| Very long paper (>30 pages) | Batch reads in 10-page chunks, be selective, document omissions |
| Blog post (no page numbers) | Use section headings as cite references |
| Paper has no clear sections | Extract by topic clusters, note in structure |
| PDF extraction artifacts | Note in verification log |
| Paper already has snapshot | Ask user: overwrite or skip? |

---

## After Completion

```
Snapshot complete: {paper title}
- Source: {url}
- Quotes: {N} verified
- Output: content/papers/{slug}/snapshot.json
- Index rebuilt: src/lib/papers/papers-index.ts

Run `npm run build` to verify the snapshot renders correctly.
```

---

## Write Context Summary (MANDATORY — do this LAST)

Write a compact result summary so the parent session receives key findings:

```bash
cat > .claude/.skill-result.md << 'SKILLEOF'
## Paper Snapshot Result: [Paper Title]

**Authors:** [Author list]
**Output:** [path to generated JSON file]

### Key Takeaways
1. [Primary contribution/finding]
2. [Secondary finding]
3. [Methodological insight]

### Relevance
- [Why this paper matters for the user's context]
SKILLEOF
```

Keep under 2000 characters. This is consumed by a hook — the parent session will see it automatically.
