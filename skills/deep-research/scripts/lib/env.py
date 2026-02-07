"""Environment and API key management for deep-research skill.

@decision All three API keys optional with graceful degradation — deep research
providers have different pricing and availability. Users may only have one or two
keys. The skill adapts its output based on which providers are available rather
than requiring all three.

Loads API keys from central ~/.claude/.env. Falls back to legacy
~/.config/deep-research/.env for backward compatibility.
"""

import sys
from pathlib import Path
from typing import Dict, List, Optional

# Add shared lib to path
_shared_lib = Path(__file__).resolve().parents[3] / "scripts" / "lib"
if str(_shared_lib) not in sys.path:
    sys.path.insert(0, str(_shared_lib))

from env import load_env_file, CENTRAL_ENV  # noqa: E402

LEGACY_CONFIG = Path.home() / ".config" / "deep-research" / ".env"

_KEY_NAMES = ('OPENAI_API_KEY', 'PERPLEXITY_API_KEY', 'GEMINI_API_KEY')


def get_config() -> Dict[str, Optional[str]]:
    """Load configuration from central .env, legacy .env, and environment.

    Priority: environment > ~/.claude/.env > ~/.config/deep-research/.env
    """
    import os

    legacy_env = load_env_file(LEGACY_CONFIG)
    central_env = load_env_file(CENTRAL_ENV)

    return {
        key: os.environ.get(key) or central_env.get(key) or legacy_env.get(key)
        for key in _KEY_NAMES
    }


def get_available_providers(config: Dict[str, Optional[str]]) -> List[str]:
    """Return list of providers that have API keys configured."""
    providers = []
    if config.get('OPENAI_API_KEY'):
        providers.append('openai')
    if config.get('PERPLEXITY_API_KEY'):
        providers.append('perplexity')
    if config.get('GEMINI_API_KEY'):
        providers.append('gemini')
    return providers


def config_exists() -> bool:
    """Check if any configuration file exists."""
    return CENTRAL_ENV.exists() or LEGACY_CONFIG.exists()
