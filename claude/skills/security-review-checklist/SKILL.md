---
name: security-review-checklist
description: Use when performing a security review of a diff or pull request, or when writing a brief that delegates one — the priority-ordered checklist of what to check and the expected output format. Load before reviewing security-sensitive changes yourself, or before typing a review checklist into a task brief for a worker that isn't the dedicated security-officer agent.
---

# Security review checklist

A security review is independent and read-only: find real, exploitable problems, don't rubber-stamp the implementer's own summary of their work, and don't edit or fix anything yourself — report it. Pull the actual diff scope rather than trusting a description of it: `gh pr diff <n>` for a PR, `git diff` / `git diff --staged` against the base branch for local/pending changes. Skim the repo's `CLAUDE.md`/README first to learn its stack and conventions (framework, ORM, auth approach, deployment setup) so severity gets judged in context instead of by generic rule.

## What to check, in priority order

1. **Secrets and credentials** — hardcoded API keys, tokens, passwords, connection strings with embedded credentials; secrets committed to env files, seed data, fixtures, or test files instead of read from environment/secret store.
2. **Injection** — raw string interpolation into SQL/shell/template contexts instead of parameterized queries or safe APIs; unsafe `eval`/`exec`-equivalents; command construction from untrusted input.
3. **Auth and session handling** — new or modified auth flows, token/session storage, CORS configuration, missing authorization checks on new endpoints or routes.
4. **Database/connection safety** — connection pool exhaustion risk, missing timeouts, migrations that could lock or destroy data at scale, unsafe cascade deletes.
5. **Input validation** — new request/response models missing bounds or type constraints on user-controlled fields; unsanitized data reaching a render context (XSS) or a query.
6. **Dependency risk** — newly added packages with known CVEs or clearly unmaintained status (check an advisory if a package looks unfamiliar); unpinned versions in build/deploy files.
7. **Multi-tenant/data isolation** — for any multi-client or multi-user system, check that tenant/user-scoped queries can't leak another tenant's data.
8. **CI/CD and deployment config** — changes to workflows, compose files, or Dockerfiles: exposed ports, disabled security checks, secrets in plaintext, hook-skipping patterns (`--no-verify` and similar).

Don't flag issues outside this list unless they're a clear, concrete vulnerability — this is a security review, not a general code-quality pass.

## Output format

For each finding: file:line, a one-sentence description of the vulnerability, a concrete exploit scenario (what input/actor triggers it and what happens), and a suggested fix. Rank findings by severity (critical/high/medium/low), worst first. If you find nothing, say so plainly — don't manufacture findings to seem thorough. End with a one-line verdict: safe to proceed, or blocked pending fixes (and which findings are blocking vs. advisory).
