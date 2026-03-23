"""Centralized API key management for all Claude Code skills.

Loads API keys from ~/.claude/.env with environment variable overrides.
Skills import from here instead of maintaining their own .env loaders.

@decision Centralized .env at ~/.claude/.env — eliminates duplicate keys
across skills (deep-research, last30days both had separate OPENAI_API_KEY).
Single file to maintain, env vars still override for CI/containers.
"""

import os
from pathlib import Path
from typing import Dict, Optional

CENTRAL_ENV = Path.home() / ".claude" / ".env"


def load_env_file(path: Path) -> Dict[str, str]:
    """Load key=value pairs from a .env file."""
    env = {}
    if not path.exists():
        return env

    with open(path, 'r') as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            if '=' in line:
                key, _, value = line.partition('=')
                key = key.strip()
                value = value.strip()
                if value and value[0] in ('"', "'") and value[-1] == value[0]:
                    value = value[1:-1]
                if key and value:
                    env[key] = value
    return env


def get_key(name: str) -> Optional[str]:
    """Get a single API key. Env var overrides .env file."""
    return os.environ.get(name) or load_env_file(CENTRAL_ENV).get(name)


def get_keys(*names: str) -> Dict[str, Optional[str]]:
    """Get multiple API keys at once."""
    file_env = load_env_file(CENTRAL_ENV)
    return {name: os.environ.get(name) or file_env.get(name) for name in names}
