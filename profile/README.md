# The `profile` file contract

This directory defines **one** thing: the format and meaning of the file

```
${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/profile
```

and ships a small reader for it that every consumer shares. This file
documents the contract and the parser; the consumers that wire it up (the
shell gate, the Python linker, the nvim `copilot.lua` gate, and the
`dotfiles profile <name>` CLI) live where each of them naturally belongs:

| Consumer | Lives at |
|----------|----------|
| Python linker (`install.py`) | repo root, imports `profile/profile.py` |
| Ansible (`provision/site.yml`) | shells out to `profile/profile.py`, see below |
| `dotfiles profile [<name>]` CLI | `tools/dotfiles.py`, linked to `~/.local/bin/dotfiles` |
| nvim `copilot.lua` gate | `nvim/lua/config/profile.lua` + `nvim/lua/plugins/copilot.lua` -- **a documented exception to "no third parser," see below** |

## Why this file exists

A dotfiles checkout can be switched into one of three **strictly nested**
capability profiles, so a machine that contributes to projects with a no-AI
contribution policy can be put into a state where no AI tooling is configured
at all:

| Profile   | What it means                                                                                                                                                    |
|-----------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `bare`    | Shell, git, nvim (**without** `copilot.lua`), tmux, starship, yazi, lazygit, editors, macros. No AI config directories, no AI npm globals.                          |
| `inline`  | `bare` **plus** editor completion plugins (`copilot.lua`, VS Code inline suggestions) and the one-shot `claude` / `copilot` CLIs. No agent roster, no `~/.claude/agents`, no skills, no MCP, no orchestrator. |
| `agentic` | Everything the repo ships today. The full agent roster, skills, hooks, MCP, orchestrator.                                                                          |

The nesting is a subset relation on *capabilities*:

```
bare  ⊂  inline  ⊂  agentic
```

Anything enabled at `bare` is enabled at `inline` and `agentic`; anything
enabled at `inline` is also enabled at `agentic`. A consumer therefore never
switches on the exact profile string — it asks "is my capability's minimum
level satisfied?" and compares by rank:

| Profile   | Rank |
|-----------|------|
| `bare`    | 0    |
| `inline`  | 1    |
| `agentic` | 2    |

"Capability X needs at least `inline`" is `rank(active) >= rank(inline)`.

## The contract

The file holds **exactly one profile name** and nothing else. It is the
single source of truth, read by three independent consumers (the shell, the
Python linker, Ansible). The rules below are deliberately strict so those
three can never drift apart on an edge case.

### Resolution rules

Given the file at `${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/profile`
(with `XDG_CONFIG_HOME` treated as unset when it is empty):

| # | Situation | Result |
|---|-----------|--------|
| 1 | **File absent** (no such path, and not a broken symlink) | Resolve to **`agentic`**. This is the *only* implicit default. It preserves today's behaviour for every checkout that predates this feature. |
| 2 | **File present, contents are exactly one of `bare` / `inline` / `agentic`** after trimming surrounding whitespace | Resolve to that profile. |
| 3 | **File present but empty** (zero bytes, or only whitespace once trimmed) | **Error.** Not treated as "absent". |
| 4 | **Trimmed contents contain internal whitespace** — a second word, a second line, a space in the middle | **Error.** The file holds one word; anything else is a botched write, not a value to guess at. |
| 5 | **Trimmed contents are a single token that is not a known profile** (`full`, `none`, `agent`, `AGENTIC`, `Bare`, …) | **Error.** No fuzzy matching, no case folding. |
| 6 | **File is not a regular file** — a directory, FIFO, socket, or a broken symlink | **Error.** |
| 7 | **File contents are not valid UTF-8** | **Error.** |

### Whitespace handling (rule 2 in detail)

Leading and trailing whitespace is trimmed before the value is evaluated.
"Whitespace" is the ASCII set space, tab, newline (`\n`), carriage return
(`\r`), form feed (`\f`), vertical tab (`\v`) — i.e. C-locale `[:space:]`. So
all of these resolve to `agentic`:

```
agentic
agentic\n
agentic\n\n\n
  agentic
\tagentic\t\n
```

A **trailing newline is expected and fine** — editors and `printf '%s\n'`
add one. What is *not* fine is whitespace *inside* the trimmed value:

```
agentic bare      → error (rule 4: two tokens)
agentic\nbare      → error (rule 4: second line)
agen tic           → error (rule 4: internal space)
```

### Case sensitivity

**Case-sensitive.** Only the lowercase spellings `bare`, `inline`, `agentic`
are valid. `AGENTIC`, `Agentic`, `BARE` all fall under rule 5 and error.

Rationale: a single canonical spelling is trivial to `grep` for and to
validate, and it means the shell reader and the Python reader do not each
need to agree on a case-folding algorithm (Unicode-aware? locale-sensitive?).
Removing that ambiguity is the entire reason this contract is written down.

### Absent vs. invalid — the load-bearing decision

**Absent resolves to `agentic`. Invalid never does.**

An absent file is the normal state of every checkout made before this feature
existed, so it has to keep meaning "full behaviour". But an existing file that
is empty, truncated, multi-line, or holds an unrecognised word is *evidence of
a problem* — a crashed writer, a half-finished manual edit, a disk-full
truncation, a merge artifact. Resolving any of those to `agentic` would
**fail open into the most-privileged profile**: exactly the wrong direction
for a feature whose purpose is to *withhold* AI tooling on request.

So invalid input **fails loudly** — the reader errors, and the caller is
expected to stop rather than proceed on a guess. It does not silently
fall back to `bare` either: a silent downgrade to the most-restrictive
profile would be almost as hard to debug as a silent upgrade, and would break
a working `agentic` checkout the first time anything ever truncated the file.
The contract's answer to "I can't tell what you meant" is to say so, not to
pick a side.

## The reader

Two implementations, identical semantics, verified against a shared table of
cases (`test_profile.py` and `test_profile.sh` exercise the same corpus):

| File | For | Entry points |
|------|-----|--------------|
| `profile.sh` | the shell; anything that can `source` a POSIX-ish bash file | `dotfiles_profile` (prints the resolved profile, or an error on stderr + return 2); `dotfiles_profile_at_least <profile>` (return 0/1/2); `dotfiles_profile_path` (prints the file path). Running the script directly (`bash profile/profile.sh`) is equivalent to `dotfiles_profile`. |
| `profile.py` | the Python linker; **and Ansible** (see below) | `resolve_profile(path=None) -> str`; `profile_at_least(current, required) -> bool`; `write_profile(name, path=None, home=None) -> bool`; constants `PROFILES`, `DEFAULT_PROFILE`, `PROFILE_RANK`; exception `ProfileError`. Running the module directly (`python3 profile/profile.py`) prints the resolved profile on stdout and exits 0, or prints `profile: <reason>` on stderr and exits **2**. `--at-least <profile>` exits 0 if satisfied, 1 if not, 2 on any read error. |

There is deliberately **no third parser**. In particular Ansible does **not**
`lookup('file', ...)` the profile and parse it in Jinja — that would be a
fourth implementation of these rules, free to drift. Instead Ansible shells
out to the Python reader and consumes its stdout / return code:

```yaml
- name: Resolve the active dotfiles profile
  ansible.builtin.command:
    cmd: python3 {{ dotfiles_dir }}/profile/profile.py
  register: _dotfiles_profile
  changed_when: false
  failed_when: _dotfiles_profile.rc != 0

- name: Record it as a fact
  ansible.builtin.set_fact:
    dotfiles_profile: "{{ _dotfiles_profile.stdout | trim }}"

# gate a task on a minimum level without re-encoding the rank table:
- name: Something that needs at least inline
  ansible.builtin.command:
    cmd: python3 {{ dotfiles_dir }}/profile/profile.py --at-least inline
  register: _needs_inline
  changed_when: false
  failed_when: _needs_inline.rc == 2   # 0 = satisfied, 1 = not, 2 = broken file
  when: ...
```

### The nvim gate: a narrow, documented exception

`nvim/lua/config/profile.lua` (added in #40) is a **fourth** implementation
of a *subset* of this contract, not a violation of "no third parser" slipped
in quietly. lazy.nvim evaluates every plugin spec's `cond` synchronously, on
every `nvim` startup, before the UI is usable — shelling out to
`python3 profile/profile.py --at-least inline` from there would add a whole
Python interpreter fork+exec to every editor launch for a check pure Lua
answers in microseconds, and would make a plugin gate hard-depend on python3
being on `PATH` at all. The exception is kept narrow on purpose:

* It feeds exactly **one boolean** (`M.at_least(tier)`, consumed by
  `nvim/lua/plugins/copilot.lua`'s `cond`) — it is never used to *write* the
  profile file, and nothing else in this repo imports it.
* It **fails closed**: absent file → `agentic` (rule 1, same as the other
  two readers), but anything it can't cleanly resolve to one of
  `bare`/`inline`/`agentic` (empty, multi-token, unreadable, not a plain
  file) is treated as invalid → `copilot.lua` does not load, and a warning
  is printed via `vim.notify`. It does not distinguish *why* a file is
  invalid the way `profile.py`/`profile.sh` do (their separate messages for
  "empty" vs "multi-token" vs "bad UTF-8" collapse here) — every one of
  those cases has exactly one Lua-side consumer, and they would all resolve
  to the same outcome regardless, so there is nothing to gain by keeping the
  distinctions apart on the way in.
* Because of the previous point, this reader can only ever be **stricter**
  than `profile.py`/`profile.sh`, never more permissive — it has no case
  that accepts something the real readers would reject, so it cannot
  silently load an AI plugin the contract says should be off. Full detail
  and the case-by-case contract mapping live in the module's own docstring.

## Security: symlink-ancestry check on write

Established by issue #29 for this repo: any state-marker file that gets
*written* must have its ancestry checked for attacker-planted symlinks
**before** any `mkdir(parents=True)` or write. The attack is a symlink dropped
at, say, `~/.config` (or `~/.config/dotfiles`) that redirects the write to an
arbitrary file the attacker chooses.

The `profile` file is exactly such a state marker — it is written by the
`dotfiles profile <name>` CLI (`tools/dotfiles.py`, #40), which calls
`write_profile()` here and nowhere else. So `write_profile()`:

1. Validates the requested name against `PROFILES` first (invalid name raises
   `ProfileError`, nothing touches the filesystem).
2. Walks every path component from the file's parent directory up to **and
   including `$HOME`**, calling `is_symlink()` on each, and checks the file
   path itself. This happens **before** `mkdir` and **before** the write.
3. If any component is a symlink: **warn on stderr and skip the write**,
   returning `False`. It does **not** raise and does **not** abort the
   caller — the CLI is expected to surface the warning and carry on.
4. Only if the ancestry is clean does it `mkdir(parents=True, exist_ok=True)`
   the parent and write atomically (temp file in the same directory +
   `os.replace`), so a reader never sees a half-written value.

The walk itself (`_first_symlinked_ancestor()`) lives here too and is the
**one** implementation of it in this repo: `install.py`'s install-receipt
write (`~/.local/state/dotfiles/install-root`, a second, unrelated
state-marker file) imports and calls it rather than keeping its own copy, so
there is exactly one issue-#29 ancestry walk for both call sites to drift
out of sync with.

The **readers** (`resolve_profile`, `dotfiles_profile`) do not fail on a
symlinked ancestor — a read cannot be turned into an arbitrary-file
overwrite, and users legitimately symlink `~/.config`. They do print a
one-line warning on stderr when the file or an ancestor up to `$HOME` is a
symlink, then return the value as normal.
