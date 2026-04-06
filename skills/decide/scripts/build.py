#!/usr/bin/env python3
"""build — Inject decision config into wizard template.

@decision DEC-DECIDE-002
@title Single-file HTML output with embedded config — no build tools
@status accepted
@rationale No build dependencies, no npm, no bundler. Config injected as JS object
literal replacing the /* __CONFIG__ */ placeholder. Output is a self-contained HTML
file that works offline and can be shared trivially. --serve mode starts a local HTTP
server so the Confirm button can POST decisions back to disk for Claude to read.

Usage:
    python3 build.py <config.json> [--output PATH] [--open] [--serve]

Examples:
    python3 build.py decision-config.json --output configurator.html --open
    python3 build.py fixtures/monitor-setup.json --serve
"""

import argparse
import json
import subprocess
import sys
import threading
from functools import partial
from http.server import HTTPServer, BaseHTTPRequestHandler
from pathlib import Path
from socket import socket

# Add lib to path
sys.path.insert(0, str(Path(__file__).parent / 'lib'))

from template_engine import inject_config, validate_config


def load_config(config_path: Path) -> dict:
    """Load and parse config JSON."""
    if not config_path.exists():
        raise FileNotFoundError(f"Config file not found: {config_path}")

    with open(config_path, 'r', encoding='utf-8') as f:
        return json.load(f)


def auto_read_research(config: dict, config_dir: Path) -> dict:
    """Auto-read research reports if meta.researchDir is set but research is empty."""
    if 'meta' not in config or 'researchDir' not in config['meta']:
        return config

    research_dir = config['meta']['researchDir']

    if 'research' in config and config['research'].get('sources'):
        return config

    if not Path(research_dir).is_absolute():
        research_path = config_dir / research_dir
    else:
        research_path = Path(research_dir)

    if not research_path.exists():
        print(f"Warning: Research directory not found: {research_path}", file=sys.stderr)
        return config

    report_md = research_path / 'report.md'
    if report_md.exists():
        with open(report_md, 'r', encoding='utf-8') as f:
            report_content = f.read()

        lines = report_content.split('\n')
        summary_lines = []
        in_summary = False
        for line in lines:
            if line.startswith('## Executive Summary'):
                in_summary = True
                continue
            if in_summary:
                if line.startswith('##'):
                    break
                if line.strip():
                    summary_lines.append(line.strip())

        summary = ' '.join(summary_lines[:3]) if summary_lines else None

        config['research'] = {
            'summary': summary,
            'sources': []
        }

        for provider_file in ['openai.md', 'perplexity.md', 'gemini.md']:
            provider_path = research_path / provider_file
            if provider_path.exists():
                with open(provider_path, 'r', encoding='utf-8') as f:
                    content = f.read()

                provider_name = provider_file.replace('.md', '').capitalize()
                content_lines = [l.strip() for l in content.split('\n') if l.strip() and not l.startswith('#')]
                condensed = ' '.join(content_lines[:5])[:500] + '...'

                config['research']['sources'].append({
                    'provider': provider_name,
                    'title': f'{provider_name} Deep Research Report',
                    'content': condensed,
                    'citations': []
                })

    return config


def build_configurator(config_path: Path, output_path: Path) -> str:
    """Build configurator HTML from config. Returns the HTML content."""
    config = load_config(config_path)
    config = auto_read_research(config, config_path.parent)

    errors = validate_config(config)
    if errors:
        print("Config validation failed:", file=sys.stderr)
        for error in errors:
            print(f"  - {error}", file=sys.stderr)
        raise ValueError(f"{len(errors)} validation error(s)")

    template_path = Path(__file__).parent.parent / 'templates' / 'wizard.html'
    if not template_path.exists():
        raise FileNotFoundError(f"Template not found: {template_path}")

    with open(template_path, 'r', encoding='utf-8') as f:
        template_content = f.read()

    html = inject_config(template_content, config)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    with open(output_path, 'w', encoding='utf-8') as f:
        f.write(html)

    print(f"Built configurator: {output_path}")
    print(f"  Title: {config['meta']['title']}")
    print(f"  Type: {config['meta']['type']}")
    print(f"  Steps: {len(config['steps'])}")
    total_options = sum(len(step['options']) for step in config['steps'])
    print(f"  Total options: {total_options}")

    return html


def open_in_browser(url_or_path) -> None:
    """Open URL or file in default browser."""
    import platform
    system = platform.system()
    target = str(url_or_path)

    try:
        if system == 'Darwin':
            subprocess.run(['open', target], check=True)
        elif system == 'Linux':
            subprocess.run(['xdg-open', target], check=True)
        elif system == 'Windows':
            subprocess.run(['start', target], shell=True, check=True)
    except subprocess.CalledProcessError as e:
        print(f"Warning: Failed to open browser: {e}", file=sys.stderr)


def find_free_port() -> int:
    """Find an available port."""
    with socket() as s:
        s.bind(('', 0))
        return s.getsockname()[1]


def make_handler(html_content: str, decisions_path: Path):
    """Create a request handler class with the HTML content and decisions path baked in."""

    class ConfiguratorHandler(BaseHTTPRequestHandler):

        def do_GET(self):
            if self.path == '/' or self.path == '/index.html':
                self.send_response(200)
                self.send_header('Content-Type', 'text/html; charset=utf-8')
                self.end_headers()
                self.wfile.write(html_content.encode('utf-8'))
            else:
                self.send_error(404)

        def do_POST(self):
            if self.path == '/api/confirm':
                content_length = int(self.headers.get('Content-Length', 0))
                body = self.rfile.read(content_length)

                try:
                    decisions = json.loads(body)
                except json.JSONDecodeError:
                    self.send_response(400)
                    self.send_header('Content-Type', 'application/json')
                    self.end_headers()
                    self.wfile.write(json.dumps({"error": "Invalid JSON"}).encode())
                    return

                decisions_path.parent.mkdir(parents=True, exist_ok=True)
                with open(decisions_path, 'w', encoding='utf-8') as f:
                    json.dump(decisions, f, indent=2)

                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Access-Control-Allow-Origin', '*')
                self.end_headers()
                self.wfile.write(json.dumps({"status": "ok", "path": str(decisions_path)}).encode())

                # Print to stdout so Claude sees it when background task completes
                print(f"\nDECISIONS CONFIRMED — saved to: {decisions_path}")
                print(f"Server shutting down.")

                # Shut down server from a separate thread (can't call from request handler)
                threading.Thread(target=self.server.shutdown, daemon=True).start()

            else:
                self.send_error(404)

        def do_OPTIONS(self):
            """Handle CORS preflight."""
            self.send_response(200)
            self.send_header('Access-Control-Allow-Origin', '*')
            self.send_header('Access-Control-Allow-Methods', 'POST, OPTIONS')
            self.send_header('Access-Control-Allow-Headers', 'Content-Type')
            self.end_headers()

        def log_message(self, format, *args):
            """Suppress routine request logs."""
            pass

    return ConfiguratorHandler


def serve_configurator(html_content: str, decisions_path: Path) -> None:
    """Start HTTP server to serve configurator and receive decisions."""
    port = find_free_port()
    handler = make_handler(html_content, decisions_path)
    server = HTTPServer(('127.0.0.1', port), handler)

    url = f"http://localhost:{port}/"
    print(f"Serving configurator at: {url}")
    print(f"Decisions will be saved to: {decisions_path}")
    print(f"Waiting for user to confirm decisions...")

    # Open browser
    open_in_browser(url)

    # Serve until decisions are submitted — handler calls shutdown() after writing file
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        print(f"Done. Decisions at: {decisions_path}")


def main():
    parser = argparse.ArgumentParser(
        description='Build decision configurator from config JSON',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__
    )
    parser.add_argument('config', type=Path, help='Path to config JSON file')
    parser.add_argument(
        '--output', '-o',
        type=Path,
        help='Output HTML path (default: {config-name}-configurator.html)'
    )
    parser.add_argument(
        '--open',
        action='store_true',
        help='Open configurator in browser after building'
    )
    parser.add_argument(
        '--serve',
        action='store_true',
        help='Start local HTTP server and open in browser. '
             'Confirm button POSTs decisions to server, which writes decisions.json to disk.'
    )
    parser.add_argument(
        '--decisions-out',
        type=Path,
        help='Path for decisions output file (default: decisions.json in CWD)'
    )

    args = parser.parse_args()

    # Determine output path
    if args.output:
        output_path = args.output
    else:
        config_name = args.config.stem
        output_path = Path.cwd() / f'{config_name}-configurator.html'

    # Build
    try:
        html = build_configurator(args.config, output_path)
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)

    # Serve mode: start HTTP server
    if args.serve:
        decisions_path = args.decisions_out or (Path.cwd() / 'decisions.json')
        serve_configurator(html, decisions_path)
    elif args.open:
        print(f"Opening {output_path} in browser...")
        open_in_browser(output_path)


if __name__ == '__main__':
    main()
