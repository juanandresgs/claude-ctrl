---
name: context-preservation
description: Generate structured context summaries for session continuity across compaction
---

# Context Preservation Skill

Generate structured context summaries when compaction is imminent or requested, ensuring session continuity without information loss.

## Output Format (STRICT - NO DEVIATIONS)

```markdown
### 1. Current Objective & Status
- **Goal**: [Robust, multi-sentence description of what we are building. Include critical details, context, and the "Definition of Done". Do not summarize into a single vague line.]
- **Status**: [Completed | In Progress | Blocked]
- **Immediate Next Step**: [The very next command or code edit required. Be specific.]

### 2. Active Context
- **Active Files**:
  - `[Absolute Path]`
  - `[Absolute Path]`
- **Recent Changes**: [Specific descriptions of what *just* changed in the code, referencing specific functions or logic.]
- **Variables/State**: [Key variable names, data structures, or temporary states currently in focus.]

### 3. Constraints & Decisions (CRITICAL)
- **Preferences**: [User preferences stated in this session, e.g., "no external deps", "use snake_case"]
- **Discarded Approaches**: [What did we try that failed? Do not repeat these mistakes.]
- **Architectural Rules**: [Patterns we agreed on, e.g., "Service Layer pattern", "DTOs required"]

### 4. Continuity Handoff
- "When resuming, the first thing to do is..."
```

## Content Extraction

### Section 1: Current Objective & Status
- Extract goal from user's initial request, explicit goal statements, Definition of Done indicators
- Status: `Completed` (all objectives achieved), `In Progress` (work ongoing), `Blocked` (explicit blocker)
- Next step: last in-progress item, last "next I will..." statement, or first pending objective

### Section 2: Active Context
- Files touched via Read/Write/Edit operations, prioritized by recency
- **ALWAYS use absolute paths** (e.g., `/Users/turla/Code/project/src/auth.ts`)
- Summarize function additions, modifications, deletions with specific names and line refs
- Key variables, data structures, environment variables in focus

### Section 3: Constraints & Decisions
- Preferences: "don't use...", "prefer...", "always...", "never..."
- Discarded approaches: failed attempts with reasons
- Architectural rules: pattern agreements, structure decisions, dependency choices

### Section 4: Continuity Handoff
- Always begin with "When resuming, the first thing to do is..."
- Must be specific enough for a fresh Claude instance to immediately continue

## Anti-Patterns (NEVER DO)

### Goal Description

**WRONG**:
- "Building a feature"
- "Working on authentication"

**RIGHT**:
- "Building a user authentication system with OAuth2 PKCE flow for the mobile app. The system must support Google and Apple SSO, store refresh tokens securely in the device keychain. Definition of Done: user can complete full login flow, tokens persist across app restarts, logout clears all tokens."

### Active Files

**WRONG**:
- `file.ts`
- `./src/auth.ts`

**RIGHT**:
- `/Users/turla/Code/myproject/src/auth/oauth-handler.ts`

### Recent Changes

**WRONG**:
- "Updated the file"
- "Fixed some issues"

**RIGHT**:
- "Added `validateTokenExpiry()` function to `/Users/turla/Code/myproject/src/auth/token-storage.ts` (lines 42-67) that checks JWT expiration. Modified `refreshToken()` to call this before attempting refresh."

### Immediate Next Step

**WRONG**:
- "Continue working"
- "Finish the implementation"

**RIGHT**:
- "Run `npm test -- --testPathPattern=oauth-handler` to verify the new `validateTokenExpiry()` function works with expired tokens"

## Validation Checklist

### Section 1
- [ ] Goal is 2+ sentences with Definition of Done
- [ ] Status is exactly: Completed, In Progress, or Blocked
- [ ] Next step is a specific command or edit

### Section 2
- [ ] All file paths are absolute (start with `/`)
- [ ] Recent changes reference specific function/method names

### Section 3
- [ ] Discarded approaches explain WHY they were discarded
- [ ] No empty sections (use "None stated this session" if applicable)

### Section 4
- [ ] Starts with "When resuming, the first thing to do is..."
- [ ] Contains a specific, actionable instruction
