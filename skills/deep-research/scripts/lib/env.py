"""Environment and API key management for deep-research skill.

@decision All three API keys optional with graceful degradation — deep research
providers have different pricing and availability. Users may only have one or two
keys. The skill adapts its output based on which providers are available rather
than requiring all three.

Loads API keys from ~/.config/deep-research/.env and environment variables.
"""

import os
from pathlib import Path
from typing import Dict, List, Optional

CONFIG_DIR = Path.home() / ".config" / "deep-research"
CONFIG_FILE = CONFIG_DIR / ".env"


def load_env_file(path: Path) -> Dict[str, str]:
    """Load environment variables from a .env file."""
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


def get_config() -> Dict[str, Optional[str]]:
    """Load configuration from ~/.config/deep-research/.env and environment.

    Environment variables override file values.

    Returns:
        Dict with OPENAI_API_KEY, PERPLEXITY_API_KEY, GEMINI_API_KEY (each Optional[str]).
    """
    file_env = load_env_file(CONFIG_FILE)

    return {
        'OPENAI_API_KEY': os.environ.get('OPENAI_API_KEY') or file_env.get('OPENAI_API_KEY'),
        'PERPLEXITY_API_KEY': os.environ.get('PERPLEXITY_API_KEY') or file_env.get('PERPLEXITY_API_KEY'),
        'GEMINI_API_KEY': os.environ.get('GEMINI_API_KEY') or file_env.get('GEMINI_API_KEY'),
    }


def get_available_providers(config: Dict[str, Optional[str]]) -> List[str]:
    """Return list of providers that have API keys configured.

    Returns:
        List of provider names: 'openai', 'perplexity', 'gemini'
    """
    providers = []
    if config.get('OPENAI_API_KEY'):
        providers.append('openai')
    if config.get('PERPLEXITY_API_KEY'):
        providers.append('perplexity')
    if config.get('GEMINI_API_KEY'):
        providers.append('gemini')
    return providers


def config_exists() -> bool:
    """Check if configuration file exists."""
    return CONFIG_FILE.exists()
