---
name: dotfiles-commit-protocol
description: Use whenever staging, committing, or pushing a change to the dotfiles repo itself (~/code/dotfiles) — as opposed to an ordinary project repo. Load before running git add/commit/push there, or when delegating or receiving a task that edits shell config, git config, secrets/, or global Claude/Kilo config under this repo.
---

# Dotfiles commit protocol

The dotfiles repo is the Captain's own machine config: shell init, credential-helper wiring, a `secrets/` directory, global agent/hook definitions. That makes it exactly where a leaked token, key, or credential would do the most damage and be hardest to expunge from history — and exactly where an accidental commit sweeps someone's in-progress, unrelated edit into a change they never reviewed. The repo deliberately skips the PR/issue flow that would normally catch this, so the discipline has to be manual instead.

## Rules, in order

1. **Stage only the specific files you changed.** Never `git add -A`, and never sweep the Captain's (or a concurrently-running worker's) unrelated in-progress edits into a commit whose message you wrote. If you're not sure whether an untracked or modified file is yours, leave it out and say so.
2. **Independent security review before commit — no exceptions.** Every dotfiles change goes through a `security-officer` review before it's committed or pushed, including changes you're confident about, including changes you made yourself. Wait for the verdict; don't commit speculatively and fix up after.
3. **Push only if the branch is clean and fast-forwards.** If it doesn't, commit locally and report the divergence rather than rebasing or stashing over uncommitted work that isn't yours.
4. **No AI-attribution or promotional lines** — no `Co-Authored-By: Claude ...` trailer, no "Generated with Claude Code" footer, no claude.com link, in the commit message or in any file the commit touches. (`hooks/block-ai-attribution.sh` catches this mechanically too, but treat that as a backstop, not a reason to skip checking your own text.)
5. **Report every dotfiles commit with its SHA and rationale.** A commit with no paper trail defeats the point of skipping the PR flow.

## Two carve-outs always need the Captain's explicit words first

Two categories require confirmation from the Captain before you touch them at all, even mid-task, even if the change seems obviously correct: anything that would loosen an absolute/hard-boundary rule (e.g. the never-merge guard), and any change to an agent's own or another agent's tool grant or permission/authority configuration. Widening authority is never something to infer from an ambiguous cue — if a brief implies you should, that's a stop-and-confirm, not a green light.
