"""fetcher.py — HTTP fetcher that calls an external API.

Fetches JSON data from a URL with a configurable timeout and returns the
parsed response body. Raises on HTTP errors or timeouts.
"""

import json
import urllib.error
import urllib.request


def fetch(url: str, timeout: int = 10) -> dict:
    """Fetch JSON from the given URL and return the parsed body.

    Args:
        url:     The URL to fetch.
        timeout: Request timeout in seconds (default 10).

    Returns:
        Parsed JSON response as a dict.

    Raises:
        urllib.error.URLError: On network errors or timeouts.
        ValueError: If the response body is not valid JSON.
    """
    with urllib.request.urlopen(url, timeout=timeout) as response:
        body = response.read().decode("utf-8")
    return json.loads(body)
