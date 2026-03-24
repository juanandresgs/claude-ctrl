#!/usr/bin/env python3
"""Search sidecar — indexes traces and manifest entries for text search.

Shadow-mode: read-only observer. Never writes to any canonical table.
Provides simple case-insensitive substring search over traces and the
trace_manifest table, returning ranked results by type.

Usage (standalone):
    python3 sidecars/search/search.py <query>
    python3 sidecars/search/search.py <query> --limit 5

Usage (via cc-policy):
    cc-policy sidecar search <query>

@decision DEC-SIDECAR-001
Title: Sidecars are read-only consumers of the canonical SQLite runtime
Status: accepted
Rationale: SearchIndex reads the traces and trace_manifest tables with
  SELECT-only queries and performs all matching in Python. No writes occur.
  The test suite verifies this via row-count assertions before/after
  observe(), search(), and report() calls. Search is intentionally a
  simple case-insensitive substring match — no external search engine,
  no FTS5 virtual table (which would require INSERT), no index tables.
  This keeps the sidecar genuinely read-only at the SQLite layer.

@decision DEC-SIDECAR-003
Title: SearchIndex loads traces and manifest entries into memory
Status: accepted
Rationale: The sidecar loads the 50 most recent traces and 200 most recent
  manifest entries into memory at observe() time, then searches in Python.
  An in-memory scan over O(250) rows is fast enough (<1ms) for interactive
  CLI use. A production FTS or index would require writes; staying in-memory
  keeps the read-only invariant. The 50/200 limits are hardcoded but the
  search() method accepts a limit argument for result count. If the corpus
  grows large enough to need real FTS, that becomes a separate ticket.
"""

from __future__ import annotations

import json
import sys
import time
from pathlib import Path
import sqlite3
from typing import Optional

# Allow running as `python3 sidecars/search/search.py` from project root
_HERE = Path(__file__).resolve().parent
_PROJECT_ROOT = _HERE.parent.parent
if str(_PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(_PROJECT_ROOT))

# Limits for how many rows to load at observe() time
_TRACE_LOAD_LIMIT = 50
_MANIFEST_LOAD_LIMIT = 200


class SearchIndex:
    """Read-only search sidecar over traces and trace_manifest.

    Reads: traces (50 most recent), trace_manifest (200 most recent).
    Never writes to any table.

    Attributes populated after observe():
        traces:           list[dict] — recent traces, newest first
        manifest_entries: list[dict] — recent manifest entries, newest first
    """

    def __init__(self, name: str, conn: sqlite3.Connection):
        self.name = name
        self._conn = conn
        # Populated by observe()
        self.traces: list[dict] = []
        self.manifest_entries: list[dict] = []

    def observe(self) -> None:
        """Execute read-only queries to load the search corpus.

        Loads the most recent traces and trace_manifest entries into memory.
        Safe to call multiple times; each call refreshes the corpus.
        """
        conn = self._conn

        trace_rows = conn.execute(
            "SELECT session_id, agent_role, ticket, started_at, ended_at, summary"
            " FROM traces"
            " ORDER BY started_at DESC"
            f" LIMIT {_TRACE_LOAD_LIMIT}"
        ).fetchall()
        self.traces = [dict(r) for r in trace_rows]

        manifest_rows = conn.execute(
            "SELECT id, session_id, entry_type, path, detail, created_at"
            " FROM trace_manifest"
            " ORDER BY created_at DESC"
            f" LIMIT {_MANIFEST_LOAD_LIMIT}"
        ).fetchall()
        self.manifest_entries = [dict(r) for r in manifest_rows]

    def search(self, query: str, limit: int = 10) -> list[dict]:
        """Case-insensitive substring search across traces and manifest entries.

        Searches the following fields:
          traces:          ticket, agent_role, summary, session_id
          trace_manifest:  path, detail, entry_type, session_id

        Each result is a dict with:
          type: "trace" | "manifest"
          data: the full row dict

        Results are returned in observation order (traces before manifests,
        then in the order they appear in the loaded corpus). The combined
        result list is truncated to `limit`.

        Args:
            query: Search term (case-insensitive substring match).
            limit: Maximum number of results to return (default 10).

        Returns:
            List of result dicts, up to `limit` entries.
        """
        if not query:
            return []

        q = query.lower()
        results: list[dict] = []

        for trace in self.traces:
            if self._trace_matches(trace, q):
                results.append({"type": "trace", "data": trace})

        for entry in self.manifest_entries:
            if self._manifest_matches(entry, q):
                results.append({"type": "manifest", "data": entry})

        return results[:limit]

    def _trace_matches(self, trace: dict, query_lower: str) -> bool:
        """Return True if any searchable trace field contains query_lower."""
        fields = [
            trace.get("ticket") or "",
            trace.get("agent_role") or "",
            trace.get("summary") or "",
            trace.get("session_id") or "",
        ]
        return any(query_lower in f.lower() for f in fields)

    def _manifest_matches(self, entry: dict, query_lower: str) -> bool:
        """Return True if any searchable manifest field contains query_lower."""
        fields = [
            entry.get("path") or "",
            entry.get("detail") or "",
            entry.get("entry_type") or "",
            entry.get("session_id") or "",
        ]
        return any(query_lower in f.lower() for f in fields)

    def report(self) -> dict:
        """Return a JSON-serializable index summary dict.

        Returns:
            dict with keys: name, observed_at, indexed_traces,
            indexed_manifest_entries.
        """
        return {
            "name": self.name,
            "observed_at": int(time.time()),
            "indexed_traces": len(self.traces),
            "indexed_manifest_entries": len(self.manifest_entries),
        }


# ---------------------------------------------------------------------------
# Standalone entry point
# ---------------------------------------------------------------------------

def _main() -> int:
    """Run a search query and print JSON results to stdout."""
    import argparse

    parser = argparse.ArgumentParser(
        description="Search traces and manifest entries (read-only sidecar)."
    )
    parser.add_argument("query", help="Search term")
    parser.add_argument("--limit", type=int, default=10,
                        help="Maximum results to return (default 10)")
    args = parser.parse_args()

    from runtime.core.config import default_db_path
    from runtime.core.db import connect
    from runtime.schemas import ensure_schema

    db_path = default_db_path()
    if not db_path.exists():
        print(json.dumps({
            "error": f"database not found: {db_path}",
            "query": args.query,
            "results": [],
        }, indent=2))
        return 1

    conn = connect(db_path)
    ensure_schema(conn)
    try:
        si = SearchIndex("search", conn)
        si.observe()
        results = si.search(args.query, limit=args.limit)
        print(json.dumps({
            "query": args.query,
            "count": len(results),
            "results": results,
        }, indent=2))
    finally:
        conn.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(_main())
