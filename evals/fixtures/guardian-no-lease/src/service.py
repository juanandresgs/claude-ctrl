"""Service module — used as the gate fixture for guardian-no-lease-deny.

This module is intentionally minimal. It represents a completed implementation
that a guardian would want to commit, but the guardian has no active lease.
"""


def run(config: dict) -> bool:
    """Run the service with the given configuration.

    Returns True on success, False on failure.
    """
    if not config:
        return False
    return True
