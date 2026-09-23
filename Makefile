# Top-level entry points for this repo. Mirrored in .vscode/tasks.json —
# keep both in sync when a target here changes.

.PHONY: roster roster-check

# Regenerate every agent-definition file in the roster (claude/agents/,
# kilo/.kilo/agents/, copilot/agents/) from roster/templates/*.md.j2. This is
# the fix for drift reported by `make roster-check`: edit the template, run
# this, review the diff, commit it.
roster:
	python3 roster/render.py

# CI's drift guard (job `agent-spine-drift`): regenerate into memory and
# diff against what's actually committed, without touching the working
# tree. Fails with a per-file diff naming exactly what drifted — from an
# edited generated file, an edited template that was never regenerated, or
# a template edited on one machine and not re-run on another.
roster-check:
	python3 roster/render.py --check
