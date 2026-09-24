-- Minimal Lua reader for the dotfiles `profile` file contract
-- (profile/README.md at the repo root). Feeds exactly one decision today:
-- lazy.nvim plugin specs' `cond` -- "is the active profile at least
-- <tier>?" -- see nvim/lua/plugins/copilot.lua.
--
-- WHY THIS IS A FOURTH IMPLEMENTATION, DELIBERATELY:
--
-- profile/README.md is explicit that there is "deliberately no third
-- parser" -- Ansible shells out to profile/profile.py rather than
-- re-implementing the rules in Jinja, specifically so the shell, Python and
-- Ansible readers can never drift apart on an edge case. This module is a
-- documented, narrow exception to that rule, not a quiet violation of it:
--
--   * lazy.nvim evaluates every plugin spec's `cond` synchronously, on
--     every nvim startup, before the UI is usable. Shelling out to `python3
--     profile/profile.py --at-least inline` from here (the alternative that
--     WOULD keep this at "no third parser") adds a fork+exec of a whole
--     Python interpreter to every single `nvim` launch -- tens of
--     milliseconds of a real, user-visible startup regression, and a hard
--     dependency on python3 being on PATH at all, for a check that a dozen
--     lines of the Lua nvim already has loaded can answer in microseconds.
--   * The blast radius of this reader being wrong is small and asymmetric:
--     it feeds exactly one boolean (load copilot.lua or don't), it is never
--     used to WRITE the profile file, and it fails closed (see below) --
--     the worst case of a bug here is "copilot didn't load when it should
--     have", never "the wrong profile got written" or "an unrelated tool
--     silently disagrees about the active profile".
--   * It intentionally does NOT reimplement every rule profile/profile.py
--     and profile/profile.sh enforce (UTF-8 validation, "not a regular
--     file" vs "empty" vs "multi-token" as distinct error messages, ...).
--     Every one of those distinctions collapses to the same outcome here --
--     "not a clean single known token -> don't load copilot" -- because
--     that is the only distinction this reader's one caller needs. A
--     mismatch between this reader and the real ones can only ever be
--     "this one is stricter", never "this one accepts something the real
--     readers would reject" (see M.resolve() below) -- so it can't silently
--     load an AI plugin the contract says should be off.
--
-- Contract subset implemented: file absent -> "agentic" (rule 1); file
-- present, trims to exactly one of bare/inline/agentic -> that value (rules
-- 2-5); anything else (empty, multi-token, unreadable, not a plain file) ->
-- treated as invalid, same fail-closed outcome as a genuinely unknown word.

local M = {}

local RANK = { bare = 0, inline = 1, agentic = 2 }

local function profile_path()
  local xdg = vim.env.XDG_CONFIG_HOME
  local config_home = (xdg ~= nil and xdg ~= "") and xdg or (vim.env.HOME .. "/.config")
  return config_home .. "/dotfiles/profile"
end

-- Returns the resolved profile name, or nil plus a human-readable reason.
-- Never raises -- a corrupt profile file must not be able to crash nvim
-- startup, only degrade it to "copilot doesn't load".
function M.resolve()
  local path = profile_path()
  local uv = vim.uv or vim.loop
  local stat = uv.fs_stat(path)

  -- Rule 1: genuinely absent -> default. fs_stat() already follows a
  -- symlink and returns nil for a broken one, so a broken symlink correctly
  -- falls through to the "present but unreadable" branch below instead of
  -- silently defaulting to agentic.
  if stat == nil then
    return "agentic"
  end
  if stat.type ~= "file" then
    return nil, ("%s is not a regular file"):format(path)
  end

  local fh = io.open(path, "r")
  if fh == nil then
    return nil, ("could not open %s"):format(path)
  end
  local raw = fh:read("*a")
  fh:close()
  if raw == nil then
    return nil, ("could not read %s"):format(path)
  end

  -- Trim ASCII whitespace only, matching profile.py's C-locale [:space:]
  -- set (space, tab, \n, \r, \f, \v) -- Lua patterns don't have a portable
  -- \s, so this is spelled out explicitly rather than assumed equivalent.
  local value = raw:gsub("^[ \t\n\r\f\v]+", ""):gsub("[ \t\n\r\f\v]+$", "")

  if value == "" then
    return nil, ("%s is empty"):format(path)
  end
  if value:find("[ \t\n\r\f\v]") then
    return nil, ("%s contains more than one token"):format(path)
  end
  if RANK[value] == nil then
    return nil, ("unknown profile '%s' in %s"):format(value, path)
  end
  return value
end

-- True iff the active profile is at or above `required` in the bare < inline
-- < agentic nesting. Fails CLOSED on any read/parse problem -- warns once via
-- vim.notify and returns false, rather than erroring nvim startup. "Don't
-- load the AI plugin" is always the safe direction for a state file this
-- reader can't make sense of; "load it anyway" never is.
function M.at_least(required)
  local active, err = M.resolve()
  if active == nil then
    vim.notify(
      "dotfiles profile: " .. err .. " -- treating as invalid; not loading AI-gated plugins.",
      vim.log.levels.WARN
    )
    return false
  end
  return RANK[active] >= RANK[required]
end

return M
