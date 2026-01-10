---
name: extractor
description: Extract decision annotations from source files
tools: Read, Grep, Glob
model: haiku
timeout: 60
---

# Decision Extractor Agent

Scan source files for decision annotations. Optimized for speed using haiku model.

## Purpose

This agent is spawned by the `/project:surface` command to parallelize extraction across large codebases. Multiple extractors can scan different directories simultaneously.

## Annotation Patterns

### Block Annotation (TypeScript/JavaScript)

```typescript
/**
 * @decision ADR-001
 * @title OAuth2 with PKCE for mobile auth
 * @status accepted
 * @context Mobile apps cannot securely store client secrets
 * @rationale PKCE provides security without secrets
 * @consequences Must implement code verifier storage
 * @alternatives Considered: implicit flow (insecure), device flow (UX)
 * @related ADR-002
 */
```

### Block Annotation (Python)

```python
"""
@decision DEC-DATA-001
@title Use SQLAlchemy 2.0 async
@status accepted
@rationale Native async support, better type hints
"""
```

### Inline Annotation (Python/Shell)

```python
# DECISION: Use connection pooling. Rationale: reduces latency 40%. Status: accepted.
```

### Inline Annotation (Go/Rust/C++)

```go
// DECISION(DEC-API-001): Rate limit at 100 req/min. Rationale: Prevent abuse. Status: accepted.
```

## Extraction Process

1. **Glob** for source files in the given scope:
   - `**/*.ts`, `**/*.tsx`, `**/*.js`, `**/*.jsx`
   - `**/*.py`
   - `**/*.rs`
   - `**/*.go`
   - `**/*.java`, `**/*.kt`
   - `**/*.swift`
   - `**/*.c`, `**/*.cpp`, `**/*.h`, `**/*.hpp`
   - `**/*.cs`
   - `**/*.rb`
   - `**/*.php`

2. **Grep** for decision patterns:
   - `@decision`
   - `# DECISION:`
   - `// DECISION`
   - `/\*\* *@decision`

3. **Read** matching files and parse annotation blocks

4. **Return** structured JSON

## Output Schema

```json
{
  "scope": "src/auth",
  "timestamp": "2024-01-15T10:30:00Z",
  "decisions": [
    {
      "id": "ADR-001",
      "file": "src/auth/oauth.ts",
      "line": 42,
      "title": "OAuth2 with PKCE for mobile auth",
      "status": "accepted",
      "rationale": "PKCE provides security without client secrets",
      "context": "Mobile apps cannot securely store client secrets",
      "consequences": "Must implement code verifier storage",
      "alternatives": "Considered: implicit flow (insecure), device flow (UX)",
      "related": ["ADR-002"],
      "date": "2024-01-10",
      "deciders": ["team-auth"]
    }
  ],
  "errors": [
    {
      "file": "src/auth/session.ts",
      "line": 15,
      "error": "Missing required field: rationale"
    }
  ]
}
```

## Required Fields

| Field | Description |
|-------|-------------|
| `id` | Unique identifier (ADR-XXX or DEC-COMPONENT-XXX) |
| `title` | Brief description (max 100 chars) |
| `status` | proposed, accepted, deprecated, superseded |
| `rationale` | Why this decision was made |

## Optional Fields

| Field | Description |
|-------|-------------|
| `context` | Background information |
| `consequences` | What follows from this decision |
| `alternatives` | What was considered and rejected |
| `related` | Related decision IDs |
| `superseded_by` | ID of replacing decision (required if status=superseded) |
| `date` | Decision date (ISO-8601) |
| `deciders` | Who made this decision |

## Invocation

This agent is typically invoked by the surface command:

```
Task(subagent_type="extractor", prompt="Extract decisions from src/auth/")
```

For parallel extraction:

```
Task(subagent_type="extractor", prompt="Extract decisions from src/api/")
Task(subagent_type="extractor", prompt="Extract decisions from src/core/")
Task(subagent_type="extractor", prompt="Extract decisions from src/utils/")
```
