#!/usr/bin/env bash
# Reader for the dotfiles `profile` file contract.
#
# Source this file to get the functions below, or run it directly
# (`bash profile/profile.sh`) as a shorthand for `dotfiles_profile`.
# Safe to source from bash or zsh; sourcing only defines functions.
#
# The single source of truth is:
#     ${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/profile
# holding exactly one of: bare  <  inline  <  agentic   (nested capabilities)
#
#   file absent            -> prints "agentic" (preserves old behaviour)
#   file empty / >1 token / unknown word / not a regular file
#                          -> message on stderr, return 2 (never falls back)
#   value is case-sensitive lowercase; surrounding whitespace is trimmed
#
# This is the *shell* implementation of the contract. The Python
# implementation (profile/profile.py) has identical semantics and is what
# Ansible and the linker use; profile/test_profile.sh checks this one against
# the same corpus. See profile/README.md for the full contract.

# --- internals --------------------------------------------------------------

_dotfiles_profile_rank() {
  case "$1" in
    bare)    printf '0\n' ;;
    inline)  printf '1\n' ;;
    agentic) printf '2\n' ;;
    *)       return 1 ;;
  esac
}

# Read path only: a symlinked file or ancestor cannot turn a read into an
# arbitrary-file overwrite, and users legitimately symlink ~/.config. So warn
# and carry on rather than failing. (The *write* path in profile.py skips
# instead -- see issue #29.)
_dotfiles_profile_warn_symlinks() {
  local file="$1" dir parent home
  home="${HOME%/}"
  [ -L "$file" ] && printf 'profile: %s is a symlink; reading the profile through it anyway\n' "$file" >&2
  dir=$(dirname -- "$file")
  while : ; do
    [ -L "$dir" ] && printf 'profile: %s is a symlink; reading the profile through it anyway\n' "$dir" >&2
    [ "$dir" = "$home" ] && break
    [ "$dir" = "/" ] && break
    parent=$(dirname -- "$dir")
    [ "$parent" = "$dir" ] && break
    dir="$parent"
  done
}

# --- public API -----------------------------------------------------------

dotfiles_profile_path() {
  printf '%s/dotfiles/profile\n' "${XDG_CONFIG_HOME:-$HOME/.config}"
}

# Print the resolved profile name on stdout (return 0), or print a reason on
# stderr and return 2.
dotfiles_profile() {
  # Byte-oriented, locale-independent matching for the trim and the
  # whitespace check -- must agree with profile.py's ASCII-only set.
  local LC_ALL=C
  local file raw value
  file=$(dotfiles_profile_path)

  # Rule 1: genuinely absent (and not a broken symlink) -> default.
  if [ ! -L "$file" ] && [ ! -e "$file" ]; then
    printf 'agentic\n'
    return 0
  fi

  _dotfiles_profile_warn_symlinks "$file"

  # Rule 6: must be a regular file. `test -f` follows symlinks, so this also
  # rejects a broken symlink, a directory, a FIFO, a socket.
  if [ ! -f "$file" ]; then
    printf 'profile: %s is not a regular file\n' "$file" >&2
    return 2
  fi

  # $(<file) reads the bytes and strips *only* trailing newlines.
  if ! raw=$(<"$file"); then
    printf 'profile: cannot read %s\n' "$file" >&2
    return 2
  fi

  # Trim leading, then trailing, ASCII whitespace ([:space:] under LC_ALL=C
  # is space, tab, \n, \r, \f, \v).
  value="${raw#"${raw%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"

  # Rule 3: empty / whitespace-only.
  if [ -z "$value" ]; then
    printf 'profile: %s is empty\n' "$file" >&2
    return 2
  fi

  # Rule 4: exactly one token -- no internal whitespace or newlines.
  case "$value" in
    *[[:space:]]*)
      printf 'profile: %s contains more than one token; it must hold exactly one profile name\n' "$file" >&2
      return 2
      ;;
  esac

  # Rules 2 & 5: known value, case-sensitive. `[` compares bytes, so invalid
  # UTF-8 simply fails to match any token and lands in the error branch --
  # same "this is not a valid profile" outcome as profile.py's explicit
  # UnicodeDecodeError path.
  if [ "$value" = bare ] || [ "$value" = inline ] || [ "$value" = agentic ]; then
    printf '%s\n' "$value"
    return 0
  fi

  printf 'profile: unknown profile %s in %s; valid values are bare, inline, agentic\n' "$value" "$file" >&2
  return 2
}

# Return 0 if the active profile is at or above <required> in the nesting
# order, 1 if it is below, 2 on a read error or a bad argument.
dotfiles_profile_at_least() {
  local required="$1" active req_rank act_rank
  if ! req_rank=$(_dotfiles_profile_rank "$required"); then
    printf 'profile: not a profile name: %s\n' "$required" >&2
    return 2
  fi
  if ! active=$(dotfiles_profile); then
    return 2
  fi
  act_rank=$(_dotfiles_profile_rank "$active")
  [ "$act_rank" -ge "$req_rank" ]
}

# Executed directly (not sourced)? Behave like `dotfiles_profile`. This test
# is bash-specific; when sourced from bash or zsh it is simply skipped and
# only the functions are defined.
if [ -n "${BASH_SOURCE:-}" ] && [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  dotfiles_profile "$@"
  exit $?
fi
