#!/usr/bin/env bash
# Tests for profile/profile.sh -- the same corpus as test_profile.py, so the
# two readers cannot drift apart on an edge case.
#
# Run directly: `bash profile/test_profile.sh`. Exits non-zero if any case
# fails. `profile/run-tests.sh` runs this plus the Python suite.
set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
READER="$SCRIPT_DIR/profile.sh"

pass=0
fail=0
ok()  { pass=$((pass + 1)); printf 'ok   - %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL - %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"; }

# Run the reader as a standalone script against a freshly built config dir.
#   $1 = mode, $2 = payload (for RAW/RAWNONL/BYTES)
# Sets OUT, ERR, RC.
resolve_case() {
  local mode="$1" payload="${2-}"
  local tmp cfg pf
  tmp=$(mktemp -d)
  cfg="$tmp/.config"
  mkdir -p "$cfg/dotfiles"
  pf="$cfg/dotfiles/profile"
  case "$mode" in
    ABSENT)  : ;;
    DIR)     rm -f "$pf"; mkdir "$pf" ;;
    BROKEN)  ln -s "$tmp/does-not-exist" "$pf" ;;
    LINKFILE)
      printf 'inline\n' > "$tmp/real-profile"
      ln -s "$tmp/real-profile" "$pf" ;;
    LINKANCESTOR)
      rm -rf "$cfg"
      mkdir -p "$tmp/real-config/dotfiles"
      printf 'bare\n' > "$tmp/real-config/dotfiles/profile"
      ln -s "$tmp/real-config" "$cfg" ;;
    RAW)      printf '%b' "$payload" > "$pf" ;;   # interprets \n \t \r \xNN
    RAWNONL)  printf '%s' "$payload" > "$pf" ;;   # exact bytes, no newline
    *) echo "unknown mode $mode" >&2; exit 99 ;;
  esac
  OUT=$(HOME="$tmp" XDG_CONFIG_HOME="$cfg" bash "$READER" 2>"$tmp/err"); RC=$?
  ERR=$(cat "$tmp/err")
  rm -rf "$tmp"
}

assert_value() { # desc expected
  if [ "$RC" -eq 0 ] && [ "$OUT" = "$2" ] && [ -z "$ERR" ]; then
    ok "$1"
  else
    bad "$1" "rc=0 out='$2' err=''" "rc=$RC out='$OUT' err='$ERR'"
  fi
}

assert_error() { # desc
  if [ "$RC" -eq 2 ] && [ -z "$OUT" ] && [ -n "$ERR" ]; then
    ok "$1"
  else
    bad "$1" "rc=2 out='' err=<nonempty>" "rc=$RC out='$OUT' err='$ERR'"
  fi
}

# ---- rule 1: absent -> agentic ------------------------------------------
resolve_case ABSENT;            assert_value "absent file resolves to agentic" "agentic"

# ---- rule 2: the three canonical values --------------------------------
resolve_case RAW "bare";        assert_value "value 'bare'" "bare"
resolve_case RAW "inline";      assert_value "value 'inline'" "inline"
resolve_case RAW "agentic";     assert_value "value 'agentic'" "agentic"

# ---- rule 2: surrounding whitespace is trimmed -----------------------
resolve_case RAW  'agentic\n';        assert_value "trailing newline trimmed" "agentic"
resolve_case RAW  'agentic\n\n\n';    assert_value "many trailing newlines trimmed" "agentic"
resolve_case RAWNONL '  inline  ';    assert_value "leading+trailing spaces trimmed" "inline"
resolve_case RAW  '\t\r\nbare\r\n\t'; assert_value "tabs and CRLF trimmed" "bare"

# ---- rule 3: empty / whitespace-only ---------------------------------
resolve_case RAWNONL '';             assert_error "empty file errors"
resolve_case RAW  '   \n\t\n';       assert_error "whitespace-only file errors"

# ---- rule 4: more than one token ------------------------------------
resolve_case RAWNONL 'agentic bare'; assert_error "two words error"
resolve_case RAW  'agentic\nbare\n'; assert_error "second line error"
resolve_case RAWNONL 'agen tic';     assert_error "internal space error"

# ---- rule 5: unknown words ----------------------------------------
for w in full none agent on yes default; do
  resolve_case RAWNONL "$w";         assert_error "unknown word '$w' errors"
done

# ---- rule 5: case sensitivity -------------------------------------
for w in AGENTIC Agentic BARE Bare Inline INLINE; do
  resolve_case RAWNONL "$w";         assert_error "wrong-case '$w' errors"
done

# ---- rule 6: not a regular file ---------------------------------
resolve_case DIR;                    assert_error "directory at path errors"
resolve_case BROKEN;                 assert_error "broken symlink errors"

# ---- rule 7: invalid UTF-8 (bash: fails to match any token -> error) --
resolve_case RAW '\xff\xfe\xfa';     assert_error "invalid UTF-8 errors"

# ---- symlink in ancestry: read warns but still resolves -----------
resolve_case LINKFILE
if [ "$RC" -eq 0 ] && [ "$OUT" = "inline" ] && printf '%s' "$ERR" | grep -q "is a symlink"; then
  ok "symlinked file: warns on stderr, still resolves"
else
  bad "symlinked file: warns on stderr, still resolves" "rc=0 out=inline err~=symlink" "rc=$RC out='$OUT' err='$ERR'"
fi

resolve_case LINKANCESTOR
if [ "$RC" -eq 0 ] && [ "$OUT" = "bare" ] && printf '%s' "$ERR" | grep -q "is a symlink"; then
  ok "symlinked ancestor: warns on stderr, still resolves"
else
  bad "symlinked ancestor: warns on stderr, still resolves" "rc=0 out=bare err~=symlink" "rc=$RC out='$OUT' err='$ERR'"
fi

# ---- dotfiles_profile_path honours XDG_CONFIG_HOME ---------------
got=$(XDG_CONFIG_HOME=/somewhere/cfg bash -c ". '$READER'; dotfiles_profile_path")
if [ "$got" = "/somewhere/cfg/dotfiles/profile" ]; then
  ok "dotfiles_profile_path uses XDG_CONFIG_HOME"
else
  bad "dotfiles_profile_path uses XDG_CONFIG_HOME" "/somewhere/cfg/dotfiles/profile" "$got"
fi

# ---- dotfiles_profile_at_least: nesting ----------------------------
at_least_case() { # value required -> RC
  local tmp
  tmp=$(mktemp -d)
  mkdir -p "$tmp/.config/dotfiles"
  printf '%s\n' "$1" > "$tmp/.config/dotfiles/profile"
  # shellcheck source=/dev/null  # $READER is resolved at runtime
  # shellcheck disable=SC2030,SC2031  # env vars scoped to this subshell on purpose
  ( export HOME="$tmp" XDG_CONFIG_HOME="$tmp/.config"; . "$READER"; dotfiles_profile_at_least "$2" )
  RC=$?
  rm -rf "$tmp"
}
assert_rc() { # desc expected_rc
  if [ "$RC" -eq "$2" ]; then ok "$1"; else bad "$1" "rc=$2" "rc=$RC"; fi
}

at_least_case bare    bare;    assert_rc "at_least: bare >= bare" 0
at_least_case inline  bare;    assert_rc "at_least: inline >= bare" 0
at_least_case agentic bare;    assert_rc "at_least: agentic >= bare" 0
at_least_case inline  inline;  assert_rc "at_least: inline >= inline" 0
at_least_case agentic inline;  assert_rc "at_least: agentic >= inline" 0
at_least_case bare    inline;  assert_rc "at_least: bare < inline" 1
at_least_case bare    agentic; assert_rc "at_least: bare < agentic" 1
at_least_case inline  agentic; assert_rc "at_least: inline < agentic" 1
at_least_case agentic full;    assert_rc "at_least: bad required name -> rc 2" 2
at_least_case nonsense bare;   assert_rc "at_least: broken profile file -> rc 2" 2

# ---- summary ----------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
