#!/usr/bin/env bash
# GitHub Copilot CLI preToolUse hook -- ports claude/hooks/require-devcontainer.sh's
# enforcement to Copilot. This file is a THIN SHIM and must stay one: it maps
# Copilot's tool-call shape onto the JSON payload require-devcontainer.sh already
# expects on stdin, spawns that script, and defers to its exit code for every
# decision. It holds no git/marker/container-detection/allowlist logic of its own,
# and it must never grow any -- see the claude-config-scoping skill and the Kilo
# port at kilo/plugin/require-devcontainer.ts for why a second implementation of
# the same rule is a standing anti-pattern in this repo. Two copies always drift,
# and a drift here means either spurious blocks or -- far worse -- a silent bypass
# of the one guard that keeps agent work off the bare host.
#
# Wired up via copilot/settings.json's hooks.preToolUse matcher, which install.py
# symlinks to ~/.copilot/settings.json (and this directory to ~/.copilot/hooks).
# User-level hooks live in settings.json, NOT config.json: putting them in
# config.json appears to work exactly once, then the CLI migrates them out, logs
# `[WARNING] Settings migration: "hooks" differs...` and deletes them -- after
# which the guard is silently gone. config.json's own header says as much ("User
# settings belong in settings.json. This file is managed automatically.").
#
# NO EXEMPTION EXISTS HERE, AND NOTHING SHIPPED NEEDS ONE. `agent_type` below is
# hardcoded to "copilot", and the bash script exempts exactly one value --
# "chief-engineer", the Claude Code host-bootstrap role. So under Copilot the
# exemption path is unreachable by construction. That is the intended permanent
# state, not an interim gap waiting on a fix.
#
# It has to be unreachable, because there is no honest way to grant it. Copilot's
# preToolUse payload carries NO agent identity at all (sessionId, timestamp, cwd,
# toolName, toolArgs -- that is the whole of it), so this shim cannot tell one
# agent's calls from another's. The only "exemption" available would be a blanket
# one keyed off nothing, which is not an exemption, it is switching the guard off.
#
# The resolution is scope, not a workaround: the Copilot agent roster deliberately
# ships no agent that would need the exemption. Host bootstrap necessarily happens
# before a container exists, so it runs under Claude Code, whose hook receives a
# real agent identity and exempts chief-engineer by name. copilot/agents/ therefore
# carries review, implementation and orchestration roles only, and
# copilot/agents/number-one.agent.md states plainly that fresh-project provisioning
# is not a capability this roster has. Nothing here is one hardcoded string away
# from working; there is simply no Copilot caller for that string to match.
#
# If Copilot ever grows a hook payload identifying the calling agent -- or the
# Captain decides Copilot needs its own provisioning path onto the host -- that is
# a decision for the Captain, not a default this shim assumes. Do not invent an
# exemption here in the meantime. The Kilo port sits in the same position and is
# resolved the same way: it hardcodes agent_type to "kilo" and ships no
# provisioning role either.
#
# COMPENSATING FOR A REAL REGRESSION -- stderr is DISCARDED. Claude Code hands the
# blocked agent a hook's stderr verbatim; Copilot throws it away and shows only
# `Denied by preToolUse hook: hook exited with code 2`. require-devcontainer.sh
# explains itself at length on stderr (which project, why, and to load the
# `devcontainer-first` skill), and all of that would be lost. So this shim captures
# the guard's stderr and re-emits it on stdout as Copilot's own flat decision JSON:
# {"permissionDecision":"deny","permissionDecisionReason":"..."}. The keys must be
# FLAT. Claude Code's nested
# {"hookSpecificOutput":{"hookEventName":...,"permissionDecision":"deny"}} wrapper
# is NOT understood by Copilot and was observed to ALLOW the call straight through
# -- do not copy Claude's shape here. Verified: exit 2 *plus* that JSON denies, and
# the JSON's reason wins over the generic message, so this emits both the JSON and
# exit 2 -- fail-closed semantics plus a readable explanation.
#
# THE MODEL-FAMILY TOOL-NAME TRAP. Copilot's file-mutation tool depends on which
# model is driving: claude-sonnet-5 and gemini-3.5-flash emit `create` + `edit`,
# while gpt-5.4 and gpt-5.3-codex emit `apply_patch` instead. `bash` is the shell
# tool for every family. A tool map that covers only one family silently stops
# firing the moment the Captain switches models -- which is a fail-open, not a
# visible breakage. This is precisely why copilot/settings.json's matcher is now
# `.*` and NOT a name allowlist: an exact-name matcher has to be complete forever,
# against a packed binary whose tool roster cannot be enumerated, and any name it
# misses gets no hook at all with nothing to notice. Widening the matcher moves the
# whole classification decision into the `case` statement below -- testable code
# under our control, where an unrecognised name is a visible miss rather than a
# silent one. THAT LAST CLAIM WAS ASPIRATIONAL UNTIL ISSUE #12: the `case` used
# to end `*) exit 0 ;;`, which made an unrecognised name a SILENT allow, not a
# visible miss -- see the DENY BY DEFAULT note at the `case` itself for the fix
# and the reproduced bypass. The cost is that this hook now runs on EVERY tool
# call, so the out-of-scope fast path below is on the session's hot path and is
# deliberately kept to a single jq spawn. `str_replace_editor` is mapped
# defensively: it was never observed firing, but the shipped runtime does carry
# its tool schema, and that schema names its target parameter `path` -- the
# same key `create`/`edit` use, which the branch below already reads. MCP tools
# remain out of reach no matter what the matcher says: they fire a separate
# `preMcpToolCall` event that a preToolUse matcher never sees. That is out of
# scope here and deliberately not worked around.
#
# THE INVALID-MATCHER HAZARD lives in copilot/settings.json, not here, but it is
# the same failure class and worth stating once: matchers are compiled as
# `^(?:PATTERN)$` (Rust regex, full match), and an invalid one makes the CLI log
# `Invalid matcher regex ... hook will be skipped` and run nothing at all. Unknown
# keys inside a hook entry are likewise accepted with no warning. Both are
# fail-open paths that no amount of care in this file can compensate for, so any
# edit to the matcher must be re-verified by observing an actual block.
#
# THE TIMEOUT FAILS OPEN. CONFIRMED IN THE SHIPPED RUNTIME, NOT INFERRED, AND THERE
# IS NO SETTING THAT TURNS IT OFF. v1.0.80's
# node_modules/@github/copilot-linux-x64/prebuilds/linux-x64/runtime.node carries
# these message templates adjacent in its string table:
#     Denied by preToolUse hook:
#     preToolUse hook
#     / timed out; allowing the tool call to proceed:
# alongside the errored-hook wording ` (fail-closed): `. So a hook that ERRORS fails
# closed, and a hook that TIMES OUT has its tool call ALLOWED. (Those strings are
# prefix-compressed in that table, which is why a whole-sentence `grep -F` finds
# nothing; grep the fragment `timed out; allowing the tool call` instead.)
#
# Four bounds stand between this shim and that path, and it matters to say exactly
# what they buy: they make the fail-open HARD TO REACH. They do NOT make it
# unreachable, and nothing in this repo should claim otherwise. A loaded machine, a
# guard invocation wedged somewhere `timeout` cannot interrupt (an uninterruptible
# disk wait on a dead mount), or simply a slower box than the one these numbers were
# measured on could still run past copilot/settings.json's `timeoutSec`, and that
# call would then be allowed unguarded with nothing to notice. Treat the bounds as
# raising the cost of reaching the fail-open, not as removing it. Concretely: the
# worst case MEASURED here is ~20.4s and the CEILING the code actually permits is
# JUST UNDER 21s, both against `timeoutSec: 30` -- a margin of about 1.43x at that
# ceiling, not the 3x one revision of this comment claimed nor the 1.5x the next
# one did. Cite the ceiling, not the measurement, and do not round either in the
# flattering direction. Where the extra second comes from is explained at
# GUARD_BUDGET_SECONDS; the full table is at MAX_PAYLOAD_BYTES below.
#   0. MAX_PAYLOAD_BYTES caps the raw stdin payload before the first *jq* spawn.
#      Not before the first subprocess: `input=$(cat)` has already run by then and
#      its cost scales with the real payload, so the ceiling bounds what follows
#      the read, not the read itself. That is why it is a byte ceiling on an
#      already-buffered string and not a `head -c`. Everything after it up to the
#      guard loop scales with payload SIZE rather than path count -- a second,
#      independent axis. It is a BYTE ceiling only because of the `export LC_ALL=C`
#      below; under a UTF-8 locale it counted characters and a multibyte payload
#      got 4x the budget it declared. See the measured table at MAX_PAYLOAD_BYTES.
#   1. MAX_TARGET_PATHS caps how many distinct paths a single call may target, and
#      it is checked the INSTANT paths are extracted, before any per-path work
#      happens at all. This is the bound that actually closed the hole. Before it,
#      the payload-construction loop -- one `jq -n` per path, with no deadline
#      check, running BEFORE the guard loop where the only deadline lived -- was by
#      itself enough to blow the CLI's timeout. Measured on this machine against
#      `timeoutSec: 30`, padding with harmless paths in an exempt repo: 2000 paths
#      19.7s, 3000 paths 26.0s, 4000 paths 30.0s -- at which point the CLI timed out
#      and would have allowed the write, guarded paths and all. ~160 KB of padding
#      fits inside one model response, so that was a bypass reachable by accident as
#      readily as on purpose. Exceeding the cap is a DENY, never a pass.
#   2. GUARD_BUDGET_SECONDS bounds the guard loop as a whole, and each individual
#      guard spawn is additionally wrapped in `timeout "$remaining"` so that ONE
#      slow invocation cannot carry the script past that budget. That case is real,
#      not theoretical: a path on a hung or disconnected mount (`/mnt/...` under
#      WSL) makes the guard's `git -C` and its `[ -d ]`/`dirname` walk block, and a
#      deadline checked only at the top of the loop never gets another look-in.
#      Running out of budget is a DENY; so is the wrapper firing (exit 124, which
#      lands in the unexpected-exit branch below and denies there).
#   3. copilot/settings.json pins an explicit `timeoutSec` rather than inheriting a
#      default a CLI release could change under us, and the three bounds above sit
#      below it. Change one, change all four, and keep the gap.
# Bounds 0-2 are this file's own constants and are defined together under THE THREE
# SHIM BOUNDS below; bound 3 is the CLI's and lives in copilot/settings.json.
# Beyond the bounds, stay fast: one jq spawn on the out-of-scope path, a handful of
# short ones otherwise, ONE `jq -Rs` building every payload at once plus ONE reading
# them back to verify, and one spawn of the guard per distinct target path. No
# network, no git of our own.
#
# Copilot's exit-code contract, all observed: 0 allows; 2 denies; and unlike Claude
# Code, *every* other non-zero exit also denies (1 as "hook errored", 127, a
# missing script). Proxying the guard's exit code is therefore sufficient to block
# -- but it also means an accidental non-zero exit from this shim hard-blocks the
# session, so every deny path below names itself and its cause, and the allow path
# exits 0 deliberately.
#
# Same failure bias as the script it wraps: an unhandled failure here -- jq missing
# from PATH, a payload shape that changed under us, an unset variable -- must never
# quietly stop guarding. The ERR trap turns any such failure into a block. `-E`
# makes the trap inherit into functions and subshells.
set -Eeuo pipefail

# `SECONDS` IS INHERITED FROM THE ENVIRONMENT, so anchor it before anything reads
# it. Bash seeds the builtin from an exported `SECONDS`
# (`SECONDS=-100000 bash -c 'echo $SECONDS'` prints -100000), and a negative seed
# makes `remaining` in the guard loop enormous: the budget check never fires and
# the per-spawn `timeout` is handed a value that effectively disables it. Nothing
# an agent can reach today sets it, but the deadline story below rests entirely
# on this variable, so it is anchored rather than assumed.
SECONDS=0

# BYTES, NOT CHARACTERS -- this is what makes MAX_PAYLOAD_BYTES mean what its
# name says. Under a UTF-8 locale `${#input}` counts CHARACTERS, so an
# all-multibyte payload sails through a 4 MiB "byte" ceiling while actually
# carrying up to 16 MiB, and every pass over it costs in proportion to the bytes,
# not the characters. In the C locale `${#input}` is a true byte count and that
# 4x slack disappears.
#
# The byte count is the MEASURED, load-bearing reason and the one to keep. There
# is a second, weaker argument for the C locale that is worth recording honestly
# rather than dropping: GNU `sed` and `grep` in a UTF-8 locale are documented to
# be able to refuse or mis-handle byte sequences that are not valid UTF-8, while
# in the C locale they treat input as opaque bytes -- which is what a path
# extractor wants. An earlier revision of this comment went further and asserted
# that this could make the guard's `grep -qE '\$\(|`|<\('` command-substitution
# check fail OPEN under a UTF-8 locale. THAT CLAIM IS NOT REPRODUCIBLE: 7
# invalid-UTF-8 shapes x 3 locales all matched, and the string has in any case
# already passed through `jq -r`, which will not emit invalid UTF-8 in the first
# place. Treat the locale-robustness argument as belt-and-braces, not as measured
# fact, and do not cite it as the reason this line exists. Verified: unicode paths
# still round-trip byte-exactly through payload construction and still block.
export LC_ALL=C

SHIM_NAME="copilot/hooks/require-devcontainer.sh"

# ── THE THREE SHIM BOUNDS ───────────────────────────────────────────────────────
# These are bounds 0-2 from the header. Bound 3 is `timeoutSec` and belongs to the
# CLI, not to this file -- it lives in copilot/settings.json. All three here exist
# for the fail-open documented above, all three are DENY-on-exceed, and all three
# must stay below `timeoutSec` (30s today) with room to spare. They live together,
# rather than each next to the code that reads them, so the invariant between them
# and `timeoutSec` can be checked in one place.
#
# MEASURED ON THIS MACHINE, jq 1.7 / bash 5.2 / WSL2, AFTER `export LC_ALL=C`.
# Re-measure before changing any of the three; do not carry these numbers forward
# on trust. `timeoutSec` is 30s throughout.
#
#   stdin payload                                        verdict   wall
#   -------------------------------------------------------------------
#   4194304 B ASCII, 1 path (exactly at the ceiling)      ALLOW     1.00s
#   4194305 B (ceiling + 1)                               DENY      0.19s
#   4194304 B of U+1F600, 1 path (at the ceiling)         ALLOW     1.01s
#   4194304 B + 200 exempt paths                          ALLOW     9.4s
#   15.6 MB of U+1F600 + 200 paths                        DENY      0.69s
#   201 paths                                             DENY      0.06s
#   200 paths x 18 nonexistent segments, unpadded         ALLOW    19.05s  <-- worst
#   4194304 B + 200 paths x 18 nonexistent segments       DENY     19.54s
#   guard hangs (per-spawn `timeout` fires)               DENY     20.06s
#   200 slow-but-finite spawns, tuned to overshoot        DENY     20.40s  <-- worst
#
# WORST CASE MEASURED IS ~20.4s. THE CEILING THE CODE ACTUALLY PERMITS IS JUST
# UNDER 21s, AND THE MARGIN UNDER `timeoutSec: 30` IS ABOUT 1.43x. Cite the
# CEILING: the measurements are a lower bound on it and a slower box moves them,
# while the ceiling is a property of the arithmetic. Do not round it in the
# flattering direction -- earlier revisions of this comment claimed 3x and then
# 1.5x, and both erred the same way.
#
# The ceiling is set by GUARD_BUDGET_SECONDS and NOT by MAX_PAYLOAD_BYTES, in two
# compounding ways. First, the budget is checked at the TOP of each iteration, so
# the last guard spawn may start just under the budget and still run to completion.
# Second -- and this is where the extra second comes from -- `remaining` is
# computed from `SECONDS`, which counts WHOLE seconds, so a spawn starting at
# 19.99s elapsed sees `SECONDS=19`, is granted `timeout 1`, and is killed at ~21.0s
# rather than at the 20s the budget nominally allows. Both directions inherit that:
# worst ALLOW and worst DENY share the same ~21s ceiling.
#
# THE PRE-LOOP WORK DOES NOT ADD ON TOP OF THE BUDGET. `SECONDS` is anchored to 0
# at the very top of this file, BEFORE `input=$(cat)`, so payload parsing is spent
# from inside the budget rather than ahead of it, and it is a mistake to add the
# ~1.0s payload cost to the ~21s ceiling. Verified rather than assumed: at an
# identical per-spawn delay the 4 MiB-padded payload finished in 19.26s and the
# unpadded one in 20.40s -- the padding made the run SHORTER, not a second longer.
#
# The 200-paths-x-18-segments row is the realistic shape that rides the loop up to
# the budget: the guard walks a nonexistent path to its nearest existing ancestor
# one `dirname` SPAWN per segment, then finds no git repo and allows. 15 KB of
# patch text is enough to build it; the payload ceiling never comes near being the
# binding constraint there. Everything here sits inside 30s, none of it by much,
# and a slower box narrows all of it.
#
# MAX_PAYLOAD_BYTES -- the ceiling on the raw stdin payload, checked before the
# first jq spawn (NOT before the first subprocess: `input=$(cat)` precedes it, and
# that read costs 0.21s at 4 MB, 0.91s at 16 MB, 3.52s at 64 MB -- unbounded by
# anything here, which is the reason to keep the ceiling low rather than to raise
# it). The path count is not the only axis that scales: the five jq parses and the
# sed pass after the check scale with payload SIZE instead. 4 MiB is an order of
# magnitude above any patch a model can actually emit in one response (an
# output-token limit puts that in the hundreds of KB) and costs ~1.0s here.
#
# THIS IS A BYTE COUNT ONLY BECAUSE OF `export LC_ALL=C` ABOVE. Under a UTF-8
# locale `${#input}` counts characters, and that gap was real, not academic:
# measured on this machine, a 15.6 MB payload of U+1F600 with 200 paths was ALLOWED
# in 16.75s by the character-counting version and is DENIED in 0.69s by this one.
MAX_PAYLOAD_BYTES=$((4 * 1024 * 1024))
#
# MAX_TARGET_PATHS -- the ceiling on distinct target paths in one tool call. Only
# apply_patch can exceed 1. The number is chosen from the measured cost of a path,
# not from taste: an ordinary guard spawn is ~45ms on this machine, so 200 paths is
# ~9s of guard work against exempt-but-real repos -- under half of `timeoutSec`.
# That is the ORDINARY cost, not the worst one; see the table above for the shape
# that makes each spawn far more expensive, which GUARD_BUDGET_SECONDS rather than
# this constant is what actually bounds. Legitimate patches are nowhere near 200;
# the largest plausible refactor touches tens of files, and a caller that genuinely
# needs more can split the call, which the deny message tells it to do. Raising this
# trades directly against the fail-open, so re-measure if you do.
MAX_TARGET_PATHS=200
#
# GUARD_BUDGET_SECONDS -- the wall-clock ceiling on all guard invocations for one
# call, checked before each spawn AND enforced on each spawn via `timeout`. This is
# the bound that sets the shim's worst case in BOTH directions, and THE REAL
# CEILING IS THE BUDGET PLUS ONE SECOND -- just under 21s, not 20s -- for two
# compounding reasons. The check sits at the TOP of the loop, so an already-started
# spawn can overshoot it; and `remaining` is `GUARD_BUDGET_SECONDS - SECONDS` where
# `SECONDS` counts WHOLE seconds, so a spawn starting at 19.99s elapsed reads
# `SECONDS=19`, is handed `timeout 1`, and is killed at ~21.0s. Neither is a bug to
# fix here -- sub-second timing would cost a subprocess per iteration in the hot
# loop -- but the extra second is real and must be carried in every figure derived
# from this constant. 20s leaves ~10s under `timeoutSec` on paper and ~9s in fact,
# which the table above shows is the whole of the margin, so treat 20 and 30 as a
# matched pair. `SECONDS` is a bash builtin counting whole seconds since the script
# started (anchored to 0 at the top of this file -- it is inheritable), so
# consulting it costs no subprocess in the hot loop.
GUARD_BUDGET_SECONDS=20

# Emit Copilot's flat deny JSON on stdout and exit 2. Disarm the ERR trap first so
# a failure inside deny() cannot recurse; if jq itself is the thing that broke, fall
# back to a hand-written constant (printf is a bash builtin, so it survives an empty
# PATH) so the block still carries an explanation instead of a bare exit code.
deny() {
  trap - ERR
  if ! printf '%s' "$1" | jq -Rs '{permissionDecision: "deny", permissionDecisionReason: .}' 2>/dev/null; then
    printf '%s\n' '{"permissionDecision":"deny","permissionDecisionReason":"BLOCKED by copilot/hooks/require-devcontainer.sh: the guard could not run and jq was unavailable to report why. Refusing this call rather than allowing it unguarded. This is a bug in the hook, not in your command -- report it to the Captain."}'
  fi
  exit 2
}

# Installed before anything that can fail, so there is no window in which a failure
# exits with something other than a self-describing deny.
trap 'deny "BLOCKED by $SHIM_NAME: the shim itself failed unexpectedly near line $LINENO, so this call is refused rather than silently allowed. This is a bug in the hook, not in your command -- report it to the Captain."' ERR

[ -n "${HOME:-}" ] || deny "BLOCKED by $SHIM_NAME: HOME is unset, so the guard script ~/.claude/hooks/require-devcontainer.sh could not be located. Refusing rather than allowing this call unguarded."
GUARD="$HOME/.claude/hooks/require-devcontainer.sh"

input=$(cat)
[ -n "$input" ] || deny "BLOCKED by $SHIM_NAME: the hook received empty stdin, so there is no tool call to judge. Refusing rather than allowing an uninspected call."

# FIRST BOUND, BEFORE THE FIRST *jq* SPAWN -- not before the first subprocess.
# `input=$(cat)` above already ran one, and its cost scales with the real payload
# (measured: 4.2s for 64 MB), so nothing here bounds the read itself; what this
# bounds is the five jq parses and the sed pass that follow. `${#input}` is a bash
# parameter expansion, so the check costs no spawn and cannot itself be the slow
# thing. An oversized payload is the size-axis twin of the padded patch
# MAX_TARGET_PATHS stops. Deny, never allow: see the fail-open discussion above.
#
# This is a TRUE BYTE COUNT because of the `export LC_ALL=C` at the top of this
# file, and it must stay one. Under a UTF-8 locale `${#input}` counts CHARACTERS,
# which let an all-multibyte payload carry 4x this ceiling -- 16 MiB of real bytes
# past a check that reported 4 MiB -- and the cost of every pass over it is paid in
# bytes. Do not remove the locale export without re-measuring the table at
# MAX_PAYLOAD_BYTES; it is load-bearing for this line, not tidiness.
[ "${#input}" -le "$MAX_PAYLOAD_BYTES" ] ||
  deny "BLOCKED by $SHIM_NAME: this tool call's hook payload is ${#input} bytes, over the ${MAX_PAYLOAD_BYTES}-byte ceiling this hook will inspect. A payload that large cannot be parsed within the time the CLI allows the hook, past which the CLI stops waiting and ALLOWS the call unguarded. Refusing rather than letting that happen. Split it into smaller calls."

# Copilot's payload keys are camelCase (sessionId, timestamp, cwd, toolName,
# toolArgs) and there is no hook_event_name field at all -- do not assume Claude
# Code's snake_case shape here.
#
# The object check and the toolName read are ONE jq spawn on purpose, not two.
# With the matcher widened to `.*` this hook fires on every tool call the session
# makes, and the overwhelming majority of them exit 0 at the `case` below, so this
# is the hot path: halving its process count halves the tax the widened matcher
# imposes. A non-object payload and unparseable JSON both land in the same deny
# because they are the same thing from here -- a payload that cannot be inspected.
# The "ok " prefix is not forgeable by a hostile toolName: the failure branch emits
# the bare word "bad" and nothing else, so only a genuine object can ever produce a
# value starting with "ok ", whatever the toolName inside it happens to be.
probe=$(jq -r 'if type == "object" then "ok " + (.toolName // "") else "bad" end' <<<"$input" 2>/dev/null) || probe=""
case "$probe" in
"ok "*) tool_name=${probe#"ok "} ;;
*) deny "BLOCKED by $SHIM_NAME: the hook payload on stdin was not a JSON object, so this call could not be inspected. Refusing rather than allowing it unguarded." ;;
esac

# require-devcontainer.sh only branches on "Bash" vs. everything else in
# {Edit, Write, NotebookEdit}; it has no per-file-tool logic. So every Copilot
# file-mutation tool collapses to "Edit" and takes the identical path through it.
# Note there is no NotebookEdit equivalent to map: .ipynb files go through
# create/edit like any other text file. `write` is deliberately absent -- it is a
# Copilot *permission kind*, not a tool name.
#
# DENY BY DEFAULT -- issue #12. This case used to end `*) exit 0 ;;`: any
# toolName this shim did not recognize was silently ALLOWED. That is a fail-open
# on the exact same axis as the timeout/matcher hazards documented above, except
# it needs no adverse condition to trigger -- it fires on the FIRST call bearing
# a name this file has not been taught, whether that is a future Copilot CLI
# tool, a typo, or a name chosen specifically to dodge the `case` above. Driven
# directly against a guarded, non-containerized repo, feeding this shim
# `powershell`, `local_shell`, `shell`, and `run_in_terminal` -- none of them
# real Copilot tool names, all of them plausible ones -- each ran `npm ci` with
# ALLOW, while `bash` (lowercase, the one name this file did recognize) correctly
# denied. Confirmed reproducing before this fix and confirmed denying after it.
#
# The fix inverts the default: only names this shim can positively account for
# get out of the `case` without a deny. `view`, `grep`, and `glob` are Copilot's
# read tools -- confirmed present as literal tool-name tokens in v1.0.80's
# node_modules/@github/copilot-linux-x64/prebuilds/linux-x64/runtime.node string
# table (that table is prefix-compressed, per the TIMEOUT FAILS OPEN note above,
# so this checks for the token rather than the quoted JSON string) -- and none of
# the three take a `command` or a path: `view` reads a file, `grep`/`glob` search
# without writing. Nothing else is allowlisted, INCLUDING Copilot "planning"
# tools this shim cannot name today: an unnamed tool is exactly what this fix
# refuses to wave through on the strength of not looking dangerous.
#
# NO SHAPE-PROBE TIEBREAKER HERE, UNLIKE THE KILO PORT -- AND THAT ASYMMETRY IS
# THIS PORT'S ADVANTAGE, NOT A FEATURE IT LACKS. An earlier version of this note
# framed Kilo's probe as something that "earns its keep". State the trade
# accurately instead: an unconditional deny on an unrecognized name is the
# stronger design, and Kilo's probe is a CONCESSION to a tool namespace that
# cannot be enumerated, carrying known residual risk. An adversarial review of
# the Kilo port landed BOTH of its blocking findings squarely on that probe --
# a read-only allowlist that a contributed tool could claim membership of by
# name, and a "route path-bearing calls through Edit" rule justified by a claim
# about the shared guard script that turned out to be false. Neither defect has
# an analogue here, because there is no probe here for them to live in.
#
# Copilot can afford the stricter design because its tool roster is closed and
# first-party (no user-installed tools reach this hook), and its MCP tools fire
# a *separate* preMcpToolCall event this matcher never sees at all (see THE
# MODEL-FAMILY TOOL-NAME TRAP above) -- so there is no MCP name that could ever
# reach this `case` to be probed. Every legitimate name this shim will ever see
# is a Copilot built-in, which means every legitimate name can and should be
# added here explicitly rather than guessed at by shape. Kilo cannot afford it:
# MCP servers and plugins contribute names Kilo itself cannot enumerate ahead of
# time, so denying every unenumerated name there would deny the legitimate ones
# too, and the probe is what buys those calls a judgement at all.
#
# DO NOT "harmonize" the two ports by importing a shape probe here. That would
# trade this port's one structural advantage for parity with the weaker design,
# and it would import the residual risk documented in kilo/plugin/
# require-devcontainer.ts along with it. If Copilot ships a new tool, the
# fail-safe outcome is a loud, actionable deny -- not a silent allow -- and it
# stays that way until someone adds the name below.
case "$tool_name" in
bash) mapped="Bash" ;;
create | edit | apply_patch | str_replace_editor) mapped="Edit" ;;
view | grep | glob) exit 0 ;;
"") deny "BLOCKED by $SHIM_NAME: the hook payload carried no toolName, so this call could not be classified. Refusing rather than allowing it unguarded." ;;
*) deny "BLOCKED by $SHIM_NAME: the hook payload's toolName ('$tool_name') is not one this shim recognizes as either a read-only tool or a shell/file-mutation tool. Refusing rather than allowing an unclassified tool call through unguarded, which is the fail-open issue #12 closed -- do not restore a wildcard allow here. If '$tool_name' is a genuine read-only Copilot tool, add it to the read-only case above; if it runs commands or writes files, add it to the Bash/Edit case above." ;;
esac

# The session's working directory. require-devcontainer.sh judges a Bash call
# purely by this (a `cd` inside the command string is not resolvable from a hook,
# and does not need to be -- its allowlist bounds what a Bash call can do wherever
# it lands). A payload without a usable cwd is a payload we cannot judge.
cwd=$(jq -r '.cwd // empty' <<<"$input")
[ -n "$cwd" ] || deny "BLOCKED by $SHIM_NAME: the hook payload carried no cwd, so the project this call targets could not be determined. Refusing rather than allowing it unguarded."
[ -d "$cwd" ] || deny "BLOCKED by $SHIM_NAME: the hook payload's cwd ($cwd) is not an existing directory, so the project this call targets could not be determined. Refusing rather than allowing it unguarded."

# toolArgs is a STRING, and what is inside it depends on the tool:
#   * bash / create / edit / view / grep / glob -> double-encoded JSON (parse the
#     payload, then parse toolArgs again).
#   * apply_patch                               -> a RAW PATCH TEXT BLOB, not JSON.
# A shim that blindly JSON-parses toolArgs throws on every OpenAI-family file
# write. The `object` branch is defensive only: today the field is always a string,
# but if a future CLI stops double-encoding it, this keeps working instead of
# hard-blocking every call.
args_type=$(jq -r '.toolArgs | type' <<<"$input")
case "$args_type" in
string) args=$(jq -r '.toolArgs' <<<"$input") ;;
object) args=$(jq -c '.toolArgs' <<<"$input") ;;
*) deny "BLOCKED by $SHIM_NAME: the hook payload's toolArgs was of type '$args_type' (expected a string), so this $tool_name call could not be inspected. Refusing rather than allowing it unguarded." ;;
esac

# One JSON payload per target path, plus a human label for each so a deny can name
# the path it refused. A Bash call always has exactly one; a file tool has one per
# file it would write, and apply_patch is inherently MULTI-FILE.
payloads=()
labels=()

if [ "$mapped" = "Bash" ]; then
  command=$(jq -r '.command // empty' <<<"$args" 2>/dev/null) ||
    deny "BLOCKED by $SHIM_NAME: the bash call's toolArgs was not parseable JSON, so the command could not be inspected. Refusing rather than allowing it unguarded."
  # require-devcontainer.sh treats an empty command as out of scope and exits 0.
  # Here an empty command means the payload shape changed under us, so fail closed
  # rather than inherit an allow this shim did not earn.
  [ -n "$command" ] || deny "BLOCKED by $SHIM_NAME: no command could be extracted from the bash call's toolArgs, so it could not be inspected. Refusing rather than allowing it unguarded."
  # Copilot's bash payload carries NO per-call working directory. The Kilo port
  # prefers a per-call `workdir` over the session cwd where one is present, and the
  # same preference would be right here if the field existed -- it does not. The
  # shipped tool schema for the shell tool is {command, description,
  # requestSandboxBypass}, and neither the packed app nor the native runtime
  # contains a `workdir` key at all (only session-level `workingDirectory`, moved
  # by `metadata.setWorkingDirectory`). So the session cwd is the only directory
  # this call can be judged against. Do not add a speculative `.workdir` read here:
  # a key that never appears is dead code that reads like a guarantee.
  payloads+=("$(jq -n --arg cwd "$cwd" --arg command "$command" \
    '{tool_name: "Bash", agent_type: "copilot", cwd: $cwd, tool_input: {command: $command}}')")
  labels+=("")
else
  file_paths=()
  declare -A seen_paths=()

  if [ "$tool_name" = "apply_patch" ] && [ "$args_type" = "string" ]; then
    # Raw patch text, not JSON. Paths appear as `*** Add File: <path>` /
    # `*** Update File: <path>` / `*** Delete File: <path>`, and a rename carries a
    # `*** Move to: <dest>` line under its Update section.
    #
    # EXTRACT EVERY PATH, NOT THE FIRST. Taking only the first was a real bypass:
    # apply_patch can carry any number of sections, so a patch whose first section
    # touched an allowed or exempt path (something under /tmp, or a repo carrying
    # .no-auto-provision) and whose later sections touched a guarded project was
    # waved straight through -- the guard exited 0 and the write landed. That fires
    # by accident as readily as adversarially, and it defeated the whole port.
    #
    # `*** Move to:` is folded in as a FIRST-CLASS path, not a fallback for a
    # missing File header. A Move's destination is a write in its own right and can
    # sit in a different project from the source the Update header names, so the
    # source path does not cover it.
    #
    # Extraction is line-oriented and so is the patch format itself: a filename
    # containing a newline is unrepresentable in these headers (the header ends at
    # the line break), so there is no path apply_patch could act on that this can
    # silently split. Spaces are safe throughout -- sed emits one path per line and
    # the read loop below never word-splits.
    #
    # The ceiling is enforced HERE, inside the extraction loop, and not only on the
    # finished array. Enforcing it after the fact would still let a patch with a
    # million duplicate headers spin this loop for as long as it liked before
    # anything looked at a clock; bailing on the (N+1)th header caps the loop and
    # SIGPIPEs the `sed` feeding it. Count RAW headers, not distinct paths, so
    # dedup cannot be used to smuggle unbounded work past the cap.
    header_count=0
    while IFS= read -r extracted; do
      header_count=$((header_count + 1))
      [ "$header_count" -le "$MAX_TARGET_PATHS" ] ||
        deny "BLOCKED by $SHIM_NAME: this apply_patch carries more than $MAX_TARGET_PATHS file sections. Each one has to be checked against the devcontainer guard separately, and a patch this large cannot be checked within the time the CLI allows the hook -- past which the CLI stops waiting and ALLOWS the call unguarded. Refusing rather than letting that happen. Split it into calls of at most $MAX_TARGET_PATHS files each."
      # A header line that yields nothing after its prefix and trailing whitespace
      # are stripped is a malformed patch, not an empty section to skip past.
      # Skipping it would mean writing to a path this shim never judged, so refuse.
      [ -n "$extracted" ] ||
        deny "BLOCKED by $SHIM_NAME: this apply_patch contains a file header with an empty path, so one of the files it would write could not be identified. Refusing the whole patch rather than applying it with a path left unchecked."

      # THE GRAMMAR'S SEPARATOR IS EXACTLY ONE SPACE, AND `filename` IS GREEDY.
      # Recovered from the shipped runtime, the rule is
      # `add_hunk: "*** Add File: " filename LF add_line+` with
      # `filename: /(.+)/` -- so the single space after the colon is the whole of
      # the delimiter, and any FURTHER leading space or tab is part of the
      # filename as the CLI itself parses it. The extractor below therefore
      # strips the colon ONLY, and the grammar's one space is consumed here.
      #
      # It used to strip `[[:space:]]*` in sed, and that made the two parsers
      # disagree about where the path begins -- a differential, not a cosmetic
      # difference. Observed: the header `*** Add File:  /../src/main.py` (TWO
      # spaces) handed this shim the ABSOLUTE path `/../src/main.py`, which walks
      # up past `/`, sits in no git repo, and was ALLOWED -- while the same header
      # read per the grammar yields the RELATIVE path ` /../src/main.py`, and
      # node's `path.resolve(<guarded cwd>, " /../src/main.py")` resolves that to
      # `<guarded cwd>/src/main.py`, a real file inside the guarded project. The
      # single-space control denied correctly, which is what makes it a
      # differential rather than a general hole.
      #
      # Whether the live Rust parser trims is UNCONFIRMED, and this deliberately
      # does not depend on the answer: extra leading whitespace in a filename has
      # no legitimate use, so refusing the patch outright is safe whichever way it
      # behaves, and is the only outcome that is correct under both. The same
      # applies to a header that carries no separating space at all -- the shape
      # is then not the grammar's, and guessing at it is exactly the mistake
      # above. Trailing whitespace is still stripped below: the guard judges by
      # `dirname`, so trailing bytes cannot be used to point at another directory.
      [ "${extracted# }" != "$extracted" ] ||
        deny "BLOCKED by $SHIM_NAME: this apply_patch has a file header whose path is not separated from it by the single space the patch format requires ('$extracted'), so this shim and the CLI's own patch parser would not agree on which file it names. Refusing the whole patch rather than guessing."
      extracted=${extracted# }
      case $extracted in
      [[:space:]]*)
        deny "BLOCKED by $SHIM_NAME: this apply_patch has a file header whose path begins with extra whitespace ('$extracted'). The CLI's patch parser keeps that whitespace as part of the filename while this guard would not, so the two would judge different files -- and a relative path read as an absolute one escapes the project this guard protects. Refusing the whole patch."
        ;;
      esac

      if [ -z "${seen_paths[$extracted]+set}" ]; then
        seen_paths[$extracted]=1
        file_paths+=("$extracted")
      fi
    done < <(
      # Strips the COLON only. The grammar's single separating space is consumed
      # in the loop above, which is also where a header that does not have that
      # exact shape is refused -- see the note there. Do not put `[[:space:]]*`
      # back here: that is the differential, not a tidy-up.
      sed -n -E \
        -e 's/^\*\*\* (Add|Update|Delete) File://' \
        -e 't trim' \
        -e 's/^\*\*\* Move to://' \
        -e 't trim' \
        -e 'b' \
        -e ':trim' \
        -e 's/\r$//' \
        -e 's/[[:space:]]+$//' \
        -e 'p' \
        <<<"$args"
    )
  else
    # create/edit carry a top-level `path`, confirmed empirically -- and so does
    # str_replace_editor, whose tool schema in the shipped runtime declares exactly
    # {command, file_text, insert_line, new_str, old_str, path}. file_path and
    # filePath are kept as harmless further fallbacks.
    #
    # ONLY A STRING IS A PATH. `jq -r` renders a non-string value as its JSON
    # TEXT, so `{"path": ["/x/a.txt"]}` used to arrive here as the literal
    # `["/x/a.txt"]` -- one bogus "path" that resolves to nothing, sits in no git
    # repo, and was therefore ALLOWED. Observed for arrays and objects alike.
    # Whatever the CLI would make of such a payload, this shim cannot judge it, so
    # the type is asserted rather than coerced, and anything else denies. This
    # matches the readback check further down, which already asserts
    # `(.tool_input.file_path | type) == "string"` on the payloads it builds.
    # `empty` (a missing key) is still allowed through as the empty string and is
    # caught by the zero-paths deny below, which reports it better.
    path_probe=$(jq -r '
      (.path // .file_path // .filePath) as $p
      | if $p == null then "ok:" elif ($p | type) == "string" then "ok:" + $p
        else "bad:" + ($p | type) end' <<<"$args" 2>/dev/null) ||
      deny "BLOCKED by $SHIM_NAME: the $tool_name call's toolArgs was not parseable JSON, so the target file could not be determined. Refusing rather than allowing it unguarded."
    case $path_probe in
    "ok:"*) file_path=${path_probe#ok:} ;;
    "bad:"*)
      deny "BLOCKED by $SHIM_NAME: the $tool_name call's target path was of type '${path_probe#bad:}', not a string, so the file it would write could not be determined. Refusing rather than allowing it unguarded."
      ;;
    *)
      deny "BLOCKED by $SHIM_NAME: the $tool_name call's target path could not be read from its toolArgs. Refusing rather than allowing it unguarded."
      ;;
    esac
    [ -z "$file_path" ] || file_paths+=("$file_path")
  fi

  # No path means the guard would fall back to judging ".", i.e. some directory
  # that has nothing to do with this call. Refuse instead. This is also the
  # zero-paths-extracted case for apply_patch, and it must stay a deny.
  [ "${#file_paths[@]}" -gt 0 ] ||
    deny "BLOCKED by $SHIM_NAME: no target file path could be extracted from the $tool_name call, so the project it would write to could not be determined. Refusing rather than allowing it unguarded."

  # Belt and braces over the in-loop check above: the ceiling must hold no matter
  # which branch filled file_paths, including any branch added later. Checked here,
  # BEFORE the first line of per-path work, because the whole point of the ceiling
  # is that nothing whose cost scales with the path count runs ahead of it.
  [ "${#file_paths[@]}" -le "$MAX_TARGET_PATHS" ] ||
    deny "BLOCKED by $SHIM_NAME: this $tool_name targets ${#file_paths[@]} distinct paths, more than the $MAX_TARGET_PATHS this hook will check in one call. Checking them all would run past the time the CLI allows the hook, past which the CLI stops waiting and ALLOWS the call unguarded. Refusing rather than letting that happen. Split it into calls of at most $MAX_TARGET_PATHS files each."

  # ONE jq spawn for every payload, not one per path. This used to be a loop of
  # `jq -n` calls and that loop was the bug: it ran BEFORE the guard loop, which
  # held the only deadline, so its cost -- ~6ms of process startup per path, times
  # thousands of paths -- was unbounded pre-work that could exhaust the CLI's
  # timeout before this script had checked a clock even once. With the ceiling
  # above, one bounded jq invocation is cheap enough that it needs no deadline of
  # its own.
  #
  # PATHS GO IN ON STDIN, NOT IN argv. NOTHING ATTACKER-CONTROLLED MAY APPEAR ON
  # jq's COMMAND LINE. An earlier revision passed the paths as `--args
  # "${file_paths[@]}"` on the strength of a belief that `--args` swallows
  # everything after it as a positional. IT DOES NOT, and that was a working
  # end-to-end bypass, not a theoretical one. jq 1.7 keeps parsing options after
  # `--args`:
  #     $ jq -c -n --arg c x '$ARGS.positional[]' --args a -c b --args d e
  #     "a"  "b"  "d"  "e"      # `-c` and the second `--args` were eaten as OPTIONS
  # The exploit that followed: an `*** Add File: -f` header put `-f` on jq's
  # command line, and `-f` makes jq treat its program argument as a FILENAME to
  # read the program from -- resolved against jq's own cwd, which at this point is
  # still the Copilot session cwd (the `cd "$cwd"` happens later, inside the guard
  # loop's subshell). An agent that first wrote a file named byte-for-byte like
  # this filter string, into any directory it was allowed to write to (~, /tmp, or
  # an exempt repo), then issued one apply_patch, got its own jq program executed
  # here. That program emitted objects with an unrecognised `tool_name`, which the
  # guard exits 0 on, and padded its output so the line count still matched -- so
  # the shim exited 0 and the write landed in a guarded, non-containerized
  # project. Confirmed reproducing, and confirmed denying after this change.
  #
  # Feeding the paths as a NUL-delimited stream on stdin removes the argument
  # surface entirely rather than patching one instance of it. jq's argv is now
  # fixed text plus `--arg cwd "$cwd"`, and an `--arg` VALUE is consumed as the
  # option's argument and never itself option-parsed. NUL is the right delimiter
  # and not merely a careful one: a bash variable cannot contain a NUL byte, so no
  # path in `file_paths` can ever contain the separator, while newline, tab,
  # quote, backslash, leading space, `-`, `@` and `*` all can and all survive
  # byte-exactly. `[:-1]` drops the empty field after the trailing NUL that
  # `printf '%s\0'` leaves. `-c` keeps each payload on exactly one line for
  # `mapfile`.
  mapfile -t payloads < <(
    printf '%s\0' "${file_paths[@]}" |
      jq -c -Rs --arg cwd "$cwd" \
        'split("\u0000")[:-1][] | {tool_name: "Edit", agent_type: "copilot", cwd: $cwd, tool_input: {file_path: .}}'
  )
  labels=("${file_paths[@]}")
  # `mapfile` reports success even when the process substitution feeding it died,
  # so the count is the only signal that jq ran to completion at all. Keep it --
  # but do NOT mistake it for an integrity check. It is a LINE count, and lines
  # are not payloads: one stray output-format option (`--tab`, `-r`, `-S`) turns
  # each object into several lines, at which point N paths can still produce N
  # lines of JSON *fragments* that no longer correspond to anything in `labels`.
  # It is kept as the cheap first tripwire, and as defence in depth.
  [ "${#payloads[@]}" -eq "${#file_paths[@]}" ] ||
    deny "BLOCKED by $SHIM_NAME: building the guard payloads produced ${#payloads[@]} of the ${#file_paths[@]} needed for this $tool_name, so at least one target path could not be checked. Refusing rather than allowing it unguarded."

  # THE ACTUAL INTEGRITY CHECK, AND IT IS SEMANTIC. Read each payload back and
  # confirm, index by index, that it is the object this shim meant to build for
  # THAT path: right tool_name, right agent_type, right cwd, a `tool_input`
  # holding exactly a string `file_path`, and that path byte-identical to
  # `file_paths[i]`. Anything else -- a fragmented object, a payload built from a
  # program that is not ours, a silent reordering -- fails here regardless of how
  # it was caused, because this compares MEANING rather than counting lines.
  #
  # The comparison is done in bash, deliberately outside jq. The failure class
  # this defends against is "jq did not run the program we wrote", so a check
  # expressed inside that same program would be worthless. jq's only job here is
  # to decode; the verdict is bash's.
  #
  # Two NUL-delimited fields per payload: a status token, then the path. `mapfile
  # -d ''` splits on NUL, so a path containing newlines cannot desynchronise the
  # reader, and the separate status token means a payload MISSING `file_path`
  # cannot pass by coincidence (jq renders a missing key as the bare text `null`,
  # which is also a legal filename).
  mapfile -d '' -t verified < <(
    printf '%s\n' "${payloads[@]}" |
      jq -j --arg cwd "$cwd" '
        if type == "object"
           and .tool_name == "Edit"
           and .agent_type == "copilot"
           and .cwd == $cwd
           and (.tool_input | type) == "object"
           and (.tool_input | keys) == ["file_path"]
           and (.tool_input.file_path | type) == "string"
        then "ok", "\u0000", .tool_input.file_path, "\u0000"
        else "bad", "\u0000", "", "\u0000"
        end'
  )
  [ "${#verified[@]}" -eq $((2 * ${#file_paths[@]})) ] ||
    deny "BLOCKED by $SHIM_NAME: the guard payloads built for this $tool_name could not be read back and verified against its ${#file_paths[@]} target paths, so at least one path would have been checked as something other than itself. Refusing rather than allowing it unguarded."
  for i in "${!file_paths[@]}"; do
    if [ "${verified[2 * i]}" != "ok" ] || [ "${verified[2 * i + 1]}" != "${file_paths[i]}" ]; then
      deny "BLOCKED by $SHIM_NAME: the guard payload built for target path number $((i + 1)) of this $tool_name does not describe that path (expected '${file_paths[i]}'), so it would have been checked as something other than itself. Refusing rather than allowing it unguarded. This is a bug in the hook, not in your command -- report it to the Captain."
    fi
  done
fi

# Belt and braces: an empty payload set must never read as an allow.
[ "${#payloads[@]}" -gt 0 ] ||
  deny "BLOCKED by $SHIM_NAME: no checkable target could be derived from this $tool_name call, so nothing was submitted to the guard. Refusing rather than allowing it unguarded."

[ -f "$GUARD" ] || deny "BLOCKED by $SHIM_NAME: the guard script $GUARD is missing, so this call cannot be checked against it. Refusing rather than allowing it unguarded. Re-run install.py to restore the ~/.claude/hooks symlink."

# Spawn the guard once per DISTINCT target path, with its process cwd deliberately
# anchored to the cwd computed above. require-devcontainer.sh reads `cwd` from the
# JSON payload only for Bash; for file tools it derives its target purely from
# tool_input.file_path and falls back to "." when that is missing, at which point
# its `git -C "."` resolves against *this* process's cwd. Copilot does happen to
# run hooks with PWD already set to the session cwd, but relying on that
# undocumented behaviour would mean the guard could silently check the wrong
# project's container/exemption status if it ever changed. Set it explicitly.
#
# DENY IF ANY INVOCATION DENIES. Returning on the first deny is safe -- there is no
# partial verdict to compute and one refused path refuses the whole call. Returning
# on the first ALLOW is the bug this loop exists to fix; never reintroduce it.
#
# SELF-IMPOSED DEADLINE, TWO LAYERS. See the fail-open discussion in the header:
# a timed-out preToolUse hook has its tool call ALLOWED, so this loop must never be
# the thing that runs long. MAX_TARGET_PATHS already bounds how many times it runs;
# GUARD_BUDGET_SECONDS bounds how long that may take in total, and the per-spawn
# `timeout "$remaining"` bounds each individual guard invocation to whatever is left
# of the budget. Both layers are needed. The loop-top check alone assumes every
# spawn returns promptly, which is exactly what a path on a hung mount does not do;
# the wrapper alone would let 200 fast-but-not-instant spawns add up past the
# budget. Together the whole loop is bounded by GUARD_BUDGET_SECONDS plus the cost
# of one iteration's bookkeeping, whatever the guard does.
#
# Every way out of the bound is a DENY: budget exhausted denies here, and the
# wrapper firing exits 124, which is neither 0 nor 2 and so denies in the `*)` arm.
#
# The `if` condition suppresses errexit and the ERR trap for the duration, so a
# non-zero guard exit is handled below rather than trapped. stdout is discarded and
# stderr captured: stderr is the guard's explanation, and it is the only thing
# worth relaying.
for i in "${!payloads[@]}"; do
  remaining=$((GUARD_BUDGET_SECONDS - SECONDS))
  if [ "$remaining" -le 0 ]; then
    deny "BLOCKED by $SHIM_NAME: this $tool_name targets ${#payloads[@]} paths, and checking them all exceeded the ${GUARD_BUDGET_SECONDS}s the guard is allowed. $((i)) of them were checked and the rest were not, so this call is refused rather than allowed with paths left unguarded. Split it into smaller calls."
  fi

  # `timeout` is rightmost in the pipeline, so under `pipefail` its 124 is what the
  # substitution reports even if `printf` takes a SIGPIPE from the killed guard.
  # A missing `timeout` binary exits 127 here, which also denies -- correct.
  if guard_stderr=$(cd "$cwd" && printf '%s' "${payloads[i]}" | timeout "$remaining" bash "$GUARD" 2>&1 >/dev/null); then
    status=0
  else
    status=$?
  fi

  # Name the offending path when the call had more than one, so a deny on the
  # fourth file of a patch does not read as a deny on the first.
  which_path=""
  if [ "${#payloads[@]}" -gt 1 ] && [ -n "${labels[i]}" ]; then
    which_path=" (this $tool_name touches ${#payloads[@]} paths; the one refused is: ${labels[i]})"
  fi

  case "$status" in
  0)
    # This path is clear. Keep checking the rest -- do NOT exit 0 here.
    ;;
  2)
    guard_stderr=$(printf '%s' "$guard_stderr" | sed -e 's/[[:space:]]*$//')
    [ -n "$guard_stderr" ] || guard_stderr="BLOCKED by claude/hooks/require-devcontainer.sh (the guard blocked this call but produced no explanation). Load the \`devcontainer-first\` skill for what to do next."
    deny "${guard_stderr}${which_path}"
    ;;
  124)
    # `timeout` killed the guard. Named separately from the generic unexpected-exit
    # arm only so the message is useful; the outcome is identical and must stay a
    # deny. The guard itself never exits 124 -- it exits 0 or 2, and its own ERR
    # trap turns everything else into 2 -- so this really is the wrapper firing.
    deny "BLOCKED by $SHIM_NAME: the guard script $GUARD did not answer within the ${remaining}s left of its ${GUARD_BUDGET_SECONDS}s budget and was killed${which_path}, so its verdict is unknown. Either a target path sits on a hung or disconnected mount, or the earlier paths in this call had already used up the budget. Refusing rather than allowing this call through unchecked."
    ;;
  *)
    deny "BLOCKED by $SHIM_NAME: the guard script $GUARD exited $status (expected 0 or 2), so its verdict is unknown${which_path}. Refusing rather than allowing this call through with the guard in an unexpected state. Its output was: ${guard_stderr:-<none>}"
    ;;
  esac
done

# Every target path was allowed. Exit 0 deliberately and print nothing -- Copilot
# fails closed on any non-zero exit, so an accidental one here would hard-block the
# session.
exit 0
