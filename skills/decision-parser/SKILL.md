---
name: decision-parser
description: Parse and validate @decision annotations from source code
---

# Decision Parser Skill

Parse and validate decision annotations from source code comments.

## Annotation Formats

### Block Format (JSDoc-style)

```
/**
 * @decision <ID>
 * @title <TITLE>
 * @status <STATUS>
 * @rationale <RATIONALE>
 * [@context <CONTEXT>]
 * [@alternatives <ALTERNATIVES>]
 */
```

### Block Format (Python docstring)

```
"""
@decision <ID>
@title <TITLE>
@status <STATUS>
@rationale <RATIONALE>
"""
```

### Inline Format

```
# DECISION: <TITLE>. Rationale: <RATIONALE>. Status: <STATUS>.
// DECISION(<ID>): <TITLE>. Rationale: <RATIONALE>.
```

## Required Fields

| Field | Format | Constraints |
|-------|--------|-------------|
| `id` | `ADR-NNN` or `DEC-COMPONENT-NNN` | Unique across codebase |
| `title` | Free text | Max 100 characters |
| `status` | Enum | `proposed`, `accepted`, `deprecated`, `superseded` |
| `rationale` | Free text | At least 10 characters |

## Optional Fields

| Field | Format |
|-------|--------|
| `context` | Background information |
| `alternatives` | Rejected options and why |

## ID Conventions

- **ADR-NNN**: System-wide architectural decisions (e.g., ADR-001 Authentication strategy)
- **DEC-COMPONENT-NNN**: Component-specific decisions (e.g., DEC-AUTH-001 Token refresh strategy)

## Validation Rules

- ID pattern: `^(ADR|DEC)-[A-Z0-9]+-?[0-9]+$`
- IDs must be unique across the codebase
- Status must be one of: `proposed`, `accepted`, `deprecated`, `superseded`
- Title max 100 characters, rationale min 10 characters
- No duplicate annotations in same file
