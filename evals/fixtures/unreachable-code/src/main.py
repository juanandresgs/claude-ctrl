"""main.py — application entry point.

Imports and uses src/utils.py. Does NOT import src/orphan.py.
"""

from src.utils import format_output, truncate


def run(message: str) -> str:
    """Format and truncate the given message for display."""
    formatted = format_output(message)
    return truncate(formatted)


if __name__ == "__main__":
    print(run("Hello from main"))
