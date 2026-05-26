"""v6 critic provider command-shape tests."""

from runtime.core.critic_runner import _provider_invocation


def test_codex_invocation_is_read_only_ephemeral_and_stdin_prompt():
    argv, stdin_text = _provider_invocation("codex", "/bin/codex", "PROMPT", "/repo/wt")
    assert argv == [
        "/bin/codex",
        "exec",
        "--sandbox",
        "read-only",
        "--ephemeral",
        "--cd",
        "/repo/wt",
        "-",
    ]
    assert stdin_text == "PROMPT"


def test_gemini_invocation_is_plan_mode_headless():
    argv, stdin_text = _provider_invocation("gemini", "/bin/gemini", "PROMPT", "/repo/wt")
    assert argv == [
        "/bin/gemini",
        "--approval-mode",
        "plan",
        "--output-format",
        "text",
        "--prompt",
        "PROMPT",
    ]
    assert stdin_text == ""
