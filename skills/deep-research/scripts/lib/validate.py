"""Citation validation for deep-research results.

@decision Post-collection validation (runs after all providers return) rather than
inline validation. Four depth levels: 0=none, 1=liveness (HEAD request),
2=relevance (fetch + text match), 3=cross-reference (fetch + verify claim).
Uses urllib directly for raw HTTP (not http.py which parses JSON) — stdlib-only.

Bug fixes in this version:
- B1: Non-dict citations are now skipped with `continue` instead of raising TypeError
- B2: HEAD-only liveness falls back to GET on 405/501 via _validate_url_liveness_get
- B3: Depth 3 now extracts real claim context from report text instead of always
  using the missing `claim` field (which was always empty)

Features added:
- F1 (#78): _extract_claim_context / _extract_surrounding_sentences — extracts
  contextual sentences around a URL mention in the report text, giving depth 2/3
  something meaningful to validate even for bare-URL citations
- F2 (#79): _resolve_redirects — resolves Gemini grounding API redirect URLs to
  their final destination before validation, eliminating false negatives
"""

import re
import time
import urllib.request
import urllib.error
from typing import Any, Dict, List


def _fetch_raw_html(url: str, timeout: int = 15) -> tuple[str, int]:
    """Fetch raw HTML content from a URL.

    Args:
        url: URL to fetch
        timeout: Request timeout in seconds

    Returns:
        Tuple of (html_content, status_code)

    Raises:
        urllib.error.HTTPError: On HTTP errors
        urllib.error.URLError: On network errors
    """
    headers = {"User-Agent": "deep-research-validator/1.0"}
    req = urllib.request.Request(url, headers=headers, method="GET")

    with urllib.request.urlopen(req, timeout=timeout) as response:
        body = response.read().decode('utf-8', errors='ignore')
        return body, response.status


def _validate_url_liveness_get(url: str) -> Dict[str, Any]:
    """Check URL liveness via GET request (B2 fallback for HEAD 405/501).

    Some servers reject HEAD requests (405 Method Not Allowed or 501 Not
    Implemented). This helper does a minimal GET, reading only 1024 bytes to
    confirm the server is alive and responding.

    Args:
        url: URL to validate

    Returns:
        Dict with status and details
    """
    try:
        headers = {"User-Agent": "deep-research-validator/1.0"}
        req = urllib.request.Request(url, headers=headers, method="GET")

        with urllib.request.urlopen(req, timeout=10) as response:
            response.read(1024)  # Minimal read — just confirm server responds
            status_code = response.status
            if 200 <= status_code < 400:
                return {"status": "valid", "details": f"HTTP {status_code} (GET fallback)"}
            else:
                return {"status": "invalid", "details": f"HTTP {status_code} (GET fallback)"}

    except urllib.error.HTTPError as e:
        if 200 <= e.code < 400:
            return {"status": "valid", "details": f"HTTP {e.code} (GET fallback)"}
        else:
            return {"status": "invalid", "details": f"HTTP {e.code} (GET fallback)"}
    except urllib.error.URLError as e:
        return {"status": "unreachable", "details": f"URLError: {e.reason}"}
    except Exception as e:
        return {"status": "unreachable", "details": f"{type(e).__name__}: {e}"}


def _validate_url_liveness(url: str) -> Dict[str, Any]:
    """Check if a URL is reachable via HEAD request, falling back to GET on 405/501.

    Args:
        url: URL to validate

    Returns:
        Dict with status, details
    """
    try:
        headers = {"User-Agent": "deep-research-validator/1.0"}
        req = urllib.request.Request(url, headers=headers, method="HEAD")

        with urllib.request.urlopen(req, timeout=10) as response:
            status_code = response.status
            if 200 <= status_code < 400:
                return {"status": "valid", "details": f"HTTP {status_code}"}
            else:
                return {"status": "invalid", "details": f"HTTP {status_code}"}

    except urllib.error.HTTPError as e:
        # B2: Fall back to GET on "Method Not Allowed" or "Not Implemented"
        if e.code in (405, 501):
            return _validate_url_liveness_get(url)
        if 200 <= e.code < 400:
            return {"status": "valid", "details": f"HTTP {e.code}"}
        else:
            return {"status": "invalid", "details": f"HTTP {e.code}"}
    except urllib.error.URLError as e:
        return {"status": "unreachable", "details": f"URLError: {e.reason}"}
    except Exception as e:
        return {"status": "unreachable", "details": f"{type(e).__name__}: {e}"}


def _extract_surrounding_sentences(text: str, position: int) -> str:
    """Extract 1-2 sentences surrounding a character position in text.

    Finds sentence boundaries (`. `, `! `, `? `, `\\n\\n`) before and after
    the given position and returns up to 500 characters of context.

    Args:
        text: Full text to search within
        position: Character index to center the extraction on

    Returns:
        Extracted context string, max 500 chars
    """
    if not text:
        return ""

    # Clamp position to valid range
    position = max(0, min(position, len(text) - 1))

    # Sentence-ending patterns we look for when scanning backwards/forwards
    sentence_ends = [". ", "! ", "? ", "\n\n"]

    # Find start: scan backwards for a sentence boundary
    start = 0
    for i in range(position, -1, -1):
        for sep in sentence_ends:
            if text[i:i + len(sep)] == sep:
                start = i + len(sep)
                break
        else:
            continue
        break

    # Find end: scan forwards for 1-2 sentence boundaries
    end = len(text)
    boundaries_found = 0
    i = position
    while i < len(text):
        for sep in sentence_ends:
            if text[i:i + len(sep)] == sep:
                boundaries_found += 1
                if boundaries_found >= 2:
                    end = i + len(sep)
                    i = len(text)  # break outer loop
                    break
                i += len(sep) - 1  # advance past separator (outer loop adds 1)
                break
        i += 1

    result = text[start:end].strip()
    # Enforce 500-char cap
    if len(result) > 500:
        result = result[:500]
    return result


def _extract_claim_context(report: str, url: str, citation_index: int) -> str:
    """Extract claim context sentences for a URL from the research report.

    Tries strategies in order:
    1. Find URL in markdown link ``[text](url)`` -> extract surrounding sentences
    2. Find URL as bare text -> extract surrounding sentences
    3. Find footnote marker ``[N]`` where N = citation_index + 1 -> extract surrounding
    4. Return empty string (graceful fallback)

    Args:
        report: Full research report text (ProviderResult.report)
        url: Citation URL to locate in the report
        citation_index: 0-based index of this citation (used for [N] lookup)

    Returns:
        Context string (up to 500 chars) or empty string if not found
    """
    if not report or not url:
        return ""

    # Strategy 1: URL inside markdown link [text](url)
    # Match [anything](url) where url is the exact URL
    escaped_url = re.escape(url)
    md_pattern = r'\[[^\]]*\]\(' + escaped_url + r'\)'
    match = re.search(md_pattern, report)
    if match:
        return _extract_surrounding_sentences(report, match.start())

    # Strategy 2: URL as bare text
    pos = report.find(url)
    if pos != -1:
        return _extract_surrounding_sentences(report, pos)

    # Strategy 3: Footnote marker [N] where N = citation_index + 1
    footnote = f"[{citation_index + 1}]"
    pos = report.find(footnote)
    if pos != -1:
        return _extract_surrounding_sentences(report, pos)

    # Strategy 4: Graceful fallback
    return ""


def _resolve_redirects(url: str) -> str:
    """Resolve Gemini grounding API redirect URLs to their final destination.

    Only fires for URLs matching ``vertexaisearch.cloud.google.com/grounding-api-redirect``.
    All other URLs are returned unchanged without any HTTP request.

    Uses urllib HEAD (follows redirects), falls back to GET on 405/501.
    Returns original URL on any error -- no regression on failure.

    Args:
        url: URL to potentially resolve

    Returns:
        Final resolved URL, or original URL if not a grounding redirect or on error
    """
    # Only process Gemini grounding redirect URLs
    if "vertexaisearch.cloud.google.com/grounding-api-redirect" not in url:
        return url

    try:
        headers = {"User-Agent": "deep-research-validator/1.0"}
        req = urllib.request.Request(url, headers=headers, method="HEAD")

        with urllib.request.urlopen(req, timeout=10) as response:
            # After following redirects, response.url is the final URL
            final_url = response.url
            return final_url if final_url else url

    except urllib.error.HTTPError as e:
        # Fall back to GET on 405/501
        if e.code in (405, 501):
            try:
                req_get = urllib.request.Request(
                    url,
                    headers={"User-Agent": "deep-research-validator/1.0"},
                    method="GET",
                )
                with urllib.request.urlopen(req_get, timeout=10) as response:
                    final_url = response.url
                    return final_url if final_url else url
            except Exception:
                return url
        return url
    except Exception:
        # No regression on any error
        return url


def _validate_url_relevance(url: str, citation_title: str = "") -> Dict[str, Any]:
    """Check if a URL is reachable and contains relevant content.

    Args:
        url: URL to validate
        citation_title: Expected title or keywords to find

    Returns:
        Dict with status, details
    """
    try:
        html, status_code = _fetch_raw_html(url, timeout=15)

        if not (200 <= status_code < 400):
            return {"status": "invalid", "details": f"HTTP {status_code}"}

        # Level 2: Check if citation title appears in the page
        if citation_title:
            # Case-insensitive search
            html_lower = html.lower()
            title_lower = citation_title.lower()

            # Try exact phrase match first
            if title_lower in html_lower:
                return {"status": "valid", "details": "Citation title found in page"}

            # Try keyword match (at least 50% of words in title)
            title_words = [w for w in re.findall(r'\w+', title_lower) if len(w) > 3]
            if title_words:
                matches = sum(1 for word in title_words if word in html_lower)
                if matches / len(title_words) >= 0.5:
                    return {"status": "valid", "details": f"Keywords found ({matches}/{len(title_words)})"}

            return {"status": "invalid", "details": "Citation title not found in page"}
        else:
            # No title to verify, just check liveness
            return {"status": "valid", "details": "Page reachable (no title to verify)"}

    except urllib.error.HTTPError as e:
        return {"status": "invalid", "details": f"HTTP {e.code}"}
    except urllib.error.URLError as e:
        return {"status": "unreachable", "details": f"URLError: {e.reason}"}
    except Exception as e:
        return {"status": "unreachable", "details": f"{type(e).__name__}: {e}"}


def _validate_url_cross_reference(url: str, claim: str = "", citation_title: str = "") -> Dict[str, Any]:
    """Check if a URL supports a specific claim.

    Args:
        url: URL to validate
        claim: The specific claim to verify
        citation_title: Citation title or keywords

    Returns:
        Dict with status, details
    """
    try:
        html, status_code = _fetch_raw_html(url, timeout=15)

        if not (200 <= status_code < 400):
            return {"status": "invalid", "details": f"HTTP {status_code}"}

        html_lower = html.lower()

        # Level 3: Check if claim keywords appear in the page
        if claim:
            # Extract keywords from claim (words longer than 3 chars)
            claim_words = [w for w in re.findall(r'\w+', claim.lower()) if len(w) > 3]
            if claim_words:
                matches = sum(1 for word in claim_words if word in html_lower)
                if matches / len(claim_words) >= 0.6:  # 60% keyword match for claims
                    return {"status": "valid", "details": f"Claim keywords found ({matches}/{len(claim_words)})"}
                else:
                    return {"status": "invalid", "details": f"Insufficient claim support ({matches}/{len(claim_words)})"}

        # Fall back to title relevance
        if citation_title:
            title_lower = citation_title.lower()
            if title_lower in html_lower:
                return {"status": "valid", "details": "Citation title found in page"}

            title_words = [w for w in re.findall(r'\w+', title_lower) if len(w) > 3]
            if title_words:
                matches = sum(1 for word in title_words if word in html_lower)
                if matches / len(title_words) >= 0.5:
                    return {"status": "valid", "details": f"Title keywords found ({matches}/{len(title_words)})"}

            return {"status": "invalid", "details": "Citation not verified in page"}
        else:
            # No claim or title, just liveness
            return {"status": "valid", "details": "Page reachable (no claim to verify)"}

    except urllib.error.HTTPError as e:
        return {"status": "invalid", "details": f"HTTP {e.code}"}
    except urllib.error.URLError as e:
        return {"status": "unreachable", "details": f"URLError: {e.reason}"}
    except Exception as e:
        return {"status": "unreachable", "details": f"{type(e).__name__}: {e}"}


def validate_citations(results: List[Any], depth: int = 0) -> List[Any]:
    """Validate citations in provider results.

    Args:
        results: List of ProviderResult objects (as dicts or dataclasses)
        depth: Validation depth (0=none, 1=liveness, 2=relevance, 3=cross-ref)

    Returns:
        Modified results with validation data added to citations
    """
    if depth == 0:
        return results

    for result in results:
        # Get direct reference to citations list
        if hasattr(result, "citations"):
            citations = result.citations
        elif isinstance(result, dict):
            citations = result.get("citations", [])
        else:
            continue

        if not citations:
            continue

        # Extract report text for context (F1, B3)
        if hasattr(result, "report"):
            report_text = result.report or ""
        elif isinstance(result, dict):
            report_text = result.get("report", "")
        else:
            report_text = ""

        for citation_index, citation in enumerate(citations):
            # B1: Skip non-dict citations gracefully (was causing TypeError)
            if not isinstance(citation, dict):
                continue

            url = citation.get("url", "")
            if not url:
                citation["validation"] = {
                    "status": "skipped",
                    "depth": depth,
                    "details": "No URL",
                }
                continue

            # F2: Resolve Gemini grounding redirects before validation
            resolved_url = _resolve_redirects(url)
            if resolved_url != url:
                citation["resolved_url"] = resolved_url
            validation_url = resolved_url  # Validate against final destination

            # Validate based on depth
            if depth == 1:
                validation = _validate_url_liveness(validation_url)
            elif depth == 2:
                title = citation.get("title", "")
                # F1: Fall back to extracted context when no title
                if not title:
                    title = _extract_claim_context(report_text, url, citation_index)
                validation = _validate_url_relevance(validation_url, title)
            elif depth == 3:
                title = citation.get("title", "")
                # B3 + F1: Always extract claim context from report (claim field is never set by providers)
                claim = _extract_claim_context(report_text, url, citation_index)
                validation = _validate_url_cross_reference(validation_url, claim, title)
            else:
                validation = {"status": "skipped", "details": "Invalid depth"}

            # Add validation data to citation
            citation["validation"] = {
                "status": validation["status"],
                "depth": depth,
                "details": validation.get("details", ""),
            }

            # Rate limit: small delay between requests to avoid hammering servers
            time.sleep(0.2)

    return results
