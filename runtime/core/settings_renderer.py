"""Render Claude settings for an isolated claude-ctrl root."""

from __future__ import annotations

import json
import shutil
from pathlib import Path
from typing import Any


def render_settings(source_path: str | Path, config_root: str | Path, output_path: str | Path | None = None) -> dict:
    source = Path(source_path)
    root = str(Path(config_root).resolve())
    data = json.loads(source.read_text())
    rendered = _rewrite(data, root)
    _sync_bundled_codex_plugin_cache(Path(config_root).resolve())
    if output_path is not None:
        out = Path(output_path)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(rendered, indent=2) + "\n")
    return rendered


def _sync_bundled_codex_plugin_cache(root: Path) -> None:
    """Keep the installed plugin cache aligned with the repo-owned source.

    Claude loads enabled plugins from plugins/cache. The repo tracks the forked
    Codex plugin source under plugins/marketplaces/openai-codex/plugins/codex,
    while plugins/cache is intentionally ignored runtime state. Rendering
    settings is the deterministic bootstrap point, so sync the source plugin into
    the cache before Claude starts. This prevents stale cached hook manifests
    from reintroducing hidden Stop hooks after the source manifest was fixed.
    """

    source = root / "plugins" / "marketplaces" / "openai-codex" / "plugins" / "codex"
    package_json = root / "plugins" / "marketplaces" / "openai-codex" / "package.json"
    if not source.is_dir() or not package_json.is_file():
        return
    try:
        version = json.loads(package_json.read_text()).get("version") or "1.0.4"
    except (OSError, json.JSONDecodeError):
        version = "1.0.4"
    target = root / "plugins" / "cache" / "openai-codex" / "codex" / str(version)
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(source, target, dirs_exist_ok=True)


def _rewrite(value: Any, root: str) -> Any:
    if isinstance(value, dict):
        return {k: _rewrite(v, root) for k, v in value.items()}
    if isinstance(value, list):
        return [_rewrite(v, root) for v in value]
    if isinstance(value, str):
        return value.replace("$HOME/.claude", root).replace("${HOME}/.claude", root)
    return value
