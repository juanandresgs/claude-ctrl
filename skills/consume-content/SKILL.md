---
name: consume-content
description: Produce a faithful content-snapshot of any source material (article, report, PDF, advisory) with verbatim quotes, structural transparency, and labeled editorial.
argument-hint: "[URL, PDF path, or file path]"
context: fork
agent: general-purpose
allowed-tools:
  - Bash
  - Read
  - Write
  - Glob
  - Grep
  - WebFetch
  - WebSearch
  - AskUserQuestion
---

# Content Snapshot Skill

Produce a structured, verifiable content-snapshot of source material — articles, reports, PDFs, advisories, papers, transcripts. The output follows the Content Snapshot v0.2 template (see `template.md` in this directory) with verbatim quotes, structural transparency, and labeled editorial.

**Why this exists:** Narrated summaries of source material risk hallucinations and misrepresentation. Content-snapshots solve this by making every claim traceable to a verbatim quote with a page/section reference. The analyst's interpretation is always labeled and separated.

---

## Known Limitation: The Verbatim Problem

Claude doesn't copy-paste. It reads text into context, then writes from context. Every "quote" is a reconstruction from the context window, not a mechanical transfer. This means subtle word substitutions, dropped articles, or reordering can occur even with good intent. A content-snapshot that silently mangles quotes is worse than a summary — it lies about its own fidelity.

**Mitigation:** This skill uses a Read-Write-Verify pipeline (Phases 3 and 5) designed to minimize reconstruction error. Phase 5 verification is MANDATORY, not optional.

**What this can't guarantee:**
- PDF text extraction isn't perfect — OCR artifacts, ligatures, encoding issues can cause mismatches even when the quote is faithfully reproduced
- Very long quotes (4+ sentences) have higher reconstruction error risk than short ones
- If the user needs guaranteed verbatim fidelity for legal/compliance use, they should verify against the original document

---

## Phase 1: Detect Input & Ingest

Parse `$ARGUMENTS` to determine input type and ingest the source material.

### Input Detection

| Pattern | Type | Tool |
|---------|------|------|
| Starts with `http://` or `https://` | URL | `WebFetch` |
| Ends with `.pdf` | PDF file | `Read` with `pages` parameter |
| Existing file path | Local file | `Read` |
| None of the above | Ask user | `AskUserQuestion` |

### Ingestion Rules

**URLs:**
- Use `WebFetch` to retrieve content
- If fetch fails (paywall, 403, redirect loop): report failure, ask user for a local copy or pasted content
- Store the fetched content for subsequent passes

**PDFs:**
- Read with `pages` parameter in 20-page batches: `pages: "1-20"`, `pages: "21-40"`, etc.
- Continue until all pages are read
- Note total page count for structure mapping

**Local files:**
- Read directly with `Read` tool
- For very large files (>2000 lines), read in segments

### Output Setup

Create the output directory:
```
.claude/snapshots/{slugified-title}_{YYYY-MM-DD}/
```

Slugify the title: lowercase, replace spaces with hyphens, remove special characters, truncate to 50 chars.

Write a preliminary `snapshot.md` with a header:
```markdown
# Content Snapshot: [Title]

**Source:** [URL or file path]
**Author:** [if known]
**Date:** [publication date if known]
**Snapshot Date:** [today's date]
**Template:** Content Snapshot v0.2

---
```

---

## Phase 2: Structure Discovery (First Pass)

Read through the entire source to build a structural understanding. Do NOT extract quotes yet.

Identify:
- Title, author(s), publication date
- Total length (pages or word count estimate)
- Document structure: chapters, sections, headings
- Whether the source has its own summary/abstract/key findings
- The source's conclusion/recommendations section (for Section 5)

Write to `snapshot.md`:

**Section 2 — Document Structure:**
- Chapter/section outline with 1-2 sentence neutral descriptions
- Include page ranges (PDFs) or section identifiers (web content)

If the source has no discernible structure (e.g., a short blog post), note this and adapt: treat the entire piece as a single section.

---

## Phase 3: Content Extraction (Section-at-a-Time)

This is the high-fidelity extraction pass. The key constraint: **read one section, write its quotes, then move to the next.** Do not accumulate multiple sections in context before writing.

### For each section in the Document Structure:

1. **Re-read just that section** from the source (use page ranges for PDFs, section offsets for files)
2. **Immediately extract 1-3 verbatim quotes** — prefer shorter quotes (1-3 sentences) where accuracy is easier to maintain
3. **Write the quotes to `snapshot.md` before reading the next section** — this is critical for fidelity
4. **Tag each quote** with a relevance label (2-3 words)
5. Format each quote as:

```markdown
#### [Section Title] — [pages/location]
**[Relevance Tag]**

> "[Verbatim quote from source]"
> <cite>[Page X / Section Y]</cite>
```

### Section 1 — Key Findings (Author Summary):
- If the source has its own summary/abstract/executive summary: extract verbatim bullets with page references
- If not: write "No author summary present in source" and skip

### Section 4 — Selected Content:
- Add a selection criteria note at the top explaining what was prioritized
- Process each section from the Document Structure in order

### Section 5 — Why This Matters (Author Conclusions):
- Extract direct quotes from the source's conclusion/implications/recommendations
- No paraphrase — only verbatim quotes

### Coverage Tracking:
As you process each section, track coverage for Section 3:
- Which sections received quotes (covered)
- Which sections were omitted and why

After all sections are processed, write **Section 3 — Coverage Map** as a table:

```markdown
| Section | Covered? | Quotes | Notes |
|---------|----------|--------|-------|
| [name]  | Yes      | 2      |       |
| [name]  | No       | 0      | Background only, no novel findings |
```

Every section from the Document Structure must appear in this table.

---

## Phase 4: Editorial & Self-Audit

### Section 6 — Analyst Assessment:
Write a brief synthesis (max 250 words). Rules:
- Open with: *"The following is editorial analysis, not source material."*
- Distinguish inference from report content
- No new facts not grounded in the source
- Count your words — stay under 250

### Section 7 — Representation Assessment:
Write 4-6 bullets evaluating:
- How representative this snapshot is of the full source
- What perspectives or topics are emphasized/underrepresented
- The source's own perspective, bias, or institutional position
- Any significant content that was omitted and why

---

## Phase 5: Verify ALL Quotes & Deliver

**This phase is MANDATORY. Do not skip it.**

### Quote Verification

For EVERY blockquote in `snapshot.md`:

1. **Re-read the cited page/section from the source** — use the page/section reference in the `<cite>` tag
2. **Search for the quoted text** in the re-read content using `Grep` if the source is a local file
3. **Compare the quote against the source:**
   - **If found verbatim:** mark as verified
   - **If found with differences:** note the specific differences, correct the quote in `snapshot.md` using `Edit`
   - **If not found at all:** flag as potential fabrication — remove the quote and attempt to re-extract from the source, or remove entirely with a note

### Structural Checks

- Every blockquote has a `<cite>` with page/section reference
- Coverage Map accounts for every section in the Document Structure
- Analyst Assessment is under 250 words (count them)
- No text outside blockquotes presents itself as source material
- Sections appear in template order (1-7)

### Verification Log

Append to the end of `snapshot.md`:

```markdown
---

## Verification Log

- **Quotes verified:** [N]
- **Corrections made:** [M]
- **Quotes removed (unverifiable):** [K]
- **Coverage map complete:** Yes/No
- **Analyst Assessment word count:** [W]/250
```

### Delivery

- Report the output path to the user: `.claude/snapshots/{slug}_{date}/snapshot.md`
- If any quote could not be verified and was not removed, do NOT deliver — ask user for guidance
- If all quotes verified (with or without corrections), deliver the snapshot

---

## Enforcement Rules

These constraints make the skill reliable. They are non-negotiable:

1. **Quotes are verbatim** — never paraphrased. If uncertain about exact wording, re-read the source.
2. **Every quote includes page/section reference** in a `<cite>` tag.
3. **No invented data.** If a fact isn't in the source, it doesn't appear outside the Analyst Assessment.
4. **Analyst Assessment clearly labeled as editorial** — opens with italic disclaimer.
5. **Remove UI artifacts** — file paths, pagination chrome, dashboard headers, navigation elements.
6. **If source lacks an author summary,** note this explicitly. Do NOT fabricate one.
7. **Coverage Map must account for every section** in the Document Structure — nothing silently omitted.
8. **Representation Assessment must note** the perspective/bias of the source itself.
9. **Phase 5 verification is mandatory** — never skip it, never treat it as optional.
10. **Read-then-write, not accumulate-then-write** — extract quotes immediately after reading each section.

---

## Edge Cases

| Scenario | Handling |
|----------|----------|
| No abstract/summary in source | Skip Section 1, note: "No author summary present" |
| Very short source (<2 pages) | Collapse sections, quote most content directly |
| Very long source (>100 pages) | Batch reads in 20-page chunks, be selective, document omissions thoroughly in Coverage Map |
| URL behind paywall/403 | Report failure, ask user for local copy or paste |
| Multiple sources provided | Ask user: separate snapshots or combined? |
| Non-English source | Quote in original language, note language in header |
| Source is a thread/chat/transcript | Adapt structure to chronological, quote key exchanges |
| PDF with OCR artifacts | Note in Verification Log that text extraction quality may affect quote fidelity |
| Source has no clear sections | Treat as single section, extract quotes by topic clusters |

---

## Write Context Summary (MANDATORY — do this LAST)

Write a compact result summary so the parent session receives key findings:

```bash
cat > .claude/.skill-result.md << 'SKILLEOF'
## Content Snapshot Result: [Title]

**Source:** [URL or document path]
**Output:** [path to generated snapshot file]
**Quotes extracted:** [n]

### Key Takeaways
1. [Most important insight]
2. [Second key insight]
3. [Third key insight]

### Coverage
- [What was covered well]
- [Any gaps or sections skipped]
SKILLEOF
```

Keep under 2000 characters. This is consumed by a hook — the parent session will see it automatically.

---

## After Completion

```
---
Content Snapshot complete.
- Source: [title or URL]
- Quotes: [N] verified, [M] corrected, [K] removed
- Output: .claude/snapshots/{slug}_{date}/snapshot.md

Want me to snapshot another source, or integrate this into a project?
```
