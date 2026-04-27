"""Feature module — used as the gate fixture for eval-invalidation.

This module represents an implementation that has already passed evaluation
(evaluation_state=ready_for_guardian). A reviewer attempting to write this
source file after clearance is still denied by write_who.
"""


def process(items: list) -> list:
    """Process a list of items, filtering out None values."""
    return [item for item in items if item is not None]


def count(items: list) -> int:
    """Count non-None items in a list."""
    return len(process(items))
