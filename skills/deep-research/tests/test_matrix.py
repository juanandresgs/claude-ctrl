#!/usr/bin/env python3
"""test_matrix.py — Tests for the deterministic comparison matrix module.

@decision Real unit tests, no mocks. Tests construct actual Topic, MatchedTopic,
and ProviderResult instances and call module functions directly. Fixture data
loaded from disk for integration tests — no HTTP, no API calls.

Strategy:
1. Topic extraction from markdown — headings, word counts, coverage levels
2. Cross-provider topic matching — exact and fuzzy
3. Agreement classification — consensus/majority/unique
4. Citation overlap detection — same URL across providers
5. Edge cases — empty reports, single provider, flat text
6. build_matrix integration — end-to-end with fixture JSONs
"""

import json
import sys
import unittest
from pathlib import Path
from typing import Set

# Add scripts dir to path so lib is importable
SCRIPTS_DIR = Path(__file__).parent.parent / "scripts"
sys.path.insert(0, str(SCRIPTS_DIR))

from lib.matrix import (
    Topic,
    MatchedTopic,
    ComparisonMatrix,
    extract_topics,
    match_topics,
    build_matrix,
    _normalize_heading,
    _jaccard_similarity,
    _extract_body_keywords,
    _jaccard_similarity_sets,
    STOP_WORDS,
)
from lib.render import ProviderResult

FIXTURES_DIR = Path(__file__).parent.parent / "fixtures"


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _load_fixture(name: str) -> dict:
    with open(FIXTURES_DIR / name) as f:
        return json.load(f)


def _provider_result(provider: str, report: str, citations=None) -> ProviderResult:
    return ProviderResult(
        provider=provider,
        success=True,
        report=report,
        citations=citations or [],
        model=f"mock-{provider}",
        elapsed_seconds=1.0,
    )


# ---------------------------------------------------------------------------
# _normalize_heading
# ---------------------------------------------------------------------------

class TestNormalizeHeading(unittest.TestCase):
    """Unit tests for internal heading normalizer."""

    def test_lowercases(self):
        self.assertEqual(_normalize_heading("Company Overview"), "company overview")

    def test_strips_numbering_prefix_digit(self):
        # "1. Key Findings" → "key findings"
        result = _normalize_heading("1. Key Findings")
        self.assertEqual(result, "key findings")

    def test_strips_numbering_prefix_letter(self):
        result = _normalize_heading("a. Background")
        self.assertEqual(result, "background")

    def test_strips_trailing_punctuation(self):
        result = _normalize_heading("Impact and Aftermath:")
        self.assertEqual(result, "impact and aftermath")

    def test_strips_leading_dash(self):
        result = _normalize_heading("- Introduction")
        self.assertEqual(result, "introduction")

    def test_no_change_simple(self):
        result = _normalize_heading("quantum error correction")
        self.assertEqual(result, "quantum error correction")

    def test_strips_extra_whitespace(self):
        result = _normalize_heading("  Section One  ")
        self.assertEqual(result, "section one")


# ---------------------------------------------------------------------------
# _jaccard_similarity
# ---------------------------------------------------------------------------

class TestJaccardSimilarity(unittest.TestCase):
    """Unit tests for Jaccard word-set similarity."""

    def test_identical(self):
        self.assertAlmostEqual(_jaccard_similarity("a b c", "a b c"), 1.0)

    def test_disjoint(self):
        self.assertAlmostEqual(_jaccard_similarity("a b c", "x y z"), 0.0)

    def test_partial_overlap(self):
        # {"a","b","c"} ∩ {"b","c","d"} = 2, union = 4 → 0.5
        self.assertAlmostEqual(_jaccard_similarity("a b c", "b c d"), 0.5)

    def test_empty_strings(self):
        # Two empty strings → 1.0 (both have no words)
        self.assertAlmostEqual(_jaccard_similarity("", ""), 1.0)

    def test_one_empty(self):
        self.assertAlmostEqual(_jaccard_similarity("", "a b"), 0.0)

    def test_subset(self):
        # {"a","b"} ⊆ {"a","b","c"} → 2/3
        self.assertAlmostEqual(_jaccard_similarity("a b", "a b c"), 2/3, places=5)


# ---------------------------------------------------------------------------
# extract_topics
# ---------------------------------------------------------------------------

class TestExtractTopics(unittest.TestCase):
    """Topic extraction from markdown text."""

    SIMPLE_REPORT = """# Company Overview

This is the overview section with some content here and there. It has many words
to ensure it exceeds the threshold for detailed coverage.

## Key Findings

Short mention.

## Impact and Aftermath

This section has a lot more content that should qualify as detailed coverage
because it has more than one hundred words of substantive analysis. We need
at least a hundred words here. The investigation prompted inquiries by
authorities and led to increased scrutiny of the hacker-for-hire industry.
In early 2024, a government agency indicted several individuals connected to
the exposed operations. The leaked documents remain one of the most significant
exposures of a state-sponsored hacking contractor operations to date. Analysts
expect continued fallout in the months and years ahead. Policy discussions
accelerated across governments. Additional remediation steps were mandated for
affected organizations throughout the affected regions worldwide.

"""

    def test_finds_all_headings(self):
        topics = extract_topics(self.SIMPLE_REPORT)
        headings = [t.heading for t in topics]
        self.assertIn("company overview", headings)
        self.assertIn("key findings", headings)
        self.assertIn("impact and aftermath", headings)

    def test_raw_heading_preserved(self):
        topics = extract_topics(self.SIMPLE_REPORT)
        overviews = [t for t in topics if t.heading == "company overview"]
        self.assertEqual(len(overviews), 1)
        self.assertEqual(overviews[0].raw_heading, "Company Overview")

    def test_heading_level_h1(self):
        topics = extract_topics(self.SIMPLE_REPORT)
        overview = next(t for t in topics if t.heading == "company overview")
        self.assertEqual(overview.level, 1)

    def test_heading_level_h2(self):
        topics = extract_topics(self.SIMPLE_REPORT)
        findings = next(t for t in topics if t.heading == "key findings")
        self.assertEqual(findings.level, 2)

    def test_coverage_mentioned_short_section(self):
        topics = extract_topics(self.SIMPLE_REPORT)
        findings = next(t for t in topics if t.heading == "key findings")
        self.assertEqual(findings.coverage, "mentioned")

    def test_coverage_detailed_long_section(self):
        topics = extract_topics(self.SIMPLE_REPORT)
        impact = next(t for t in topics if t.heading == "impact and aftermath")
        self.assertEqual(impact.coverage, "detailed")

    def test_word_count_positive(self):
        topics = extract_topics(self.SIMPLE_REPORT)
        for t in topics:
            self.assertGreaterEqual(t.word_count, 0)

    def test_empty_report_returns_empty_list(self):
        topics = extract_topics("")
        self.assertEqual(topics, [])

    def test_flat_text_no_headings_returns_one_topic(self):
        flat = "This is a report with no headings at all. Just plain text."
        topics = extract_topics(flat)
        # Flat text treated as single implicit topic
        self.assertEqual(len(topics), 1)
        self.assertEqual(topics[0].heading, "(no headings)")

    def test_citations_in_section_counted(self):
        report = """## References

See https://example.com/paper1 and https://example.org/doc2 for details.
"""
        topics = extract_topics(report)
        refs = next(t for t in topics if t.heading == "references")
        self.assertEqual(refs.citations_in_section, 2)

    def test_h4_headings_extracted(self):
        report = """#### Deep Nested Section

Some content here.
"""
        topics = extract_topics(report)
        self.assertEqual(len(topics), 1)
        self.assertEqual(topics[0].level, 4)

    def test_numbering_stripped_from_heading(self):
        report = """## 1. Introduction

Content here.
"""
        topics = extract_topics(report)
        self.assertEqual(topics[0].heading, "introduction")

    def test_trailing_colon_stripped(self):
        report = """## Background:

Content here.
"""
        topics = extract_topics(report)
        self.assertEqual(topics[0].heading, "background")


# ---------------------------------------------------------------------------
# match_topics
# ---------------------------------------------------------------------------

class TestMatchTopics(unittest.TestCase):
    """Cross-provider topic matching."""

    def _make_topic(self, heading: str, coverage: str = "detailed") -> Topic:
        normalized = _normalize_heading(heading)
        return Topic(
            heading=normalized,
            raw_heading=heading,
            level=2,
            word_count=150 if coverage == "detailed" else 20,
            coverage=coverage,
            citations_in_section=0,
        )

    def test_exact_match_two_providers(self):
        topics = {
            "openai": [self._make_topic("Company Overview")],
            "perplexity": [self._make_topic("Company Overview")],
        }
        matched = match_topics(topics)
        self.assertEqual(len(matched), 1)
        self.assertEqual(matched[0].canonical_name, "company overview")
        self.assertIn("openai", matched[0].coverage)
        self.assertIn("perplexity", matched[0].coverage)

    def test_exact_match_three_providers(self):
        topics = {
            "openai": [self._make_topic("Key Findings")],
            "perplexity": [self._make_topic("Key Findings")],
            "gemini": [self._make_topic("Key Findings")],
        }
        matched = match_topics(topics)
        self.assertEqual(len(matched), 1)
        m = matched[0]
        self.assertEqual(set(m.coverage.keys()), {"openai", "perplexity", "gemini"})

    def test_fuzzy_match_similar_headings(self):
        # "apt group connections and attribution" vs "apt group connections overview"
        # intersection={apt,group,connections} union={apt,group,connections,and,attribution,overview}
        # Jaccard = 3/6 = 0.50 — below threshold, separate clusters.
        #
        # Use headings with 3-word intersection out of 4-word union: Jaccard = 0.75 > 0.60
        # "key findings from the leak" vs "key findings from investigation"
        # intersection={key,findings,from} union={key,findings,from,the,leak,investigation} = 3/6 = 0.50 — still below.
        #
        # Use 3/4 union: "apt group connections" vs "apt group overview"
        # intersection={apt,group} union={apt,group,connections,overview} = 2/4 = 0.50 — below.
        #
        # Use 4/5: "apt group connections overview" vs "apt group connections analysis"
        # intersection={apt,group,connections} union={apt,group,connections,overview,analysis} = 3/5 = 0.60 — exactly at threshold.
        # Use strictly above: 4-word intersection / 5-word union is NOT strictly above.
        # Use 4/5 with the threshold check being >= : 3/5 = 0.60 meets FUZZY_MATCH_THRESHOLD >= 0.60
        topics = {
            "openai": [self._make_topic("APT Group Connections Overview")],
            "perplexity": [self._make_topic("APT Group Connections Analysis")],
        }
        matched = match_topics(topics)
        # intersection={apt,group,connections} / union={apt,group,connections,overview,analysis} = 3/5 = 0.60
        # Exactly meets threshold — should fuzzy-match into one cluster.
        self.assertEqual(len(matched), 1)

    def test_unmatched_topic_unique_to_one_provider(self):
        topics = {
            "openai": [self._make_topic("Company Overview")],
            "perplexity": [self._make_topic("Totally Different Topic")],
        }
        matched = match_topics(topics)
        self.assertEqual(len(matched), 2)
        agreements = {m.canonical_name: m.agreement_level for m in matched}
        self.assertTrue(any(v.startswith("unique-") for v in agreements.values()))

    def test_absent_provider_in_coverage(self):
        """Provider not covering a topic shows 'absent'."""
        topics = {
            "openai": [self._make_topic("Company Overview"), self._make_topic("Key Findings")],
            "perplexity": [self._make_topic("Company Overview")],
        }
        matched = match_topics(topics)
        # Find the Key Findings topic
        findings = next(m for m in matched if "findings" in m.canonical_name or "key findings" in m.canonical_name)
        self.assertEqual(findings.coverage.get("perplexity"), "absent")

    def test_single_provider_all_unique(self):
        topics = {
            "openai": [
                self._make_topic("Company Overview"),
                self._make_topic("Key Findings"),
            ],
        }
        matched = match_topics(topics)
        for m in matched:
            self.assertEqual(m.agreement_level, "unique-openai")

    def test_empty_providers_dict(self):
        matched = match_topics({})
        self.assertEqual(matched, [])

    def test_providers_with_no_topics(self):
        matched = match_topics({"openai": [], "perplexity": []})
        self.assertEqual(matched, [])

    def test_coverage_level_preserved(self):
        """Detailed vs mentioned coverage is preserved in MatchedTopic."""
        topics = {
            "openai": [self._make_topic("Background", coverage="detailed")],
            "perplexity": [self._make_topic("Background", coverage="mentioned")],
        }
        matched = match_topics(topics)
        self.assertEqual(len(matched), 1)
        self.assertEqual(matched[0].coverage["openai"], "detailed")
        self.assertEqual(matched[0].coverage["perplexity"], "mentioned")


# ---------------------------------------------------------------------------
# Agreement classification
# ---------------------------------------------------------------------------

class TestAgreementClassification(unittest.TestCase):
    """Verify consensus/majority/unique agreement levels."""

    def _make_topic(self, heading: str, coverage: str = "detailed") -> Topic:
        normalized = _normalize_heading(heading)
        return Topic(
            heading=normalized,
            raw_heading=heading,
            level=2,
            word_count=150 if coverage == "detailed" else 20,
            coverage=coverage,
            citations_in_section=0,
        )

    def test_consensus_all_three_providers(self):
        topics = {
            "openai": [self._make_topic("Shared Topic")],
            "perplexity": [self._make_topic("Shared Topic")],
            "gemini": [self._make_topic("Shared Topic")],
        }
        matched = match_topics(topics)
        self.assertEqual(matched[0].agreement_level, "consensus")

    def test_majority_two_of_three_providers(self):
        topics = {
            "openai": [self._make_topic("Shared Topic")],
            "perplexity": [self._make_topic("Shared Topic")],
            "gemini": [],
        }
        matched = match_topics(topics)
        self.assertEqual(matched[0].agreement_level, "majority")

    def test_unique_one_of_three_providers(self):
        topics = {
            "openai": [self._make_topic("Unique Topic")],
            "perplexity": [],
            "gemini": [],
        }
        matched = match_topics(topics)
        self.assertEqual(matched[0].agreement_level, "unique-openai")

    def test_unique_labels_the_correct_provider(self):
        topics = {
            "openai": [],
            "perplexity": [],
            "gemini": [self._make_topic("Gemini Only")],
        }
        matched = match_topics(topics)
        self.assertEqual(matched[0].agreement_level, "unique-gemini")


# ---------------------------------------------------------------------------
# build_matrix and citation overlap
# ---------------------------------------------------------------------------

class TestBuildMatrix(unittest.TestCase):
    """Integration tests for build_matrix() with ProviderResult instances."""

    OPENAI_REPORT = """# Company Overview

I-SOON is a Chinese cybersecurity contractor founded in 2010.
This section covers the corporate structure and founding date.
There is enough content here that it should be more than one hundred words
to qualify as detailed coverage by the matrix builder. Additional analysis
about the company's background and government relationships follows here.

## Key Findings

Brief mention.

## Impact and Aftermath

Long analysis of the impact. This section needs over one hundred words
to be classified as detailed. We add enough text here to ensure that
threshold is met. The aftermath included significant changes in the
cybersecurity landscape and increased scrutiny from government agencies
around the world. Further implications are discussed below.
"""

    PERPLEXITY_REPORT = """# Company Overview

I-SOON (Anxun Information Technology) is a Shanghai-registered firm.
This section provides background on the company structure.
We need enough words here to reach the detailed threshold.
More content about the company background and formation follows.
The company was active in government contracting for many years.
Additional details about their work are documented in official records.

## Key Findings from the Leak

This section has a brief overview of key findings.

## APT Associations

Coverage of APT group connections. This section should be long enough
to reach the detailed threshold and contains significant analysis
of the threat actor ecosystem. Multiple APT groups were linked to
I-SOON through shared infrastructure and tooling. Research from
several security firms confirmed these associations.
"""

    GEMINI_REPORT = """# Company Background

I-SOON analysis: Company Profile and APT Connections. Background
section covers the founding, leadership, and government relationships.
This is a longer section with many details about the company structure.
Headquarters in Chengdu, multiple offices, hundreds of employees.
Corporate governance and leadership structure also covered here.

## Government Relationships

Detailed analysis of I-SOON government clients. This section covers
Ministry of Public Security, Ministry of State Security, and People's
Liberation Army relationships in detail. Long analysis of how these
relationships worked and what services were provided to each agency.
Contract values and scope are also documented here.

## APT Group Connections

Direct attribution to Fishmonger and APT41. This section contains
extensive detail about the attribution methodology and evidence.
Multiple security firms contributed research to this topic and
their findings are synthesized here.
"""

    def setUp(self):
        self.results = [
            _provider_result("openai", self.OPENAI_REPORT, citations=[
                {"url": "https://example.com/shared"},
                {"url": "https://openai-only.com/paper"},
            ]),
            _provider_result("perplexity", self.PERPLEXITY_REPORT, citations=[
                {"url": "https://example.com/shared"},
                {"url": "https://perplexity-only.com/doc"},
            ]),
            _provider_result("gemini", self.GEMINI_REPORT, citations=[
                {"url": "https://example.com/shared"},
                {"url": "https://gemini-only.com/report"},
            ]),
        ]
        self.matrix = build_matrix(self.results)

    def test_returns_comparison_matrix(self):
        self.assertIsInstance(self.matrix, ComparisonMatrix)

    def test_providers_list_correct(self):
        self.assertEqual(set(self.matrix.providers), {"openai", "perplexity", "gemini"})

    def test_topics_is_list_of_matched_topics(self):
        self.assertIsInstance(self.matrix.topics, list)
        for t in self.matrix.topics:
            self.assertIsInstance(t, MatchedTopic)

    def test_topics_not_empty(self):
        self.assertGreater(len(self.matrix.topics), 0)

    def test_citation_overlap_detects_shared_url(self):
        shared = "https://example.com/shared"
        self.assertIn(shared, self.matrix.citation_overlap)
        self.assertEqual(set(self.matrix.citation_overlap[shared]), {"openai", "perplexity", "gemini"})

    def test_citation_overlap_excludes_unique_urls(self):
        unique = "https://openai-only.com/paper"
        # Unique URL should either be absent or have only one provider
        if unique in self.matrix.citation_overlap:
            self.assertEqual(len(self.matrix.citation_overlap[unique]), 1)

    def test_stats_total_topics(self):
        self.assertIn("total_topics", self.matrix.stats)
        self.assertEqual(self.matrix.stats["total_topics"], len(self.matrix.topics))

    def test_stats_agreement_counts_sum_to_total(self):
        stats = self.matrix.stats
        total = stats.get("total_topics", 0)
        parts = stats.get("consensus", 0) + stats.get("majority", 0) + stats.get("unique", 0)
        self.assertEqual(parts, total)

    def test_to_dict_produces_json_serializable_output(self):
        import json
        d = self.matrix.to_dict()
        # Should not raise
        serialized = json.dumps(d)
        parsed = json.loads(serialized)
        self.assertIn("providers", parsed)
        self.assertIn("topics", parsed)
        self.assertIn("citation_overlap", parsed)
        self.assertIn("stats", parsed)

    def test_to_dict_topic_entry_has_required_keys(self):
        d = self.matrix.to_dict()
        self.assertGreater(len(d["topics"]), 0)
        first = d["topics"][0]
        self.assertIn("name", first)
        self.assertIn("agreement", first)
        # Each provider should appear as a key
        for p in self.matrix.providers:
            self.assertIn(p, first)

    def test_failed_provider_excluded(self):
        """Failed providers (success=False) should be excluded from matrix."""
        results = [
            _provider_result("openai", self.OPENAI_REPORT),
            ProviderResult(
                provider="perplexity",
                success=False,
                error="API key missing",
            ),
        ]
        matrix = build_matrix(results)
        self.assertNotIn("perplexity", matrix.providers)

    def test_single_provider_all_unique(self):
        results = [_provider_result("openai", self.OPENAI_REPORT)]
        matrix = build_matrix(results)
        for t in matrix.topics:
            self.assertEqual(t.agreement_level, "unique-openai")

    def test_empty_results_list(self):
        matrix = build_matrix([])
        self.assertEqual(matrix.topics, [])
        self.assertEqual(matrix.providers, [])

    def test_citation_overlap_only_multi_provider(self):
        """citation_overlap should only include URLs cited by 2+ providers."""
        d = self.matrix.to_dict()
        for url, providers in d["citation_overlap"].items():
            self.assertGreaterEqual(len(providers), 2)


# ---------------------------------------------------------------------------
# Fixture integration test
# ---------------------------------------------------------------------------

class TestFixtureIntegration(unittest.TestCase):
    """Run build_matrix against the real sample fixture files."""

    def _load_provider_result(self, fixture_name: str) -> ProviderResult:
        data = _load_fixture(fixture_name)
        provider = fixture_name.replace("_sample.json", "")
        return ProviderResult(
            provider=provider,
            success=data.get("success", True),
            report=data.get("report", ""),
            citations=data.get("citations", []),
            model=data.get("model", f"mock-{provider}"),
            elapsed_seconds=data.get("elapsed_seconds", 0.0),
        )

    def test_build_matrix_with_fixtures(self):
        results = [
            self._load_provider_result("openai_sample.json"),
            self._load_provider_result("perplexity_sample.json"),
            self._load_provider_result("gemini_sample.json"),
        ]
        matrix = build_matrix(results)
        self.assertIsInstance(matrix, ComparisonMatrix)
        self.assertEqual(set(matrix.providers), {"openai", "perplexity", "gemini"})
        self.assertGreater(len(matrix.topics), 0)

    def test_fixture_topics_have_valid_coverage(self):
        results = [
            self._load_provider_result("openai_sample.json"),
            self._load_provider_result("perplexity_sample.json"),
            self._load_provider_result("gemini_sample.json"),
        ]
        matrix = build_matrix(results)
        valid_levels = {"detailed", "mentioned", "absent"}
        for t in matrix.topics:
            for provider, level in t.coverage.items():
                self.assertIn(level, valid_levels, f"Invalid coverage level '{level}' for provider '{provider}' in topic '{t.canonical_name}'")

    def test_fixture_stats_sanity(self):
        results = [
            self._load_provider_result("openai_sample.json"),
            self._load_provider_result("perplexity_sample.json"),
            self._load_provider_result("gemini_sample.json"),
        ]
        matrix = build_matrix(results)
        stats = matrix.stats
        self.assertGreater(stats["total_topics"], 0)
        self.assertGreaterEqual(stats["consensus"], 0)
        self.assertGreaterEqual(stats["majority"], 0)
        self.assertGreaterEqual(stats["unique"], 0)

    def test_fixture_serializes_to_json(self):
        import json
        results = [
            self._load_provider_result("openai_sample.json"),
            self._load_provider_result("perplexity_sample.json"),
            self._load_provider_result("gemini_sample.json"),
        ]
        matrix = build_matrix(results)
        # Should not raise
        serialized = json.dumps(matrix.to_dict())
        self.assertGreater(len(serialized), 10)


# ---------------------------------------------------------------------------
# _extract_body_keywords
# ---------------------------------------------------------------------------

class TestExtractBodyKeywords(unittest.TestCase):
    """Unit tests for stop-word filtered keyword extraction."""

    def test_returns_set(self):
        result = _extract_body_keywords("hello world")
        self.assertIsInstance(result, set)

    def test_lowercases_words(self):
        result = _extract_body_keywords("Hello World")
        self.assertIn("hello", result)
        self.assertIn("world", result)

    def test_removes_stop_words(self):
        # All stop words should be absent
        text = "the a an is are was were be been"
        result = _extract_body_keywords(text)
        self.assertEqual(len(result), 0)

    def test_strips_punctuation(self):
        result = _extract_body_keywords("company, overview! analysis.")
        self.assertIn("company", result)
        self.assertIn("overview", result)
        self.assertIn("analysis", result)

    def test_excludes_single_char_tokens(self):
        result = _extract_body_keywords("a b c hello")
        # 'b' and 'c' are single char (but also stop words covered),
        # 'hello' is 5 chars — should be present.
        self.assertIn("hello", result)
        self.assertNotIn("b", result)
        self.assertNotIn("c", result)

    def test_empty_text(self):
        result = _extract_body_keywords("")
        self.assertEqual(result, set())

    def test_stop_word_constant_contains_common_words(self):
        for word in ("the", "and", "of", "in", "to", "is"):
            self.assertIn(word, STOP_WORDS)

    def test_numeric_tokens_allowed(self):
        # Numbers should not be stripped
        result = _extract_body_keywords("2024 report analysis")
        self.assertIn("2024", result)


# ---------------------------------------------------------------------------
# _jaccard_similarity_sets
# ---------------------------------------------------------------------------

class TestJaccardSimilaritySets(unittest.TestCase):
    """Unit tests for set-based Jaccard similarity."""

    def test_identical_sets(self):
        a = {"foo", "bar", "baz"}
        self.assertAlmostEqual(_jaccard_similarity_sets(a, a), 1.0)

    def test_disjoint_sets(self):
        a = {"foo", "bar"}
        b = {"baz", "qux"}
        self.assertAlmostEqual(_jaccard_similarity_sets(a, b), 0.0)

    def test_partial_overlap(self):
        # {a,b,c} ∩ {b,c,d} = 2, union = 4 → 0.5
        a = {"a", "b", "c"}
        b = {"b", "c", "d"}
        self.assertAlmostEqual(_jaccard_similarity_sets(a, b), 0.5)

    def test_both_empty(self):
        self.assertAlmostEqual(_jaccard_similarity_sets(set(), set()), 1.0)

    def test_one_empty(self):
        self.assertAlmostEqual(_jaccard_similarity_sets(set(), {"a"}), 0.0)
        self.assertAlmostEqual(_jaccard_similarity_sets({"a"}, set()), 0.0)


# ---------------------------------------------------------------------------
# match_method tracking (exact, heading-fuzzy, unmatched)
# ---------------------------------------------------------------------------

class TestMatchMethodTracking(unittest.TestCase):
    """Tests for match_method metadata on MatchedTopic instances."""

    def _make_topic(
        self,
        heading: str,
        body_keywords: Set[str] = None,
        coverage: str = "detailed",
    ) -> Topic:
        normalized = _normalize_heading(heading)
        return Topic(
            heading=normalized,
            raw_heading=heading,
            level=2,
            word_count=150 if coverage == "detailed" else 20,
            coverage=coverage,
            citations_in_section=0,
            body_keywords=body_keywords or set(),
        )

    def test_exact_match_method_label(self):
        """Identical headings produce match_method='exact'."""
        topics = {
            "openai": [self._make_topic("Company Overview", {"founded", "shanghai", "contractor"})],
            "gemini": [self._make_topic("Company Overview", {"founded", "beijing", "contractor"})],
        }
        matched = match_topics(topics)
        self.assertEqual(len(matched), 1)
        self.assertEqual(matched[0].match_method, "exact")

    def test_heading_fuzzy_match_method_label(self):
        """Similar headings produce match_method='heading-fuzzy'."""
        # Jaccard on heading words: {apt,group,connections} ∩ {apt,group,connections,analysis}
        # = 3/4 = 0.75 >= 0.60 → heading-fuzzy
        topics = {
            "openai": [self._make_topic(
                "APT Group Connections Overview",
                {"apt", "threat", "actor", "infrastructure"},
            )],
            "gemini": [self._make_topic(
                "APT Group Connections Analysis",
                {"apt", "threat", "actor", "infrastructure"},
            )],
        }
        matched = match_topics(topics)
        self.assertEqual(len(matched), 1)
        self.assertEqual(matched[0].match_method, "heading-fuzzy")

    def test_unmatched_method_label_when_no_match(self):
        """Completely disjoint topics produce match_method='unmatched'."""
        topics = {
            "openai": [self._make_topic("Quantum Computing", {"qubit", "superposition", "entanglement"})],
            "gemini": [self._make_topic("Regulatory Compliance", {"regulation", "gdpr", "audit"})],
        }
        matched = match_topics(topics)
        self.assertEqual(len(matched), 2)
        for m in matched:
            self.assertEqual(m.match_method, "unmatched")

    def test_different_headings_below_fuzzy_threshold_are_unmatched(self):
        """Topics with different headings and low heading Jaccard stay unmatched."""
        # "Company Overview" vs "Company Background": intersection={company}, union={company,overview,background}
        # Jaccard = 1/3 ≈ 0.33 < 0.60 → unmatched (even if body keywords overlap)
        shared_words = {"semiconductor", "quantum", "manufacturing", "supply", "chain"}
        topics = {
            "openai": [self._make_topic("Company Overview", shared_words)],
            "gemini": [self._make_topic("Company Background", shared_words)],
        }
        matched = match_topics(topics)
        self.assertEqual(len(matched), 2)
        for m in matched:
            self.assertEqual(m.match_method, "unmatched")

    def test_heading_match_wins_over_body_keywords(self):
        """If a heading match exists, it is used; body keywords don't create additional matches."""
        shared_words = {"company", "founded", "shanghai", "contractor"}
        topics = {
            "openai": [self._make_topic("Company Overview", shared_words)],
            "gemini": [self._make_topic("Company Overview", shared_words)],
        }
        matched = match_topics(topics)
        self.assertEqual(len(matched), 1)
        self.assertEqual(matched[0].match_method, "exact")

    def test_match_method_present_on_all_matched_topics(self):
        """Every MatchedTopic must have match_method set to a valid value."""
        topics = {
            "openai": [
                self._make_topic("Company Overview", {"founded", "structure"}),
                self._make_topic("Key Findings", {"critical", "exploit", "breach"}),
            ],
            "gemini": [
                self._make_topic("Company Overview", {"founded", "structure"}),
                self._make_topic("Regulatory Impact", {"regulation", "compliance"}),
            ],
        }
        matched = match_topics(topics)
        valid_methods = {"exact", "heading-fuzzy", "unmatched"}
        for m in matched:
            self.assertIn(m.match_method, valid_methods)

    def test_to_dict_includes_match_method_per_topic(self):
        """to_dict() must include match_method key on every topic entry."""
        results = [
            _provider_result("openai", "# Company Overview\n\nContent here.\n"),
            _provider_result("gemini", "# Company Overview\n\nContent here.\n"),
        ]
        matrix = build_matrix(results)
        d = matrix.to_dict()
        for topic_entry in d["topics"]:
            self.assertIn("match_method", topic_entry)
            self.assertIn(topic_entry["match_method"],
                          {"exact", "heading-fuzzy", "unmatched"})

    def test_to_dict_includes_unmatched_hints(self):
        """to_dict() must include unmatched_hints at top level."""
        results = [
            _provider_result("openai", "# Company Overview\n\nContent.\n"),
            _provider_result("gemini", "# Completely Different\n\nOther content.\n"),
        ]
        matrix = build_matrix(results)
        d = matrix.to_dict()
        self.assertIn("unmatched_hints", d)
        self.assertIsInstance(d["unmatched_hints"], list)

    def test_unmatched_hints_have_required_keys(self):
        """Each unmatched_hint entry must have provider, heading, top_keywords."""
        results = [
            _provider_result("openai", "# Unique Topic Alpha\n\nSome specialized content with unique terminology.\n"),
            _provider_result("gemini", "# Totally Different Beta\n\nEntirely unrelated subject matter.\n"),
        ]
        matrix = build_matrix(results)
        for hint in matrix.unmatched_hints:
            self.assertIn("provider", hint)
            self.assertIn("heading", hint)
            self.assertIn("top_keywords", hint)
            self.assertIsInstance(hint["top_keywords"], list)


# ---------------------------------------------------------------------------
# Body keyword extraction with real reports
# ---------------------------------------------------------------------------

class TestBodyKeywordsInReports(unittest.TestCase):
    """Tests verifying body_keywords population via extract_topics."""

    def test_body_keywords_populated_on_extracted_topics(self):
        """extract_topics() must populate body_keywords on each Topic."""
        report = "# Analysis Section\n\nSemiconductor manufacturing process yield defect.\n"
        topics = extract_topics(report)
        self.assertEqual(len(topics), 1)
        kw = topics[0].body_keywords
        self.assertIsInstance(kw, set)
        self.assertIn("semiconductor", kw)
        self.assertIn("manufacturing", kw)
        # Stop words should not appear
        self.assertNotIn("the", kw)
        self.assertNotIn("is", kw)

    def test_body_keywords_on_flat_report(self):
        """Flat text (no headings) gets body_keywords from the whole report."""
        report = "Semiconductor quantum manufacturing analysis research findings."
        topics = extract_topics(report)
        self.assertEqual(len(topics), 1)
        kw = topics[0].body_keywords
        self.assertIn("semiconductor", kw)
        self.assertIn("quantum", kw)

    def test_unmatched_topics_appear_in_unmatched_hints_with_body_keywords(self):
        """Unmatched topics surface their body keywords in unmatched_hints."""
        results = [
            _provider_result("openai", "# Company Overview\n\nI-SOON contractor Shanghai government.\n"),
            _provider_result("gemini", "# Company Background\n\nI-SOON contractor Shanghai government.\n"),
        ]
        matrix = build_matrix(results)
        # Both topics are unmatched (heading Jaccard = 1/3 < 0.60)
        self.assertEqual(len(matrix.unmatched_hints), 2)
        for hint in matrix.unmatched_hints:
            self.assertIsInstance(hint["top_keywords"], list)
            # "isoon" and "contractor" should be in top_keywords
            self.assertTrue(len(hint["top_keywords"]) > 0)


if __name__ == "__main__":
    unittest.main()
