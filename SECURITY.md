# Security Policy

## Reporting a vulnerability

**Please do not open a public issue for security vulnerabilities.**

Report privately through GitHub's
[private vulnerability reporting](https://github.com/frkline/lemon/security/advisories/new)
(Security tab → "Report a vulnerability"), or email **frank.kline@gmail.com**.

Please include:

- A description of the issue and its impact
- Steps to reproduce (proof-of-concept if possible)
- Affected version / commit

You can expect an initial response within a few days. Once a fix is available,
we'll coordinate disclosure with you.

## Scope and threat model

Lemon is a personal, **unsandboxed** menu-bar app that runs on your own Mac. It:

- Stores the only sensitive secret — your issue-tracker API key/PAT — in the
  macOS **Keychain**, never in files or environment variables on disk.
- Launches your own `claude` CLI inside disposable git worktrees under `/tmp`.
- Talks to Linear / GitHub over HTTPS and runs a localhost-only MCP server
  (`127.0.0.1:8765`) when explicitly enabled.

Because Lemon drives a coding agent with your credentials and grants it tool
access inside a worktree, treat the issues you tag with 🍋 as trusted input.
Reports about credential handling, the MCP surface, or worktree/launch command
construction are especially welcome.
