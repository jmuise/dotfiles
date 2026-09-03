#!/usr/bin/env python3
"""Reader for the dotfiles ``profile`` file contract.

The single source of truth is the file

    ${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/profile

which holds exactly one profile name. See ``profile/README.md`` for the full
contract; the short version:

* ``bare`` (rank 0) ⊂ ``inline`` (rank 1) ⊂ ``agentic`` (rank 2)
* file **absent**            -> resolves to ``agentic`` (preserves old behaviour)
* file empty / multi-token / unknown word / not-a-regular-file / bad UTF-8
  -> :class:`ProfileError` (never silently falls back to ``agentic``)
* value is case-sensitive lowercase; surrounding whitespace is trimmed

This module is imported by the Python linker and executed as a script by
Ansible (``python3 profile/profile.py`` -> profile name on stdout, exit 0;
error -> stderr, exit 2). It is the only Python implementation of the
contract; do not add a second parser elsewhere.
"""

from __future__ import annotations

import os
import sys
import tempfile
from pathlib import Path
from typing import Iterable, Optional

__all__ = [
    "PROFILES",
    "DEFAULT_PROFILE",
    "PROFILE_RANK",
    "ProfileError",
    "profile_path",
    "resolve_profile",
    "profile_at_least",
    "write_profile",
]

# Canonical, ordered from least to most capable. Index == rank.
PROFILES = ("bare", "inline", "agentic")
DEFAULT_PROFILE = "agentic"
PROFILE_RANK = {name: rank for rank, name in enumerate(PROFILES)}

# ASCII whitespace only, matching C-locale [:space:] in the shell reader:
# space, tab, newline, carriage return, form feed, vertical tab.
_ASCII_WS = " \t\n\r\f\v"


class ProfileError(ValueError):
    """The profile file exists but its contents are not a valid profile.

    Raised for empty / whitespace-only files, multi-token or multi-line
    contents, unknown words, wrong case, non-regular files and invalid
    UTF-8. Never raised for an absent file (that resolves to
    :data:`DEFAULT_PROFILE`).
    """


def profile_path(config_home: Optional[os.PathLike | str] = None) -> Path:
    """Return the path to the profile file.

    ``config_home`` overrides ``$XDG_CONFIG_HOME`` (an empty env value is
    treated as unset, matching the shell's ``${XDG_CONFIG_HOME:-...}``).
    """
    if config_home is None:
        config_home = os.environ.get("XDG_CONFIG_HOME") or (Path.home() / ".config")
    return Path(config_home) / "dotfiles" / "profile"


def _ancestors_to_home(path: Path, home: Optional[Path] = None) -> Iterable[Path]:
    """Yield ``path`` then each parent, stopping at (and including) ``$HOME``.

    If ``path`` is not under ``$HOME`` the walk stops at the filesystem root.
    Used for the issue-#29 symlink-ancestry check. Path components are
    compared, never ``resolve()``d -- resolving would follow the very
    symlinks this walk exists to detect.
    """
    home_abs = (Path(home) if home is not None else Path.home())
    if not home_abs.is_absolute():
        home_abs = Path.cwd() / home_abs
    current = path if path.is_absolute() else Path.cwd() / path
    while True:
        yield current
        parent = current.parent
        if current == home_abs or parent == current:
            break
        current = parent


def _symlink_in_ancestry(path: Path, home: Optional[Path] = None) -> Optional[Path]:
    """Return the first symlink at ``path`` or any ancestor up to ``$HOME``.

    ``None`` if the ancestry is clean.
    """
    for component in _ancestors_to_home(path, home=home):
        try:
            if component.is_symlink():
                return component
        except OSError:
            # An unreadable component is not, by itself, the symlink attack
            # this guards against; let the actual read/write surface it.
            continue
    return None


def _warn(msg: str) -> None:
    print(f"profile: {msg}", file=sys.stderr)


def resolve_profile(
    path: Optional[os.PathLike | str] = None,
    *,
    config_home: Optional[os.PathLike | str] = None,
    home: Optional[os.PathLike | str] = None,
) -> str:
    """Resolve the active profile name.

    Returns one of :data:`PROFILES`. Returns :data:`DEFAULT_PROFILE` when the
    file is absent. Raises :class:`ProfileError` for any present-but-invalid
    file (see the class docstring and ``profile/README.md``).

    A symlink at the file or any ancestor up to ``$HOME`` is *not* an error
    for a read -- it emits a one-line stderr warning and resolution
    continues.
    """
    p = Path(path) if path is not None else profile_path(config_home)
    home_p = Path(home) if home is not None else None

    is_symlink = False
    try:
        is_symlink = p.is_symlink()
    except OSError:
        is_symlink = False

    # Rule 1: genuinely absent (and not a broken symlink) -> default.
    if not is_symlink and not p.exists():
        return DEFAULT_PROFILE

    offender = _symlink_in_ancestry(p, home=home_p)
    if offender is not None:
        _warn(f"{offender} is a symlink; reading the profile through it anyway")

    # Rule 6: must be a regular file (this also rejects broken symlinks,
    # directories, FIFOs, sockets).
    if not p.is_file():
        raise ProfileError(f"{p} is not a regular file")

    # Rule 7: valid UTF-8.
    try:
        raw = p.read_text(encoding="utf-8")
    except UnicodeDecodeError as exc:
        raise ProfileError(f"{p} is not valid UTF-8: {exc}") from exc

    value = raw.strip(_ASCII_WS)

    # Rule 3: empty / whitespace-only.
    if not value:
        raise ProfileError(f"{p} is empty")

    # Rule 4: exactly one token, no internal whitespace / newlines.
    if any(ch in _ASCII_WS for ch in value):
        raise ProfileError(
            f"{p} contains more than one token ({value!r}); it must hold exactly one profile name"
        )

    # Rule 5: known, case-sensitive.
    if value not in PROFILE_RANK:
        raise ProfileError(
            f"unknown profile {value!r} in {p}; valid values are {', '.join(PROFILES)}"
        )

    # Rule 2.
    return value


def profile_at_least(current: str, required: str) -> bool:
    """True iff ``current`` is at or above ``required`` in the nesting order.

    Both arguments must be valid profile names; anything else is a
    programming error and raises :class:`ProfileError`.
    """
    try:
        return PROFILE_RANK[current] >= PROFILE_RANK[required]
    except KeyError as exc:
        raise ProfileError(f"not a profile name: {exc.args[0]!r}") from None


def write_profile(
    name: str,
    path: Optional[os.PathLike | str] = None,
    *,
    config_home: Optional[os.PathLike | str] = None,
    home: Optional[os.PathLike | str] = None,
) -> bool:
    """Write ``name`` to the profile file, atomically.

    Carries the issue-#29 symlink-ancestry check: before any ``mkdir`` or
    write, every path component from the file's parent up to and including
    ``$HOME`` (plus the file path itself) is checked with ``is_symlink()``.
    If any is a symlink this **warns on stderr and skips the write**,
    returning ``False`` -- it does not raise and does not abort the caller.

    An invalid ``name`` raises :class:`ProfileError` before touching the
    filesystem. Returns ``True`` on a successful write.
    """
    if name not in PROFILE_RANK:
        raise ProfileError(
            f"refusing to write unknown profile {name!r}; valid values are {', '.join(PROFILES)}"
        )

    p = Path(path) if path is not None else profile_path(config_home)
    home_p = Path(home) if home is not None else None

    offender = _symlink_in_ancestry(p, home=home_p)
    if offender is not None:
        _warn(
            f"{offender} is a symlink -- refusing to write the profile through it; "
            f"profile file left unchanged"
        )
        return False

    p.parent.mkdir(parents=True, exist_ok=True)

    # Atomic replace so a concurrent reader never sees a partial value.
    fd, tmp_name = tempfile.mkstemp(dir=str(p.parent), prefix=".profile.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(f"{name}\n")
        os.replace(tmp_name, p)
    except BaseException:
        try:
            os.unlink(tmp_name)
        except OSError:
            pass
        raise
    return True


def _main(argv: list[str]) -> int:
    at_least = None
    args = list(argv)
    if args and args[0] == "--at-least":
        if len(args) < 2:
            print("profile: --at-least needs a profile name", file=sys.stderr)
            return 2
        at_least = args[1]
        args = args[2:]
    if args:
        print(f"profile: unexpected argument {args[0]!r}", file=sys.stderr)
        return 2

    try:
        active = resolve_profile()
    except ProfileError as exc:
        print(f"profile: {exc}", file=sys.stderr)
        return 2

    if at_least is not None:
        try:
            ok = profile_at_least(active, at_least)
        except ProfileError as exc:
            print(f"profile: {exc}", file=sys.stderr)
            return 2
        return 0 if ok else 1

    print(active)
    return 0


if __name__ == "__main__":
    sys.exit(_main(sys.argv[1:]))
