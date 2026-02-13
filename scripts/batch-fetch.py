#!/usr/bin/env python3
"""
Batch URL fetcher for cascade-proof multi-URL retrieval.

This script fetches multiple URLs in parallel within a single process,
ensuring that individual URL failures do not affect other fetches.
Outputs JSON with per-URL success/error status.

Usage:
    batch-fetch.py URL1 [URL2 URL3 ...]

@decision DEC-FETCH-001
@title Stdlib-only parallel fetch with independent failure isolation
@status accepted
@rationale WebFetch cascade failures block sibling tool calls. This script
uses ThreadPoolExecutor for parallel fetching in a single process, with
per-URL timeout and error handling. Each result is independent. Uses
stdlib only to avoid pip dependencies in global config.
"""

import sys
import json
import urllib.request
import urllib.error
from concurrent.futures import ThreadPoolExecutor, as_completed
from html.parser import HTMLParser
from io import StringIO

# Constants
TIMEOUT_SECONDS = 30
MAX_CONTENT_LENGTH = 50 * 1024  # 50KB per URL
USER_AGENT = "Mozilla/5.0 (compatible; ClaudeCode/1.0)"


class HTMLTextExtractor(HTMLParser):
    """Extract visible text from HTML, stripping tags."""

    def __init__(self):
        super().__init__()
        self.text = StringIO()
        self.skip_tags = {'script', 'style', 'head'}
        self.current_tag = None

    def handle_starttag(self, tag, attrs):
        self.current_tag = tag

    def handle_endtag(self, tag):
        if tag == self.current_tag:
            self.current_tag = None

    def handle_data(self, data):
        if self.current_tag not in self.skip_tags:
            self.text.write(data)

    def get_text(self):
        return self.text.getvalue()


def fetch_url(url: str) -> dict:
    """
    Fetch a single URL and return result dict.

    Args:
        url: URL to fetch

    Returns:
        Dict with keys: url, success, content, error
    """
    result = {
        "url": url,
        "success": False,
        "content": None,
        "error": None
    }

    try:
        req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
        with urllib.request.urlopen(req, timeout=TIMEOUT_SECONDS) as response:
            # Read response
            raw_data = response.read()

            # Detect encoding
            content_type = response.headers.get('Content-Type', '')
            charset = 'utf-8'
            if 'charset=' in content_type:
                charset = content_type.split('charset=')[-1].split(';')[0].strip()

            # Decode
            try:
                html = raw_data.decode(charset)
            except (UnicodeDecodeError, LookupError):
                html = raw_data.decode('utf-8', errors='ignore')

            # Strip HTML tags
            parser = HTMLTextExtractor()
            parser.feed(html)
            text = parser.get_text()

            # Clean whitespace
            lines = [line.strip() for line in text.splitlines() if line.strip()]
            content = '\n'.join(lines)

            # Truncate if needed
            if len(content) > MAX_CONTENT_LENGTH:
                content = content[:MAX_CONTENT_LENGTH] + "\n[... content truncated ...]"

            result["success"] = True
            result["content"] = content

    except urllib.error.HTTPError as e:
        result["error"] = f"HTTP {e.code}: {e.reason}"
    except urllib.error.URLError as e:
        result["error"] = f"URL error: {e.reason}"
    except TimeoutError:
        result["error"] = f"Timeout after {TIMEOUT_SECONDS}s"
    except Exception as e:
        result["error"] = f"Unexpected error: {type(e).__name__}: {str(e)}"

    return result


def main():
    """Main entry point."""
    if len(sys.argv) < 2:
        print(json.dumps({
            "error": "Usage: batch-fetch.py URL1 [URL2 URL3 ...]",
            "results": []
        }), file=sys.stdout)
        sys.exit(1)

    urls = sys.argv[1:]
    results = []

    # Fetch in parallel with ThreadPoolExecutor
    with ThreadPoolExecutor(max_workers=min(10, len(urls))) as executor:
        future_to_url = {executor.submit(fetch_url, url): url for url in urls}

        for future in as_completed(future_to_url):
            try:
                result = future.result()
                results.append(result)
            except Exception as e:
                # Should never happen due to error handling in fetch_url,
                # but catch just in case
                url = future_to_url[future]
                results.append({
                    "url": url,
                    "success": False,
                    "content": None,
                    "error": f"Executor error: {str(e)}"
                })

    # Sort results to match input order
    url_to_result = {r["url"]: r for r in results}
    ordered_results = [url_to_result[url] for url in urls]

    # Output JSON
    output = {"results": ordered_results}
    print(json.dumps(output, indent=2), file=sys.stdout)

    sys.exit(0)


if __name__ == "__main__":
    main()
