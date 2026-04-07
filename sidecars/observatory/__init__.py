"""Observatory sidecar package.

Read-only observer of runtime health state. W-OBS-4: upgraded to produce
a full analysis report by delegating to runtime.core.observatory.generate_report().
Output now includes metrics_summary, trends, patterns, suggestions, convergence,
and review_gate_health alongside the legacy health snapshot keys.

Entry point: sidecars/observatory/observe.py
"""
