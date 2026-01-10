---
name: decision-parser
description: Parse decision annotation syntax from source code
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
 * [@consequences <CONSEQUENCES>]
 * [@alternatives <ALTERNATIVES>]
 * [@related <ID1>, <ID2>]
 * [@superseded_by <ID>]
 * [@date <ISO-DATE>]
 * [@deciders <NAME1>, <NAME2>]
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
// DECISION(<ID>): <TITLE>. Rationale: <RATIONALE>. Status: <STATUS>.
```

## Field Specifications

### Required Fields

| Field | Format | Constraints |
|-------|--------|-------------|
| `id` | `ADR-NNN` or `DEC-COMPONENT-NNN` | Unique, alphanumeric with hyphens |
| `title` | Free text | Max 100 characters |
| `status` | Enum | `proposed`, `accepted`, `deprecated`, `superseded` |
| `rationale` | Free text | At least 10 characters |

### Optional Fields

| Field | Format | Constraints |
|-------|--------|-------------|
| `context` | Free text | Background information |
| `consequences` | Free text | Resulting impacts |
| `alternatives` | Free text | Rejected options |
| `related` | Comma-separated IDs | Must reference existing decisions |
| `superseded_by` | Single ID | Required if status=superseded |
| `date` | ISO-8601 | e.g., 2024-01-15 |
| `deciders` | Comma-separated names | Who made the decision |

## ID Conventions

### Architecture Decision Records (ADR)

Format: `ADR-NNN`

Used for:
- System-wide architectural decisions
- Cross-cutting concerns
- Technology choices
- Integration patterns

Examples:
- `ADR-001` - Authentication strategy
- `ADR-015` - Database selection
- `ADR-042` - API versioning approach

### Component Decisions (DEC)

Format: `DEC-COMPONENT-NNN`

Used for:
- Component-specific design choices
- Implementation details
- Local optimizations

Examples:
- `DEC-AUTH-001` - Token refresh strategy
- `DEC-API-003` - Rate limiting approach
- `DEC-DATA-007` - Caching policy

## Validation Rules

### ID Validation
- Must match pattern: `^(ADR|DEC)-[A-Z0-9]+-?[0-9]+$`
- Must be unique across the codebase
- Must not be empty

### Status Validation
- Must be one of: `proposed`, `accepted`, `deprecated`, `superseded`
- If `superseded`, `superseded_by` field is required

### Reference Validation
- `superseded_by` must reference an existing decision
- `related` IDs must all reference existing decisions
- No circular supersession chains allowed

### Content Validation
- `title` max 100 characters
- `rationale` min 10 characters (must be meaningful)
- No duplicate annotations in same file

## Parsing Priority

When multiple annotation styles are present, parse in order:
1. Block annotations (most complete)
2. Inline annotations (supplementary)

## Error Handling

### Missing Required Field
```json
{
  "error": "MISSING_FIELD",
  "field": "rationale",
  "file": "src/auth.ts",
  "line": 42
}
```

### Invalid Status
```json
{
  "error": "INVALID_STATUS",
  "value": "approved",
  "valid": ["proposed", "accepted", "deprecated", "superseded"],
  "file": "src/auth.ts",
  "line": 44
}
```

### Duplicate ID
```json
{
  "error": "DUPLICATE_ID",
  "id": "ADR-001",
  "locations": [
    {"file": "src/auth.ts", "line": 42},
    {"file": "src/api.ts", "line": 15}
  ]
}
```

### Broken Reference
```json
{
  "error": "BROKEN_REFERENCE",
  "id": "ADR-003",
  "references": "ADR-999",
  "file": "src/auth.ts",
  "line": 48
}
```
