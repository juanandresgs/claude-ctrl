"""Environment and API key management for deep-research skill.

@decision All three API keys optional with graceful degradation — deep research
providers have different pricing and availability. Users may only have one or two
keys. The skill adapts its output based on which providers are available rather
than requiring all three.

Loads API keys from central ~/.claude/.env.
"""

import sys
from pathlib import Path
from typing import Dict, List, Optional

# Add shared lib to path
_shared_lib = Path(__file__).resolve().parents[4] / "scripts" / "lib"
if str(_shared_lib) not in sys.path:
    sys.path.insert(0, str(_shared_lib))

from keychain import load_env_file, CENTRAL_ENV  # noqa: E402

_KEY_NAMES = ('OPENAI_API_KEY', 'PERPLEXITY_API_KEY', 'GEMINI_API_KEY')


def get_config() -> Dict[str, Optional[str]]:
    """Load configuration from ~/.claude/.env and environment.

    Priority: environment > ~/.claude/.env
    """
    import os

    central_env = load_env_file(CENTRAL_ENV)

    return {
        key: os.environ.get(key) or central_env.get(key)
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
    """Check if central configuration file exists."""
    return CENTRAL_ENV.exists()
