---
name: devcontainer-first
description: Use before editing files or running project commands in any repository — and whenever a tool call is blocked by require-devcontainer.sh. Holds the rule that project work happens inside the project's devcontainer, the exemption and container-detection checks, and the decision tree for getting a session containerized (dispatching chief-engineer, and when to stop and ask the Captain first).
---

# Devcontainer first

**No session — orchestrated, delegated, or a session the Captain started by hand — edits files or runs project commands against a project's working tree unless it is actually running inside that project's container.** This is not a preference. Agents did engineering work on the WSL host against a containerized project and left the host cluttered with build artifacts, caches and installed toolchains; the container exists precisely so that never happens.

Enforcement is mechanical, via the `require-devcontainer.sh` `PreToolUse` hook — because a prose rule cannot bind a fresh session that never read the conversation. This skill is the decision procedure for what to do once you are blocked, or once you notice the situation yourself before trying.

Why the hook and not just this rule: subagents share the top-level session's OS process, so a subagent can never be independently "inside" a container. The only thing that is ever really containerized is the top-level `claude` process (a VS Code Dev Containers attach, or `chief-engineer`'s Phase 4 `docker run ... claude`). So "get containerized" always means relaunching the *session*, never something a worker can arrange for itself mid-task.

## Two checks, in this order

**1. Is the repo exempt?** A `.no-auto-provision` file at the git project root (`git rev-parse --show-toplevel`) means the repo opted out, and host-side work there is correct and expected. Test for that file and nothing else — **never hardcode a path to the dotfiles repo**. The marker is the portable mechanism; the dotfiles repo is just its first user (it configures the host machine itself, so containerizing it would break the access it needs). Any repo whose job is configuring the host it lives on may adopt it. A directory that is not inside a git repo at all (a scratch dir, `$HOME`) is likewise out of scope.

**2. Am I in a container?** Any one of these is sufficient:

- `/.dockerenv` exists
- `/proc/1/cgroup` mentions `docker` or `containerd`
- `$REMOTE_CONTAINERS` is `true`
- `$CODESPACES` is set

This deliberately answers only "am I in *some* container", not "am I in *this project's* container". Distinguishing those reliably from inside is not worth the complexity: the realistic failure this guards against is work happening on the bare host, not a session confusing one devcontainer for another.

## Once blocked: the decision tree

**No `.devcontainer/` (or k8s/Helm equivalent) in the project yet** → **confirm with the Captain before provisioning.** Retrofitting containerization onto an established repo is consequential — it adds committed files, changes how everyone opens the project, and is a judgment call about that repo's conventions. This is deliberately different from the fresh-project flow, where provisioning is automatic. Under `number-one`, escalate; in a direct session with no orchestrator above you, ask with `AskUserQuestion`. Once approved, dispatch `chief-engineer` for **Phase 3** (containerization) **+ Phase 4** (build and relaunch).

**Project has `.devcontainer/` but this session simply isn't running in it** → dispatch `chief-engineer` for **Phase 4 alone**. No confirmation needed; nothing new is being decided, the baseline already exists and is just not in effect. `chief-engineer` is written to be invoked for a single phase — read its definition rather than restating its steps into a brief.

**`chief-engineer` reports Phase 4's preconditions fail** — docker daemon unreachable, no `CLAUDE_CODE_OAUTH_TOKEN`/`ANTHROPIC_API_KEY` to forward, build failure — → **stop and report to the Captain rather than proceeding as if the baseline were met.** Never do the work on the host as a substitute. An honest "couldn't get containerized, here's why" is the correct outcome; host-side work that quietly reproduces the original problem is not.

**A relaunch that can't attach interactively.** An interactive `-it` session started from a tool call is not attachable in every environment (`chief-engineer`'s own Phase 4 note covers this). When that happens, report exactly how far it got — image built, container starts, `claude --version` runs inside it — and what blocked the attach, so the Captain can start it by hand from a real terminal. Do not report a relaunch as done because the build succeeded; per `verification-discipline`, building an image is not running a session in it.

## What is still allowed on the host

The hook permits a narrow read-only and orchestration set so a blocked session can still orient itself and report: read-only `git` (`status`, `diff`, `log`, `show`, `branch`, `fetch`, `remote`, `worktree`, `rev-parse`), read-only `gh` (`pr view|checks|status|list`, `issue view|list`), and basic reads (`ls`, `find`, `cat`, `grep`, `wc`, `pwd`, `echo`). Everything else — installs, builds, test runs, `git commit`, and any `Edit`/`Write`/`NotebookEdit` — is blocked on a non-exempt, non-containerized project.

`docker build`/`run`/`exec` are **not** on that allowlist. Provisioning goes through `chief-engineer`, which the hook exempts by `agent_type` because its whole job is host-side bootstrap before any container exists. Treat that exemption as the single intended path in, not as a technique to borrow — do not ask a general-purpose worker to run the docker commands on `chief-engineer`'s behalf.

The allowlist errs wide on purpose: it over-blocks rather than risks under-firing, because an under-firing guard here fails silently and reproduces exactly the host clutter it exists to prevent. If you hit a legitimate read-only command it refuses, that is a case for widening the allowlist deliberately — surface it to the Captain, don't route around it.
