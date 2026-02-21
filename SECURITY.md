# Security Policy

## Supported Versions

We actively support security updates for the following versions:

| Version | Supported          |
| ------- | ------------------ |
| 2.0.x   | :white_check_mark: |
| < 2.0   | :x:                |

## Reporting a Vulnerability

We take security issues seriously. If you discover a security vulnerability in this Claude Code configuration system, please follow these guidelines:

### Where to Report

**Preferred:** Use GitHub's private security advisory feature:
1. Navigate to the [Security tab](https://github.com/juanandresgs/claude-ctrl/security)
2. Click "Report a vulnerability"
3. Fill out the form with details

**Alternative:** Email security issues to the repository maintainer at `juanandresgs@gmail.com` with subject line: `[SECURITY] Claude System Vulnerability`

### What Counts as a Security Issue

In the context of a Claude Code configuration repository, security issues include:

- **Hook injection vulnerabilities** — Shell command injection via hook scripts
- **Permission bypasses** — Circumventing `branch-guard.sh`, `guard.sh`, or other safety gates
- **Credential exposure** — Accidental logging or storing of API keys, tokens, or secrets
- **Unsafe file operations** — Path traversal, arbitrary file writes, or deletion outside project scope
- **Privilege escalation** — Hooks gaining unintended system access
- **Supply chain risks** — Compromised submodules or dependencies

### What to Include

- Description of the vulnerability
- Steps to reproduce
- Affected versions
- Potential impact
- Suggested fix (if you have one)

### Response Timeline

- **Initial response:** Within 48 hours
- **Severity assessment:** Within 7 days
- **Fix timeline:** Depends on severity
  - Critical: 7-14 days
  - High: 14-30 days
  - Medium/Low: Next scheduled release

### Disclosure Policy

Please do **not** publicly disclose the vulnerability until we've had a chance to address it. We will:

1. Confirm receipt within 48 hours
2. Provide a severity assessment within 7 days
3. Work with you on a fix timeline
4. Credit you in the release notes (unless you prefer anonymity)
5. Publish a security advisory after the fix is released

## Security Best Practices

When using this configuration system:

- Never commit `.env` files or credentials to version control
- Review hook scripts before installation — they run with your user privileges
- Keep the system updated (`git pull` regularly)
- Use project-scoped API keys (not account-wide admin keys) for research skills
- Review the `settings.json` permissions allow-list before adding new patterns

## Known Limitations

This is a local configuration system for Claude Code. It does not:

- Run in sandboxed environments
- Validate external tool outputs (e.g., `gh`, `git`, `shellcheck`)
- Prevent all forms of command injection if external tools are compromised
- Protect against malicious user input — hooks trust the operator

If you use this system in a shared or untrusted environment, review all hook scripts and understand the execution model before proceeding.
