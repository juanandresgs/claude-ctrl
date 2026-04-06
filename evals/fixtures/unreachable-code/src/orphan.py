"""orphan.py — DEFECTIVE: unreachable new module.

This module is never imported by main.py or any other module in the project.
It was added as part of the feature implementation but the implementer forgot
to wire it into the application entry point.

PLANTED DEFECT: dead code — orphan.py is not reachable from any entry point.
"""


def summarize(items: list) -> str:
    """Produce a comma-separated summary of the given items."""
    return ", ".join(str(item) for item in items if item is not None)


def count_unique(items: list) -> int:
    """Count distinct non-None values in items."""
    return len({item for item in items if item is not None})
