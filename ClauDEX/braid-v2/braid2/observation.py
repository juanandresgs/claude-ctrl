from __future__ import annotations

import re


def significant_lines(text: str) -> list[str]:
    return [line.strip() for line in str(text).splitlines() if line.strip()]


def first_matching_line(text: str, pattern: str) -> str | None:
    regex = re.compile(pattern, re.IGNORECASE)
    for line in significant_lines(text):
        if regex.search(line):
            return line
    return None


def extract_numbered_choices(text: str) -> list[dict[str, str]]:
    choices: list[dict[str, str]] = []
    for line in significant_lines(text):
        match = re.match(r"^(?:[>*>❯]\s*)?(\d+)\.\s+(.*)$", line)
        if match:
            choices.append({"choice": match.group(1), "label": match.group(2)})
    return choices


def extract_selected_choice(text: str) -> str | None:
    line = first_matching_line(text, r"^[>*>❯]\s*\d+\.\s+")
    if not line:
        return None
    match = re.match(r"^[>*>❯]\s*(\d+)\.\s+", line)
    return match.group(1) if match else None


def summarize_text(text: str, limit: int = 300) -> str:
    compact = " ".join(significant_lines(text))
    if len(compact) <= limit:
        return compact
    return compact[: limit - 3] + "..."


def detect_interaction_gate(text: str) -> dict | None:
    if not text:
        return None

    choices = extract_numbered_choices(text)
    selected_choice = extract_selected_choice(text)

    trust_line = first_matching_line(text, r"Do you trust the contents of this directory\?")
    if trust_line:
        return {
            "gate_type": "trust_prompt",
            "prompt_excerpt": trust_line,
            "choices": choices,
            "selected_choice": selected_choice,
        }

    edit_line = first_matching_line(text, r"Do you want to make this edit(?:\s+to\s+.+?)?\?")
    if edit_line:
        return {
            "gate_type": "edit_approval",
            "prompt_excerpt": edit_line,
            "choices": choices,
            "selected_choice": selected_choice,
        }

    settings_line = first_matching_line(text, r"allow .* to edit .* settings .* session")
    if settings_line:
        return {
            "gate_type": "settings_approval",
            "prompt_excerpt": settings_line,
            "choices": choices,
            "selected_choice": selected_choice,
        }

    permission_line = first_matching_line(
        text,
        r"\b(allow|approve|permission|deny|continue|bypass permissions|tool permission|mcp)\b",
    )
    if permission_line and choices:
        return {
            "gate_type": "permission_prompt",
            "prompt_excerpt": permission_line,
            "choices": choices,
            "selected_choice": selected_choice,
        }

    return None

