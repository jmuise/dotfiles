---
name: claude-config-scoping
description: Use when deciding where a piece of Claude Code configuration belongs — the user-global dotfiles tier (~/.claude, symlinked from ~/code/dotfiles/claude) versus a project's own committed .claude/ directory. Load before adding or editing an agent, skill, hook, rule, CLAUDE.md or settings entry, before seeding a newly provisioned project's .claude/, and whenever a project-level rule looks like it restates something the global tier already covers.
---

# Where Claude Code config belongs

There are two tiers that matter day to day.

- **Global — the Captain's tier.** `~/.claude/`, symlinked from `~/code/dotfiles/claude/` and version-controlled in the dotfiles repo. It describes **the person**: how the Captain works, in every repo, on every machine.
- **Project — the codebase's tier.** A `.claude/` directory committed inside the project's own repo. It describes **this codebase**: things that are true for anyone working on it, including someone who has never seen the Captain's dotfiles.

Getting this wrong is not cosmetic. Global content that should have been project-scoped follows the Captain into repos where it is false; project content that should have been global has to be rewritten, and re-agreed, in every repo they touch.

## The two tests

Apply both, in this order.

1. **Transplant test.** A teammate clones this repo onto a machine with no dotfiles at all. Does the rule still have to hold for their work to be *correct*? If yes → project. If it only makes the work match the Captain's taste → global.
2. **Suitcase test.** The Captain starts an unrelated project tomorrow. Should this come with them? If yes → global.

When both tests say yes, you are looking at a general rule with a project-specific fact stuck to it. Split them: the rule goes global, the fact goes in the project's `CLAUDE.md`. Never put the same thing in both places.

## Reach for the lightest rung

Project-scoped config has its own escalation ladder, and the default answer is the first rung. Stop as soon as one works.

1. **Project `CLAUDE.md`** (repo root, or `.claude/CLAUDE.md`) — the default, and for most projects the only rung ever needed. Facts a newcomer would otherwise have to re-derive: the stack and its pinned versions, the exact build/test/lint invocations, how to bring the stack up, non-obvious invariants, and where the bodies are buried.
2. **`.claude/rules/*.md` with `paths:` frontmatter** — when a rule applies only to part of the tree and would be noise everywhere else (extra scrutiny on payment-handling modules, say). These load on demand against matching paths, so they cost nothing in sessions that never touch those files.
3. **`.claude/settings.json`** — team-shared permissions for this repo's own tooling. Committed and read by everyone. `settings.local.json` is the personal, gitignored counterpart: machine-specific paths, personal experiments, anything user-shaped belongs there and never in the committed file.
4. **`.claude/skills/`** — procedural knowledge tied to this repo's tooling that shouldn't sit in every session's context. Uncommon; most procedures generalise and belong global.
5. **`.claude/hooks/` plus a settings entry** — mechanical enforcement for this repo only. Rare, and subject to the guardrail rule below.
6. **`.claude/agents/`** — a project-scoped role. The heaviest rung and almost always the wrong one; see below.

## Project config is additive and thin, never a copy

The global tier already applies inside every project. Restating any of it project-side is pure duplication, and duplicated rules rot out of sync silently — the copy stays behind while the original improves, and nothing tells you which one an agent read.

- **Never copy a global skill into a project.** Reference it by name; it is already available there.
- **Never fork a global agent just to give it a project fact.** Put the fact in the project's `CLAUDE.md` — every agent working in that repo already reads it.
- **Never restate a global rule "for emphasis".** If it needs emphasis, the global definition is the thing to fix.
- **Keep the project `CLAUDE.md` short** — well under 200 lines. It is in context for every session in that repo, so every line is a recurring cost paid forever.

The reliable smell: you are writing a project rule, and its general form would be just as true in the next repo. That is a global rule wearing a project's clothes.

On layering — `CLAUDE.md` files **concatenate** rather than override, global first and project last. So a project file adds to the Captain's global instructions; it cannot quietly replace them. What it *can* do is contradict them, and a contradiction resolves arbitrarily rather than predictably. If you genuinely need to override a global default for one repo, say so explicitly in the project file so a reader knows it was deliberate.

## Never shadow a global name

A project-scoped definition that shares a `name` with a global one **replaces it outright**, and nothing announces that it happened. This was measured, not assumed: a project `.claude/agents/duty-officer.md` carrying a marker string caused `duty-officer` to appear exactly once in the available agent list, with the project file's description — the global definition was simply gone. Not both, not a warning, not a suffix.

That is a bypass waiting to be used. A repo that ships its own `security-officer` gets reviewed by whatever standard that repo chose, while every brief, every habit and every status report still says "security-officer reviewed it".

- Give project-scoped agents, skills and rules names prefixed with the repo (`pos-payment-review`, never `security-officer` or `reviewer`). Collisions then cannot happen by accident, and a reader can tell which tier a name came from.
- A project-scoped definition must never be a weakened variant of a global reviewer, guard, or protocol.
- When a project defines an agent, check its name against the global roster first. The check is cheap and the failure is silent.

## Guardrails stay global

Under Claude Code, the merge and force-push blocks and the AI-attribution block live in the user tier as `PreToolUse` hooks plus a `permissions.deny` rule. Project config must never weaken them. Under GitHub Copilot CLI the same backstops are only partial and take a different shape — never-merge is prose in the agent definitions, the co-author trailer is the `"includeCoAuthoredBy": false` settings key, and neither hook is ported — so see the README's "Sharing the roster with Kilo and Copilot" section for what actually holds there.

- **Permission rules merge across scopes and a deny wins**, so a project `permissions.allow` that tries to re-permit `gh pr merge` or a force-push should not succeed. Treat any attempt to add one as a signal that something is wrong, not as a setting to tune until it works.
- **Hooks were measured to merge, not replace.** This was worth checking, because the published settings documentation describes most settings as override-by-precedence and lists project scope *above* user scope — which would have meant a project `PreToolUse` entry silently switching the Captain's guards off for everyone in that repo. Observed behaviour is the opposite and the safe one: in a project defining its own `PreToolUse` Bash-matcher hook, the project hook fired **and** the global `block-ai-attribution.sh` still fired and still blocked the commit, identically to a control project with no `.claude/settings.json`.
- That is an observation about one version, not a guarantee. It is also the kind of thing a release could change without anyone noticing, because the failure mode is silent: the guard simply stops firing and nothing reports its absence. So when adding a project hook, re-confirm the global guards still fire in that repo and report the evidence — and never treat "the docs say it merges" as the check.
- Removing, relaxing or shadowing a guardrail is the Captain's decision. It is never an agent's, and never an inference from an ambiguous instruction.

## A committed `.claude/` is executable code shipped with the repo

Project hooks are scripts, and project agents, skills and rules are instructions that steer whoever opens the repo next. All of it arrives by `git clone`. Review changes to a project's `.claude/` with the same suspicion you would apply to a build script — an unfamiliar repo's `.claude/` is a prompt-injection and instruction-substitution surface, not documentation.

**Workspace trust does not cover all of it.** The gate is partial, and knowing exactly where it stops matters:

- **Trust-gated (observed):** `permissions.allow` entries in a project `.claude/settings.json` are discarded in an untrusted directory, with an explicit warning on stderr naming the count of ignored entries.
- **Not gated at all (observed):** project-scoped **agents, skills and `CLAUDE.md` are discovered and active in an untrusted directory**, with no prompt. That includes an agent that shadows a global one by name. So the dangerous case — a cloned repo silently substituting its own reviewer, or appending instructions to every session in that tree — happens *before* anyone is asked to trust anything.
- **Unresolved:** whether project-defined *hooks* fire in an untrusted workspace. Two separate probes disagreed: one saw a project hook never fire and attributed that to the trust gate, another saw the project hook fire and log. Treat it as unsettled and verify per repo rather than relying on either answer.

What held in **every** probe, trusted or not, is that the user-global guards fired and blocked. That is the property worth re-confirming whenever this stack changes; it is not one to assume.

Practical consequence: reading a repo's `.claude/` should be part of looking at an unfamiliar codebase, in the same breath as reading its build scripts, and before doing real work in it.

## Seeding a newly provisioned project

A fresh project gets exactly one thing by default: a thin project `CLAUDE.md`, written **after** containerization so it can document the commands that actually exist rather than the ones someone intended.

Do **not** pre-create empty `agents/`, `skills/`, `hooks/` or `rules/` directories. An empty directory is an invitation to fill it, and the easiest way to fill it is to copy global content down — which is the exact drift this convention exists to prevent. Add the higher rungs when a concrete need appears, not in anticipation of one.

`/init` is an interactive built-in command and cannot be driven non-interactively, so a provisioning agent should not try to shell out to it. Write the file directly from what detecting the stack already taught you; that is both cheaper and more accurate than a generated summary.

## Where this leaves the two repos

- `~/code/dotfiles/claude/` — global agents, skills, hooks, `settings.json`, `CLAUDE.md`. Committed to dotfiles, subject to the dotfiles commit protocol and its mandatory independent security review.
- `<project>/.claude/` — that project's own `CLAUDE.md`, and only the higher rungs it has actually earned. Committed to the project repo through its normal PR flow, and reviewed like code.
