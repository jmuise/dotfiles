"""Registry of every generated agent-definition file.

This is the roster: one entry per (role, tool) combination that actually
ships. Adding a new tool target for an existing role — the thing #8 defers —
is meant to be exactly one new `Target` entry plus whatever template branch
that tool needs; nothing else in `render.py` should need to change.

Each `Target` carries everything `render.py` needs to produce one output
file: which template renders it, where it's written, and the per-tool
context (`tool` id plus role-specific variables like `project_context_file`)
that the template branches on. Frontmatter is part of the template body —
see the per-role .md.j2 files — so it is not modeled here.
"""

from __future__ import annotations

from dataclasses import dataclass, field


@dataclass(frozen=True)
class Target:
    role: str  # template file is roster/templates/<role>.md.j2
    tool: str  # "claude" | "kilo" | "copilot" — the context variable templates branch on
    output: str  # path relative to the repo root
    context: dict = field(default_factory=dict)


# Per-tool project-config conventions (#20): the file a project's own
# instructions live in, and the directory a project-scoped agent/skill/hook
# lives under. Confirmed against each CLI's own runtime rather than assumed:
#   - Claude Code: `CLAUDE.md` + `.claude/` — documented throughout this repo.
#   - Kilo: `AGENTS.md`, discovered by walking up from cwd to the project
#     root (confirmed in the shipped `@kilocode/cli` runtime's own string
#     table: `H.up({targets:["AGENTS.md"], start:f, stop:D})`). Project
#     agents live at `.kilo/agent/*.md` (`.kilo/agents/` — plural — also
#     loads, per the same runtime's own environment-banner string: "Project
#     config: .kilo/command/*.md, .kilo/agent/*.md, kilo.json, AGENTS.md.
#     Put new commands and agents in .kilo/.").
#   - Copilot: `.github/copilot-instructions.md` + `.github/` — confirmed in
#     the shipped `@github/copilot` runtime's own string table ("Read
#     `.github/copilot-instructions.md` to understand what instructions
#     already exist.", "check `.github/skills/` and `.github/agents/`").
#
# `project_agents_dir`/`project_agents_dir_bare` (order 7's own mentions) and
# `project_context_file`/`project_config_dir` (order 1a's and order 11's) are
# kept as separate keys, even though they name the same convention, because
# they were fixed at different times: Copilot's order-7 text was already
# adapted to `.github/agents/` when its roster was hand-translated, while
# order 11 kept literal Claude paths in every copy until #20. Collapsing them
# into one key is tempting but would be premature here.
PROJECT_CONVENTIONS = {
    "claude": {
        "project_context_file": "CLAUDE.md",
        "project_config_dir": ".claude/",
        "project_agents_dir": ".claude/agents/",
        "project_agents_dir_bare": ".claude/",
        "agent_file_ext": ".md",
    },
    "kilo": {
        "project_context_file": "CLAUDE.md",
        "project_config_dir": ".claude/",
        "project_agents_dir": ".claude/agents/",
        "project_agents_dir_bare": ".claude/",
        "agent_file_ext": ".md",
    },
    "copilot": {
        "project_context_file": "CLAUDE.md",
        "project_config_dir": ".claude/",
        "project_agents_dir": ".github/agents/",
        "project_agents_dir_bare": ".github/",
        "agent_file_ext": ".agent.md",
    },
}


def _ctx(tool: str, **extra) -> dict:
    ctx = {"tool": tool, **PROJECT_CONVENTIONS[tool]}
    ctx.update(extra)
    return ctx


TARGETS: list[Target] = [
    # number-one — the only role with all three tool targets today.
    Target("number-one", "claude", "claude/agents/number-one.md", _ctx("claude")),
    Target("number-one", "kilo", "kilo/.kilo/agents/number-one.md", _ctx("kilo")),
    Target("number-one", "copilot", "copilot/agents/number-one.agent.md", _ctx("copilot")),
    # chief-engineer — Claude-only. Copilot has no equivalent: fresh-project
    # provisioning needs the devcontainer guard's by-name exemption, which
    # Copilot's hook payload cannot carry (see number-one's order 1 and
    # README's "Sharing the roster" section). `devcontainer-reviewer` below
    # is a distinct role, not a per-tool rendering of this one.
    Target("chief-engineer", "claude", "claude/agents/chief-engineer.md", _ctx("claude")),
    # devcontainer-reviewer — Copilot-only counterpart to the read-only
    # sign-off half of chief-engineer's job. See #8: porting a real
    # provisioning agent to Kilo/Copilot is out of scope here.
    Target(
        "devcontainer-reviewer",
        "copilot",
        "copilot/agents/devcontainer-reviewer.agent.md",
        _ctx("copilot"),
    ),
    # duty-officer, implementation-engineer, security-officer — Claude and
    # Copilot both ship these; Kilo has neither yet (#8).
    Target("duty-officer", "claude", "claude/agents/duty-officer.md", _ctx("claude")),
    Target("duty-officer", "copilot", "copilot/agents/duty-officer.agent.md", _ctx("copilot")),
    Target(
        "implementation-engineer",
        "claude",
        "claude/agents/implementation-engineer.md",
        _ctx("claude"),
    ),
    Target(
        "implementation-engineer",
        "copilot",
        "copilot/agents/implementation-engineer.agent.md",
        _ctx("copilot"),
    ),
    Target("security-officer", "claude", "claude/agents/security-officer.md", _ctx("claude")),
    Target(
        "security-officer",
        "copilot",
        "copilot/agents/security-officer.agent.md",
        _ctx("copilot"),
    ),
]
