"""utils.py — utility functions used by main.py."""


def format_output(value: str, width: int = 40) -> str:
    """Return value padded to the given width with dashes."""
    return value.ljust(width, "-")


def truncate(value: str, max_len: int = 80) -> str:
    """Truncate a string to max_len characters, appending '...' if cut."""
    if len(value) <= max_len:
        return value
    return value[: max_len - 3] + "..."
