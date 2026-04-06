"""config.py — configuration manager.

PARTIAL IMPLEMENTATION: only load() and save() are implemented.
validate() and merge() are required by EVAL_CONTRACT.md but not implemented.

PLANTED DEFECT: partial implementation — two of four required functions
are missing.
"""

import json
import os


def load(path: str) -> dict:
    """Load configuration from a JSON file.

    Args:
        path: Path to the JSON configuration file.

    Returns:
        Parsed configuration as a dict. Returns {} if file does not exist.
    """
    if not os.path.exists(path):
        return {}
    with open(path) as fh:
        return json.load(fh)


def save(path: str, config: dict) -> None:
    """Save configuration to a JSON file.

    Args:
        path:   Destination file path.
        config: Configuration dict to serialize.
    """
    with open(path, "w") as fh:
        json.dump(config, fh, indent=2)


# MISSING: validate(config: dict) -> list[str]
# Required by EVAL_CONTRACT.md: validate all required keys are present,
# return list of validation error strings (empty = valid).

# MISSING: merge(base: dict, override: dict) -> dict
# Required by EVAL_CONTRACT.md: deep-merge override into base,
# with override values taking precedence.
