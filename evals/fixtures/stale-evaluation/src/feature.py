"""feature.py — simple feature module.

This module was modified AFTER the last evaluator clearance. The stored
head_sha in evaluation_state no longer matches the current HEAD.

PLANTED DEFECT: stale evaluation — source changed after tester clearance.
The IMPL_HEAD_SHA in the last tester output does not match current HEAD.
"""


def compute(values: list[int]) -> dict:
    """Compute basic statistics for a list of integers.

    Returns a dict with keys: min, max, sum, count.
    Returns all zeros for an empty list.
    """
    if not values:
        return {"min": 0, "max": 0, "sum": 0, "count": 0}
    return {
        "min": min(values),
        "max": max(values),
        "sum": sum(values),
        "count": len(values),
    }
