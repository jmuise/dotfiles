-- Copilot inline completion, profile-gated to `inline` and above
-- (profile/README.md: `bare` carries no AI config or plugins at all;
-- `inline` adds editor completion plugins as one of its two additions over
-- `bare`, see issue #40).
--
-- Uses lazy.nvim's `cond` rather than `enabled` or wrapping this whole
-- return value in a manual `if`:
--
--   * `cond = false` means "installed (present in nvim/lazy-lock.json,
--     cloned, kept up to date), but not loaded/sourced this session".
--     `enabled = false` goes further and excludes the plugin from the spec
--     entirely -- not installed, not lockfile-tracked. nvim/lazy-lock.json
--     is committed to this repo and shared across every profile on every
--     machine that links nvim/ (install.py's `link()`, unconditional --
--     nvim itself is not profile-gated the way ~/.claude etc. are, only
--     this one plugin's *loading* is). If the active profile at the moment
--     someone last ran `:Lazy sync` controlled whether copilot.lua's pin
--     even exists in the lockfile, the committed lockfile would silently
--     drift depending on which machine/profile happened to sync it last --
--     a `bare` sync would want to DELETE the pin, an `agentic` one would
--     want to ADD it back. `cond` sidesteps that entirely: the plugin is
--     always installed and always lockfile-pinned, identically regardless
--     of profile, and only whether it actually LOADS varies. That is also
--     the cheaper failure mode if this reader is ever wrong (see
--     nvim/lua/config/profile.lua) -- worst case a `:Lazy sync` still
--     touches the plugin's install, never its lockfile pin.
--   * A manual `if profile.at_least("inline") then return {...} else return
--     {} end` around the whole file achieves the same *load* outcome, but
--     lazy.nvim's own `cond` field exists precisely so a spec can be
--     unconditionally present (browsable via `:Lazy`, consistently
--     lockfile-pinned) while still being conditionally loaded -- using the
--     field lazy.nvim ships for this is what "no errors under `bare`"
--     actually rests on: it is lazy.nvim's own tested code path, not a
--     hand-rolled one that has to reimplement lazy.nvim's own
--     "excluded-but-still-known" bookkeeping.
--
-- No parsing logic lives in this file; nvim/lua/config/profile.lua is the
-- one gate reader, same "no second parser" discipline profile/README.md
-- asks of every other consumer.
return {
  "zbirenbaum/copilot.lua",
  -- Pinned to the latest tagged release as of this writing. This `version`
  -- field is a hint to lazy.nvim's resolver, not the source of truth --
  -- nvim/lazy-lock.json is authoritative for the exact commit every
  -- machine actually installs (see the discussion above); update both
  -- together via `:Lazy update`.
  version = "v3.1.9",
  cond = function()
    return require("config.profile").at_least("inline")
  end,
  cmd = "Copilot",
  event = "InsertEnter",
  opts = {
    suggestion = { enabled = true, auto_trigger = true },
    panel = { enabled = true },
  },
}
