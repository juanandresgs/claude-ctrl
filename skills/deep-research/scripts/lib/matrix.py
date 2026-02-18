"""
matrix.py — Deterministic comparison matrix builder for deep-research skill.

Purpose: Programmatically extract topics from provider reports, build a
coverage matrix, compute citation overlap, and produce a structured
ComparisonMatrix that can be serialized to JSON alongside raw_results.json.

Architecture:
- All stdlib-only Python — no external dependencies.
- Topic extraction via markdown heading regex (H1–H4). Flat reports get one
  synthetic "no headings" topic.
- Cross-provider matching: two passes.
  Pass 1: exact (normalized text equal), then heading-fuzzy (Jaccard ≥ 0.60
  on heading word sets).
  Pass 2: content-fuzzy — Jaccard ≥ 0.30 on body keyword sets (stop-word
  filtered) for topics unmatched after Pass 1.
- Agreement levels: 'consensus' (all providers), 'majority' (2+), 'unique-<p>'
  (one provider). Computed against active providers (successful results only).
- Citation overlap: deterministic URL set intersection across providers.
- ComparisonMatrix.to_dict() produces the JSON structure written to
  comparison_matrix.json and embedded in raw_results.json. Includes
  match_method per topic and unmatched_hints at top level.

@decision DEC-MATRIX-001
@title Jaccard similarity threshold at 0.60 for fuzzy heading match (Pass 1)
@status accepted
@rationale 0.60 captures genuinely related headings (e.g. "APT Group
Connections" / "APT Group Links") while excluding accidental overlaps
(e.g. "Company Overview" / "Company Background" which share only "company").
Lower thresholds produce false merges; higher thresholds miss real matches.

@decision DEC-MATRIX-002
@title Content-based Pass 2 with Jaccard threshold 0.30 on body keywords
@status accepted
@rationale Pass 1 relies on heading text similarity, which fails when providers
use different terminology for the same subject (e.g. "Company Overview" vs
"Company Background"). Pass 2 uses keyword overlap of section body text
(stop-word filtered) to catch these structural mismatches. 0.30 is low enough
to catch topically related sections while high enough to exclude coincidental
keyword sharing in short sections. Stop-word filtering removes noise from
common English function words that inflate overlap spuriously.
"""

import re
from dataclasses import dataclass, field, asdict
from typing import Any, Dict, List, Optional, Set, Tuple

# Word count threshold separating 'detailed' from 'mentioned' coverage.
DETAILED_WORD_THRESHOLD = 100

# Minimum Jaccard similarity for fuzzy heading match (Pass 1).
FUZZY_MATCH_THRESHOLD = 0.60

# Minimum Jaccard similarity for content-based match (Pass 2).
CONTENT_MATCH_THRESHOLD = 0.30

# English stop words excluded from body keyword extraction.
STOP_WORDS = frozenset({
    "the", "a", "an", "is", "are", "was", "were", "be", "been", "being",
    "have", "has", "had", "do", "does", "did", "will", "would", "shall",
    "should", "may", "might", "can", "could", "must", "to", "of", "in",
    "for", "on", "with", "at", "by", "from", "as", "into", "through",
    "during", "before", "after", "above", "below", "between", "but", "and",
    "or", "nor", "not", "no", "so", "if", "then", "than", "that", "this",
    "these", "those", "it", "its", "they", "them", "their", "he", "she",
    "we", "you", "who", "which", "what", "when", "where", "how", "also",
    "very", "more", "most", "other", "some", "such", "only", "same",
    "just", "about", "each", "all", "both", "few", "many", "much", "any",
    "own",
})


# ---------------------------------------------------------------------------
# Data classes
# ---------------------------------------------------------------------------

@dataclass
class Topic:
    """A single section extracted from a provider report.

    Fields:
        heading: Normalized heading text (lowercase, stripped of numbering/punctuation).
        raw_heading: Original heading text as it appears in the report.
        level: Heading depth (1–4).
        word_count: Number of words in the section body.
        coverage: 'detailed' (≥100 words) or 'mentioned' (<100 words).
        citations_in_section: Number of URLs found in the section body.
        body_keywords: Significant keywords from section body (stop-word filtered).
    """
    heading: str
    raw_heading: str
    level: int
    word_count: int
    coverage: str  # 'detailed' | 'mentioned'
    citations_in_section: int
    body_keywords: Set[str] = field(default_factory=set)


@dataclass
class MatchedTopic:
    """A topic cluster matched across providers.

    Fields:
        canonical_name: Best representative normalized heading.
        coverage: {provider: 'detailed'|'mentioned'|'absent'}.
        agreement_level: 'consensus', 'majority', or 'unique-<provider>'.
        match_method: How this cluster was formed.
            'exact'         — heading strings were identical after normalization.
            'heading-fuzzy' — heading Jaccard >= 0.60.
            'content-fuzzy' — body keyword Jaccard >= 0.30 (Pass 2 only).
            'unmatched'     — topic found in only one provider; no match found.
    """
    canonical_name: str
    coverage: Dict[str, str]  # {provider: 'detailed'|'mentioned'|'absent'}
    agreement_level: str
    match_method: str = "unmatched"  # 'exact' | 'heading-fuzzy' | 'content-fuzzy' | 'unmatched'


@dataclass
class ComparisonMatrix:
    """Full cross-provider comparison matrix.

    Fields:
        topics: List of matched topic clusters.
        providers: List of active provider names (successful results only).
        citation_overlap: {url: [providers]} — only URLs cited by 2+ providers.
        stats: Aggregate counts (total_topics, consensus, majority, unique).
        unmatched_hints: Topics that stayed unmatched after both passes.
            Each entry: {"provider": str, "heading": str, "top_keywords": [str]}.
            Used by the LLM synthesis step to identify potential manual merges.
    """
    topics: List[MatchedTopic]
    providers: List[str]
    citation_overlap: Dict[str, List[str]]
    stats: Dict[str, Any]
    unmatched_hints: List[Dict] = field(default_factory=list)

    def to_dict(self) -> Dict[str, Any]:
        """Serialize to a JSON-friendly dict matching the output schema.

        Output structure:
            {
              "providers": [...],
              "topics": [
                {"name": "...", "openai": "detailed", ..., "agreement": "consensus",
                 "match_method": "exact"},
                ...
              ],
              "citation_overlap": {"url": ["openai", "gemini"], ...},
              "stats": {"total_topics": N, "consensus": N, ...},
              "unmatched_hints": [
                {"provider": "openai", "heading": "...", "top_keywords": [...]},
                ...
              ]
            }
        """
        topics_out = []
        for t in self.topics:
            entry: Dict[str, Any] = {"name": t.canonical_name}
            for provider in self.providers:
                entry[provider] = t.coverage.get(provider, "absent")
            entry["agreement"] = t.agreement_level
            entry["match_method"] = t.match_method
            topics_out.append(entry)

        return {
            "providers": self.providers,
            "topics": topics_out,
            "citation_overlap": self.citation_overlap,
            "stats": self.stats,
            "unmatched_hints": self.unmatched_hints,
        }


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

def _extract_body_keywords(text: str) -> Set[str]:
    """Extract significant keywords from section body text.

    Lowercases, splits on whitespace, strips punctuation, removes stop words
    and single-character tokens. Used for Pass 2 content-based matching.

    Args:
        text: Raw section body text (markdown).

    Returns:
        Set of cleaned keyword strings.
    """
    words: Set[str] = set()
    for word in text.lower().split():
        cleaned = re.sub(r'[^a-z0-9]', '', word)
        if cleaned and len(cleaned) > 1 and cleaned not in STOP_WORDS:
            words.add(cleaned)
    return words


def _jaccard_similarity_sets(a: Set[str], b: Set[str]) -> float:
    """Jaccard similarity between two pre-computed keyword sets.

    Args:
        a: First keyword set.
        b: Second keyword set.

    Returns:
        Float in [0.0, 1.0]. Two empty sets → 1.0. One empty → 0.0.
    """
    if not a and not b:
        return 1.0
    if not a or not b:
        return 0.0
    return len(a & b) / len(a | b)


def _normalize_heading(text: str) -> str:
    """Normalize a heading for comparison.

    Steps:
    1. Strip leading/trailing whitespace.
    2. Strip leading list/dash prefix (e.g. "- ").
    3. Strip leading numbering prefix (e.g. "1. ", "a. ").
    4. Strip trailing punctuation (colon, period, etc.).
    5. Lowercase.
    6. Collapse internal whitespace.

    Examples:
        "1. Key Findings"       → "key findings"
        "a. Background:"        → "background"
        "- Introduction"        → "introduction"
        "  Company Overview  "  → "company overview"
    """
    s = text.strip()
    # Strip leading dash or bullet
    s = re.sub(r"^[-*•]\s+", "", s)
    # Strip leading numbering: "1. ", "2) ", "a. ", "A. "
    s = re.sub(r"^[0-9A-Za-z]+[.)]\s+", "", s)
    # Strip trailing punctuation
    s = s.rstrip(":.,;!?")
    # Lowercase and collapse whitespace
    s = re.sub(r"\s+", " ", s).strip().lower()
    return s


def _count_urls(text: str) -> int:
    """Count the number of http/https URLs in a block of text."""
    return len(re.findall(r"https?://\S+", text))


def _jaccard_similarity(a: str, b: str) -> float:
    """Jaccard similarity between the word sets of two strings.

    Empty strings are treated as empty sets. Two empty strings → 1.0.
    One empty string → 0.0.
    """
    words_a: Set[str] = set(a.lower().split()) if a.strip() else set()
    words_b: Set[str] = set(b.lower().split()) if b.strip() else set()

    if not words_a and not words_b:
        return 1.0
    if not words_a or not words_b:
        return 0.0

    intersection = words_a & words_b
    union = words_a | words_b
    return len(intersection) / len(union)


# ---------------------------------------------------------------------------
# Topic extraction
# ---------------------------------------------------------------------------

# Matches H1–H4 markdown headings at line start.
_HEADING_RE = re.compile(r"^(#{1,4})\s+(.+)$", re.MULTILINE)


def extract_topics(report: str) -> List[Topic]:
    """Extract topics from a markdown report.

    Parses H1–H4 headings and computes per-section metrics.
    Returns an empty list for empty/whitespace-only input.
    Returns a single synthetic topic for flat text (no headings).

    Args:
        report: Raw markdown report text.

    Returns:
        List of Topic instances, one per heading section.
    """
    if not report or not report.strip():
        return []

    matches = list(_HEADING_RE.finditer(report))

    if not matches:
        # Flat text — treat entire report as one implicit topic.
        word_count = len(report.split())
        coverage = "detailed" if word_count >= DETAILED_WORD_THRESHOLD else "mentioned"
        return [
            Topic(
                heading="(no headings)",
                raw_heading="(no headings)",
                level=1,
                word_count=word_count,
                coverage=coverage,
                citations_in_section=_count_urls(report),
                body_keywords=_extract_body_keywords(report),
            )
        ]

    topics: List[Topic] = []

    for i, match in enumerate(matches):
        level = len(match.group(1))
        raw_heading = match.group(2).strip()
        heading = _normalize_heading(raw_heading)

        # Section body: text between this heading and the next heading (or EOF).
        body_start = match.end()
        body_end = matches[i + 1].start() if i + 1 < len(matches) else len(report)
        body = report[body_start:body_end]

        word_count = len(body.split())
        coverage = "detailed" if word_count >= DETAILED_WORD_THRESHOLD else "mentioned"
        citation_count = _count_urls(body)

        topics.append(Topic(
            heading=heading,
            raw_heading=raw_heading,
            level=level,
            word_count=word_count,
            coverage=coverage,
            citations_in_section=citation_count,
            body_keywords=_extract_body_keywords(body),
        ))

    return topics


# ---------------------------------------------------------------------------
# Cross-provider matching
# ---------------------------------------------------------------------------

def _best_match(
    needle: Topic,
    candidates: List[Topic],
    used: Set[int],
) -> Optional[Tuple[int, float]]:
    """Find the best heading-based match for `needle` among unused candidates.

    Returns (index, score) of the best match with score >= FUZZY_MATCH_THRESHOLD,
    or None if no suitable match exists.

    Score 1.0 indicates an exact match; scores below 1.0 are heading-fuzzy.
    """
    best_idx: Optional[int] = None
    best_score = FUZZY_MATCH_THRESHOLD - 1e-9  # just below threshold

    for idx, candidate in enumerate(candidates):
        if idx in used:
            continue
        # Try exact match first.
        if needle.heading == candidate.heading:
            return (idx, 1.0)
        score = _jaccard_similarity(needle.heading, candidate.heading)
        if score > best_score:
            best_score = score
            best_idx = idx

    if best_idx is not None and best_score >= FUZZY_MATCH_THRESHOLD:
        return (best_idx, best_score)
    return None


def _best_content_match(
    needle: Topic,
    candidates: List[Topic],
) -> Optional[Tuple[int, float]]:
    """Find the best content-based match for `needle` among candidates.

    Uses body_keywords Jaccard similarity with CONTENT_MATCH_THRESHOLD.
    Used by Pass 2 cluster-level merging (not topic-level).

    Returns (index, score) or None if no match meets the threshold.
    """
    best_idx: Optional[int] = None
    best_score = CONTENT_MATCH_THRESHOLD - 1e-9  # just below threshold

    for idx, candidate in enumerate(candidates):
        score = _jaccard_similarity_sets(needle.body_keywords, candidate.body_keywords)
        if score > best_score:
            best_score = score
            best_idx = idx

    if best_idx is not None and best_score >= CONTENT_MATCH_THRESHOLD:
        return (best_idx, best_score)
    return None


def match_topics(
    provider_topics: Dict[str, List[Topic]],
) -> List[MatchedTopic]:
    """Cluster topics across providers into MatchedTopic instances.

    Algorithm — two passes:

    Pass 1 (heading-based):
    1. For each provider in insertion order, iterate its topics.
    2. For each topic, attempt an exact then heading-fuzzy match against every
       other provider's topic list (only unmatched topics considered).
    3. All matched topics form one cluster. match_method is 'exact' for
       score==1.0, 'heading-fuzzy' for scores below 1.0.

    Pass 2 (content-based):
    4. Topics not matched in Pass 1 are iterated again.
    5. For each unmatched anchor, attempt content keyword Jaccard match
       (threshold 0.30) against other providers' still-unmatched topics.
    6. Matched clusters get match_method='content-fuzzy'.

    Remaining topics with no match in either pass get match_method='unmatched'.

    7. Providers whose topic lists have no match for a cluster get 'absent'.
    8. agreement_level is derived from how many active providers cover the topic.

    Args:
        provider_topics: {provider_name: [Topic, ...]}

    Returns:
        List of MatchedTopic clusters.
    """
    providers = list(provider_topics.keys())
    if not providers:
        return []

    # Track which topics in each provider have been assigned to a cluster.
    used: Dict[str, Set[int]] = {p: set() for p in providers}

    # Each cluster: maps provider → Topic (or None), plus the match_method.
    # Format: {"topics": {provider: Topic|None}, "match_method": str}
    clusters: List[Dict] = []

    # -----------------------------------------------------------------------
    # Pass 1: heading-based matching (exact + fuzzy)
    # -----------------------------------------------------------------------
    for anchor_provider in providers:
        for anchor_idx, anchor_topic in enumerate(provider_topics[anchor_provider]):
            if anchor_idx in used[anchor_provider]:
                continue

            cluster_topics: Dict[str, Optional[Topic]] = {p: None for p in providers}
            cluster_topics[anchor_provider] = anchor_topic
            used[anchor_provider].add(anchor_idx)

            # Provisional method for this cluster — upgraded as matches are found.
            cluster_match_method = "unmatched"

            for other_provider in providers:
                if other_provider == anchor_provider:
                    continue
                other_topics = provider_topics[other_provider]
                result = _best_match(anchor_topic, other_topics, used[other_provider])
                if result is not None:
                    match_idx, score = result
                    cluster_topics[other_provider] = other_topics[match_idx]
                    used[other_provider].add(match_idx)
                    # Upgrade: exact > heading-fuzzy > unmatched
                    if score == 1.0:
                        if cluster_match_method == "unmatched":
                            cluster_match_method = "exact"
                    else:
                        if cluster_match_method == "unmatched":
                            cluster_match_method = "heading-fuzzy"

            clusters.append({
                "topics": cluster_topics,
                "match_method": cluster_match_method,
            })

    # -----------------------------------------------------------------------
    # Pass 2: content-based cluster merging for still-unmatched clusters.
    #
    # After Pass 1, every topic has been assigned to exactly one cluster as
    # anchor (all indices are in `used`). Pass 2 therefore operates at the
    # cluster level: it compares two "unmatched" clusters that each belong to
    # different single providers, and merges them if their representative
    # topic's body_keywords Jaccard meets CONTENT_MATCH_THRESHOLD.
    #
    # Merged clusters are marked with a sentinel so they can be skipped when
    # building the final MatchedTopic list.
    # -----------------------------------------------------------------------

    # Build an index of active (non-merged) unmatched clusters for fast lookup.
    # We'll iterate and mark merged clusters with "merged_into" key.
    for i, cluster_a in enumerate(clusters):
        if cluster_a["match_method"] != "unmatched":
            continue
        if "merged_into" in cluster_a:
            continue

        cluster_topics_a = cluster_a["topics"]
        anchor_a = next(p for p, t in cluster_topics_a.items() if t is not None)
        topic_a = cluster_topics_a[anchor_a]

        # Skip clusters whose anchor has no body keywords — no content basis.
        if not topic_a.body_keywords:
            continue

        best_j: Optional[int] = None
        best_sim = CONTENT_MATCH_THRESHOLD - 1e-9

        for j, cluster_b in enumerate(clusters):
            if j <= i:
                continue  # avoid double-checking pairs
            if cluster_b["match_method"] != "unmatched":
                continue
            if "merged_into" in cluster_b:
                continue

            cluster_topics_b = cluster_b["topics"]
            anchor_b = next(p for p, t in cluster_topics_b.items() if t is not None)
            if anchor_b == anchor_a:
                continue  # both from same provider — skip

            topic_b = cluster_topics_b[anchor_b]
            # Skip if candidate has no body keywords.
            if not topic_b.body_keywords:
                continue
            sim = _jaccard_similarity_sets(topic_a.body_keywords, topic_b.body_keywords)
            if sim > best_sim:
                best_sim = sim
                best_j = j

        if best_j is not None:
            # Merge cluster_b into cluster_a.
            cluster_b = clusters[best_j]
            cluster_topics_b = cluster_b["topics"]
            for p, t in cluster_topics_b.items():
                if t is not None and cluster_topics_a.get(p) is None:
                    cluster_topics_a[p] = t
            cluster_a["match_method"] = "content-fuzzy"
            cluster_b["merged_into"] = i  # mark as absorbed

    # -----------------------------------------------------------------------
    # Convert clusters to MatchedTopic instances.
    # Clusters absorbed by Pass 2 merging are skipped (they have "merged_into").
    # -----------------------------------------------------------------------
    active_provider_count = len(providers)
    matched: List[MatchedTopic] = []

    for cluster in clusters:
        if "merged_into" in cluster:
            continue  # this cluster was absorbed into another during Pass 2
        cluster_topics = cluster["topics"]
        match_method = cluster["match_method"]

        present_topics = [(p, t) for p, t in cluster_topics.items() if t is not None]
        canonical = max(
            (t.heading for _, t in present_topics),
            key=len,
        )

        coverage: Dict[str, str] = {}
        for p in providers:
            t = cluster_topics.get(p)
            if t is not None:
                coverage[p] = t.coverage
            else:
                coverage[p] = "absent"

        present_count = sum(1 for v in coverage.values() if v != "absent")

        if active_provider_count == 1:
            agreement = f"unique-{providers[0]}"
        elif present_count == active_provider_count:
            agreement = "consensus"
        elif present_count >= 2:
            agreement = "majority"
        else:
            only_provider = next(
                p for p, v in coverage.items() if v != "absent"
            )
            agreement = f"unique-{only_provider}"

        matched.append(MatchedTopic(
            canonical_name=canonical,
            coverage=coverage,
            agreement_level=agreement,
            match_method=match_method,
        ))

    return matched


# ---------------------------------------------------------------------------
# Citation overlap
# ---------------------------------------------------------------------------

def _extract_urls(citations: List[Any]) -> Set[str]:
    """Extract normalized URL strings from a citations list.

    Handles both dict citations ({"url": "..."}) and bare URL strings.
    """
    urls: Set[str] = set()
    for citation in citations:
        if isinstance(citation, dict):
            url = citation.get("url", "")
            if url:
                urls.add(url.strip())
        elif isinstance(citation, str):
            url = citation.strip()
            if url:
                urls.add(url)
    return urls


def _compute_citation_overlap(
    results: list,  # List[ProviderResult]
) -> Dict[str, List[str]]:
    """Return a dict of {url: [providers]} for URLs cited by 2+ providers.

    Only URLs appearing in 2 or more provider citation lists are included.

    Args:
        results: List of ProviderResult (successful only).

    Returns:
        Dict mapping URL → sorted list of provider names.
    """
    # Build {url: set of providers}
    url_providers: Dict[str, Set[str]] = {}

    for r in results:
        provider_urls = _extract_urls(r.citations)
        for url in provider_urls:
            if url not in url_providers:
                url_providers[url] = set()
            url_providers[url].add(r.provider)

    # Filter to only multi-provider URLs, sort provider lists for determinism.
    overlap: Dict[str, List[str]] = {}
    for url, providers in sorted(url_providers.items()):
        if len(providers) >= 2:
            overlap[url] = sorted(providers)

    return overlap


# ---------------------------------------------------------------------------
# Matrix builder
# ---------------------------------------------------------------------------

def build_matrix(results: list) -> ComparisonMatrix:
    """Build a ComparisonMatrix from a list of ProviderResult instances.

    Only successful providers (result.success == True) contribute to the matrix.
    Failed providers are excluded from the providers list and treated as absent
    for all topics.

    Args:
        results: List[ProviderResult] — output from deep_research.py.

    Returns:
        ComparisonMatrix ready for serialization.
    """
    # Filter to successful providers only.
    successful = [r for r in results if r.success]

    if not successful:
        return ComparisonMatrix(
            topics=[],
            providers=[],
            citation_overlap={},
            stats={"total_topics": 0, "consensus": 0, "majority": 0, "unique": 0},
            unmatched_hints=[],
        )

    providers = [r.provider for r in successful]

    # Extract topics per provider.
    provider_topics: Dict[str, List[Topic]] = {}
    for r in successful:
        provider_topics[r.provider] = extract_topics(r.report)

    # Match topics across providers (two-pass).
    matched = match_topics(provider_topics)

    # Compute citation overlap.
    citation_overlap = _compute_citation_overlap(successful)

    # Compute stats.
    consensus_count = sum(1 for t in matched if t.agreement_level == "consensus")
    majority_count = sum(1 for t in matched if t.agreement_level == "majority")
    unique_count = sum(1 for t in matched if t.agreement_level.startswith("unique-"))

    stats: Dict[str, Any] = {
        "total_topics": len(matched),
        "consensus": consensus_count,
        "majority": majority_count,
        "unique": unique_count,
    }

    # Build unmatched_hints: topics that remained unmatched after both passes.
    # Each hint gives the LLM the provider, heading, and top keywords so it
    # can decide whether to manually merge topics with different headings.
    # Build a lookup from heading to Topic for each provider.
    heading_to_topic: Dict[str, Dict[str, Topic]] = {}
    for p, topics_list in provider_topics.items():
        for topic in topics_list:
            if topic.heading not in heading_to_topic:
                heading_to_topic[topic.heading] = {}
            heading_to_topic[topic.heading][p] = topic

    unmatched_hints: List[Dict] = []
    for t in matched:
        if t.match_method != "unmatched":
            continue
        owning_provider = next(
            (p for p, cov in t.coverage.items() if cov != "absent"),
            None,
        )
        if owning_provider is None:
            continue
        # Retrieve the Topic object to get body_keywords.
        topic_obj: Optional[Topic] = next(
            (
                topic
                for topic in provider_topics.get(owning_provider, [])
                if topic.heading == t.canonical_name
            ),
            None,
        )
        keywords: List[str] = []
        if topic_obj is not None and topic_obj.body_keywords:
            keywords = sorted(topic_obj.body_keywords)[:20]

        unmatched_hints.append({
            "provider": owning_provider,
            "heading": t.canonical_name,
            "top_keywords": keywords,
        })

    return ComparisonMatrix(
        topics=matched,
        providers=providers,
        citation_overlap=citation_overlap,
        stats=stats,
        unmatched_hints=unmatched_hints,
    )
