#!/usr/bin/env python3
"""Render every agent-definition file in the roster from its Jinja2 template.

This is what `make roster` and `make roster-check` both call. It replaces
`tools/sync-agent.sh` and the spine-comparison half of `hooks/pre-commit`:
instead of hand-syncing a "spine" between independently-maintained copies and
then checking they didn't drift apart, each (role, tool) combination is now a
single template render, so there is nothing to drift — the committed files
*are* the generator's output, and `make roster-check` just proves that.

Usage:
    python3 roster/render.py            # write every generated file
    python3 roster/render.py --check    # write to a temp dir and diff against
                                         # the committed files; nonzero exit
                                         # and a per-file report on drift

Requires Jinja2 (see roster/requirements.txt for the pinned version).
"""

from __future__ import annotations

import argparse
import difflib
import sys
from pathlib import Path

try:
    import jinja2
except ImportError:
    print(
        "error: Jinja2 is not installed for this Python interpreter.\n"
        "  Install the pinned version: pip install -r roster/requirements.txt\n"
        "  (Jinja2 also ships bundled with Ansible, if that's already on this machine.)",
        file=sys.stderr,
    )
    raise SystemExit(1)

from targets import TARGETS

ROOT = Path(__file__).resolve().parent.parent
TEMPLATES_DIR = Path(__file__).resolve().parent / "templates"


def make_env() -> jinja2.Environment:
    return jinja2.Environment(
        loader=jinja2.FileSystemLoader(str(TEMPLATES_DIR)),
        trim_blocks=True,
        lstrip_blocks=True,
        keep_trailing_newline=True,
        undefined=jinja2.StrictUndefined,
    )


def render_all(env: jinja2.Environment) -> dict[str, str]:
    """Return {output_path: rendered_content} for every target in the roster."""
    rendered = {}
    for target in TARGETS:
        template = env.get_template(f"{target.role}.md.j2")
        rendered[target.output] = template.render(**target.context)
    return rendered


def write_all(rendered: dict[str, str]) -> None:
    for rel_path, content in rendered.items():
        out_path = ROOT / rel_path
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(content, encoding="utf-8")
        print(f"wrote {rel_path}")


def check_all(rendered: dict[str, str]) -> int:
    """Diff rendered output against what's actually committed. Returns the
    number of drifted files (0 == clean)."""
    drifted = 0
    for rel_path, content in rendered.items():
        out_path = ROOT / rel_path
        on_disk = out_path.read_text(encoding="utf-8") if out_path.exists() else None
        if on_disk == content:
            continue
        drifted += 1
        print(f"✖ drift: {rel_path}", file=sys.stderr)
        if on_disk is None:
            print(f"  {rel_path} does not exist on disk yet.", file=sys.stderr)
            continue
        diff = difflib.unified_diff(
            on_disk.splitlines(keepends=True),
            content.splitlines(keepends=True),
            fromfile=f"{rel_path} (on disk)",
            tofile=f"{rel_path} (rendered from roster/templates/)",
        )
        sys.stderr.writelines(diff)
        print(file=sys.stderr)
    return drifted


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check",
        action="store_true",
        help="don't write; fail and report which committed files have drifted from their template",
    )
    args = parser.parse_args()

    env = make_env()
    rendered = render_all(env)

    if args.check:
        drifted = check_all(rendered)
        if drifted:
            names = ", ".join(sorted(rendered))
            print(
                f"\n{drifted} file(s) out of {len(rendered)} drifted from roster/templates/ "
                f"(checked: {names}).\n"
                "Run `make roster` to regenerate, review the diff, and commit it.",
                file=sys.stderr,
            )
            return 1
        print(f"roster-check: {len(rendered)} generated file(s) match roster/templates/")
        return 0

    write_all(rendered)
    return 0


if __name__ == "__main__":
    sys.exit(main())
