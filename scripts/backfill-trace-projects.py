#!/usr/bin/env python3
"""
backfill-trace-projects.py — Backfill null project_name entries in traces/index.jsonl

For each trace index entry with a null/empty project_name, find the nearest
non-null neighbor by timestamp (within ±60 minutes). Update the trace's
manifest.json with the inferred project_name and project fields, then
rebuild index.jsonl from the updated manifests.

@decision DEC-BACKFILL-001
@title Python implementation for trace project backfill
@status accepted
@rationale 896 entries require timestamp-sorted lookup with binary search.
  Python provides json, bisect, and datetime stdlib — the right tools for
  this job. Bash+jq would require a per-entry jq call (896 invocations)
  whereas Python loads all data into memory once.

Usage:
  python3 scripts/backfill-trace-projects.py [--trace-store=PATH] [--dry-run]

Returns: 0 on success, 1 on error
"""

import json
import os
import sys
import shutil
import argparse
import subprocess
from datetime import datetime, timezone
from bisect import bisect_left

WINDOW_SECONDS = 3600  # ±60 minutes


def parse_iso(ts: str) -> float:
    """Parse ISO 8601 UTC timestamp to epoch float. Returns 0.0 on failure."""
    if not ts:
        return 0.0
    for fmt in ("%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%dT%H:%M:%S.%fZ"):
        try:
            dt = datetime.strptime(ts, fmt).replace(tzinfo=timezone.utc)
            return dt.timestamp()
        except ValueError:
            continue
    return 0.0


def load_index(index_path: str) -> list[dict]:
    """Load all index entries from index.jsonl. Returns list of dicts."""
    entries = []
    with open(index_path) as f:
        for lineno, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                entries.append(json.loads(line))
            except json.JSONDecodeError as e:
                print(f"  WARN: index line {lineno} malformed — skipping: {e}", file=sys.stderr)
    return entries


def find_nearest_project(null_epoch: float, anchors: list[tuple]) -> str | None:
    """
    Find project_name of the nearest anchor within WINDOW_SECONDS of null_epoch.
    anchors: sorted list of (epoch, project_name, project_root) tuples.
    Returns project_name string or None if none within window.
    """
    if not anchors:
        return None, None

    epochs = [a[0] for a in anchors]
    idx = bisect_left(epochs, null_epoch)

    best_dist = float("inf")
    best_name = None
    best_root = None

    # Check neighbors at idx-1 and idx (the insertion point and its predecessor)
    for i in (idx - 1, idx):
        if 0 <= i < len(anchors):
            dist = abs(anchors[i][0] - null_epoch)
            if dist < best_dist and dist <= WINDOW_SECONDS:
                best_dist = dist
                best_name = anchors[i][1]
                best_root = anchors[i][2]

    return best_name, best_root


def update_manifest(manifest_path: str, project_name: str, project_root: str) -> bool:
    """
    Update manifest.json project_name and project fields using jq.
    Uses tmp+mv pattern for safety. Returns True on success.
    """
    if not os.path.exists(manifest_path):
        return False

    tmp_path = manifest_path + ".tmp"
    try:
        result = subprocess.run(
            [
                "jq",
                "--arg", "project_name", project_name,
                "--arg", "project", project_root,
                '. + {project_name: $project_name, project: $project}',
                manifest_path,
            ],
            capture_output=True,
            text=True,
        )
        if result.returncode != 0 or not result.stdout.strip():
            print(f"  ERROR: jq failed for {manifest_path}: {result.stderr}", file=sys.stderr)
            return False

        with open(tmp_path, "w") as f:
            f.write(result.stdout)
        os.rename(tmp_path, manifest_path)
        return True
    except Exception as e:
        print(f"  ERROR: updating {manifest_path}: {e}", file=sys.stderr)
        if os.path.exists(tmp_path):
            os.unlink(tmp_path)
        return False


def rebuild_index(trace_store: str) -> int:
    """
    Rebuild index.jsonl from all manifest.json files.
    Writes to index.jsonl.tmp then atomically renames.
    Returns count of entries written.
    """
    index_path = os.path.join(trace_store, "index.jsonl")
    tmp_path = index_path + ".tmp"

    entries = []
    for name in os.listdir(trace_store):
        manifest_path = os.path.join(trace_store, name, "manifest.json")
        if not os.path.isfile(manifest_path):
            continue
        try:
            with open(manifest_path) as f:
                m = json.load(f)
            entry = {
                "trace_id": m.get("trace_id", "unknown"),
                "agent_type": m.get("agent_type", "unknown"),
                "project_name": m.get("project_name"),
                "branch": m.get("branch"),
                "started_at": m.get("started_at", ""),
                "duration_seconds": m.get("duration_seconds", 0),
                "outcome": m.get("outcome", "unknown"),
                "test_result": m.get("test_result", "unknown"),
                "files_changed": m.get("files_changed", 0),
            }
            entries.append(entry)
        except Exception:
            continue

    # Sort by started_at (chronological order)
    entries.sort(key=lambda e: e.get("started_at") or "")

    with open(tmp_path, "w") as f:
        for entry in entries:
            f.write(json.dumps(entry) + "\n")

    os.rename(tmp_path, index_path)
    return len(entries)


def main():
    parser = argparse.ArgumentParser(description="Backfill null project_name in trace index")
    parser.add_argument(
        "--trace-store",
        default=os.path.join(os.path.expanduser("~"), ".claude", "traces"),
        help="Path to trace store directory (default: ~/.claude/traces)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Report what would be fixed without modifying any files",
    )
    args = parser.parse_args()

    trace_store = args.trace_store
    index_path = os.path.join(trace_store, "index.jsonl")

    if not os.path.isfile(index_path):
        print(f"ERROR: index.jsonl not found at {index_path}", file=sys.stderr)
        sys.exit(1)

    print(f"Trace store: {trace_store}")
    print(f"Index: {index_path}")
    if args.dry_run:
        print("DRY RUN — no files will be modified")
    print()

    # Load all index entries
    entries = load_index(index_path)
    print(f"Loaded {len(entries)} index entries")

    # Separate null from non-null entries
    null_entries = []
    anchors = []  # (epoch, project_name, project_root)

    for e in entries:
        pn = e.get("project_name")
        is_null = not pn or pn == "null"
        ts = parse_iso(e.get("started_at", ""))
        if is_null:
            null_entries.append((ts, e))
        else:
            # Use project_name as the anchor; project root is not in index
            # We'll use project_name as both name and a placeholder for root
            # The actual project root will be inferred from manifest if available
            anchors.append((ts, pn, ""))

    print(f"Null project_name entries: {len(null_entries)}")
    print(f"Non-null anchor entries: {len(anchors)}")
    print()

    if not null_entries:
        print("No null entries to fix. Done.")
        return

    # Sort anchors by epoch for binary search
    anchors.sort(key=lambda a: a[0])

    # Build a richer anchor list by reading manifests of non-null traces
    # to get the actual project root path
    print("Building anchor map from non-null manifests...")
    anchor_manifest_map = {}  # project_name -> (project_root or "")
    for e in entries:
        pn = e.get("project_name")
        if not pn or pn == "null":
            continue
        tid = e.get("trace_id", "")
        if not tid:
            continue
        manifest_path = os.path.join(trace_store, tid, "manifest.json")
        if os.path.isfile(manifest_path):
            try:
                with open(manifest_path) as f:
                    m = json.load(f)
                proj_root = m.get("project") or ""
                if proj_root and proj_root != "null":
                    anchor_manifest_map[pn] = proj_root
            except Exception:
                continue

    # Rebuild anchors with actual project roots where available
    anchors_with_roots = []
    for ts, pn, _ in anchors:
        root = anchor_manifest_map.get(pn, "")
        anchors_with_roots.append((ts, pn, root))

    # Create backup before any modifications
    if not args.dry_run:
        backup_path = index_path + ".bak"
        shutil.copy2(index_path, backup_path)
        print(f"Backup created: {backup_path}")

    # Process each null entry
    fixed = 0
    unresolvable = 0
    no_manifest = 0
    projects_found: dict[str, int] = {}

    for null_epoch, entry in null_entries:
        tid = entry.get("trace_id", "")
        manifest_path = os.path.join(trace_store, tid, "manifest.json") if tid else ""

        inferred_name, inferred_root = find_nearest_project(null_epoch, anchors_with_roots)

        if not inferred_name:
            unresolvable += 1
            continue

        # Check if manifest exists to update
        if not os.path.isfile(manifest_path):
            # No manifest to update — but we'll still count this as resolved for index rebuild
            # The index rebuild will pick up the fixed value only if manifest exists
            no_manifest += 1
            # We can't fix the index entry without a manifest; mark unresolvable
            unresolvable += 1
            continue

        projects_found[inferred_name] = projects_found.get(inferred_name, 0) + 1

        if args.dry_run:
            print(f"  WOULD FIX: {tid} → project_name={inferred_name} (dist={abs(null_epoch - anchors_with_roots[0][0]):.0f}s)")
            fixed += 1
        else:
            # Use inferred_root if available, else use project_name as root basename hint
            root_to_use = inferred_root or inferred_name
            if update_manifest(manifest_path, inferred_name, root_to_use):
                fixed += 1
            else:
                unresolvable += 1

    print()
    print(f"Results:")
    print(f"  Fixed (manifest updated): {fixed}")
    print(f"  Unresolvable (no neighbor within ±60min): {unresolvable - no_manifest}")
    print(f"  No manifest directory: {no_manifest}")
    if projects_found:
        print(f"  Projects inferred: {dict(sorted(projects_found.items(), key=lambda x: -x[1]))}")

    # Rebuild index from updated manifests
    if not args.dry_run:
        print()
        print("Rebuilding index.jsonl from manifests...")
        count = rebuild_index(trace_store)
        print(f"Index rebuilt with {count} entries from manifest files.")
        print()
        print("Note: null entries whose trace directories were deleted cannot be recovered")
        print("in the index. The index will reflect only traces with existing manifest files.")
        print("This is correct — deleted traces should not appear in the index.")


if __name__ == "__main__":
    main()
