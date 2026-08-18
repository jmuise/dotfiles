// Kilo tool.execute.before guard -- ports claude/hooks/require-devcontainer.sh's
// enforcement to Kilo. This file is a THIN SHIM and must stay one: it maps
// Kilo's tool-call shape onto the JSON payload require-devcontainer.sh already
// expects on stdin, spawns that script, and defers to its exit code for every
// decision. It holds no git/marker/container-detection/allowlist logic of its
// own, and it must never grow any -- see tools/sync-agent.sh and the
// claude-config-scoping skill for why a second implementation of the same rule
// is a standing anti-pattern in this repo. Two copies always drift, and a
// drift here means either spurious blocks or -- far worse -- a silent bypass
// of the one guard that keeps agent work off the bare host.
//
// Loaded via Kilo's plugin-directory auto-discovery: install.py symlinks
// ~/.config/kilo/plugin -> this directory (see install.py's Kilo Code
// section), and kilo.jsonc also lists this file explicitly in its `plugin`
// array. Both point at the same file, so Kilo's own dedup-by-path collapses
// them to a single load -- the explicit entry exists to keep the wiring
// visible in kilo.jsonc rather than depending solely on directory discovery.
// Confirmed empirically: a relative entry in kilo.jsonc's `plugin` array
// resolves against the *literal* (symlinked) path of the config file, not its
// realpath -- so without that directory symlink in place, this file would
// silently fail to load (no error, no log line, hook just never fires).
//
// KNOWN, INTENTIONAL LIMITATION: unlike the Claude Code hook, this port has no
// chief-engineer exemption. `agent_type` below is hardcoded to "kilo" and
// never a value the bash script treats as exempt ("chief-engineer" is the
// only one it recognizes). Kilo has no bootstrap/provisioning agent identity
// of its own -- only `number-one` is mirrored into kilo/.kilo/agents/ -- so
// there is no Kilo-side equivalent of chief-engineer's host-bootstrap role.
// Do not invent one here. If Kilo ever needs a provisioning path onto the
// host, that is a decision for the Captain, not a default this shim assumes.
import type { Plugin } from "@kilocode/plugin"
import { spawnSync } from "node:child_process"
import { homedir } from "node:os"

// require-devcontainer.sh only branches on "Bash" vs. everything else in
// {Edit, Write, NotebookEdit} -- it has no per-file-tool logic. So Kilo's
// three file-mutation tools (edit, write, apply_patch) all map to the same
// "Edit" value; any one of them takes the identical path through the script.
const TOOL_MAP: Record<string, "Bash" | "Edit"> = {
  bash: "Bash",
  edit: "Edit",
  write: "Edit",
  apply_patch: "Edit",
}

const RequireDevcontainer: Plugin = async (ctx) => {
  // Captured once per session at plugin-load time -- "current working
  // directory for this session" per Kilo's plugin docs. This is the right
  // fallback for Bash: require-devcontainer.sh judges Bash purely by session
  // cwd anyway (a `cd` inside the command string isn't resolvable from a
  // hook either way), so a per-session value loses nothing relative to what
  // the script already expects.
  const sessionDirectory = ctx.directory

  return {
    "tool.execute.before": async (input, output) => {
      const mapped = TOOL_MAP[input.tool]
      if (!mapped) return // not a shell or file-mutation tool -- out of scope

      const args = output?.args ?? {}

      // Some bash calls (observed on task-delegated subagent calls) carry
      // their own `workdir`, which is a more precise cwd than the
      // session-wide one for that specific call. Prefer it when present.
      const cwd = (typeof args.workdir === "string" && args.workdir) || sessionDirectory

      // edit/write carry a top-level `filePath`, confirmed empirically. But
      // apply_patch does not: it's only exposed at all when the underlying
      // provider is OpenAI's Responses API with native apply_patch support
      // (gated internally on hasApplyPatchTool), and its args come through
      // as `{ callId, operation: { type, path, diff } }` -- the path lives
      // at `operation.path`, confirmed by decompiling the installed
      // @kilocode/cli bundle (no live model in this environment could
      // actually be made to emit an apply_patch call to confirm at runtime:
      // every OpenAI-family model available required sign-in/credits this
      // environment doesn't have, and the one free model tried explicitly
      // reported back "I don't have an apply_patch tool available"). Try
      // both rather than assume either is missing, so a future shape this
      // shim hasn't seen still has a chance of resolving instead of
      // silently degrading `target` to "." inside the script below.
      const filePath = typeof args.filePath === "string" ? args.filePath : args.operation?.path

      const payload =
        mapped === "Bash"
          ? { tool_name: mapped, agent_type: "kilo", cwd, tool_input: { command: args.command } }
          : { tool_name: mapped, agent_type: "kilo", cwd, tool_input: { file_path: filePath } }

      const home = process.env.HOME || homedir()
      const script = `${home}/.claude/hooks/require-devcontainer.sh`

      const result = spawnSync("bash", [script], {
        input: JSON.stringify(payload),
        encoding: "utf8",
        timeout: 15_000,
        // Anchor the script's own process cwd to the same directory we
        // computed above. require-devcontainer.sh only reads `cwd` from the
        // JSON payload for Bash; for file tools it derives `target` purely
        // from `tool_input.file_path` and falls back to "." when that's
        // missing or empty (an undocumented/renamed args field, a future
        // tool this map doesn't cover yet), at which point its `git -C "."`
        // resolves against *this* process's cwd. Without this, that would
        // silently be wherever the Kilo server itself was launched from --
        // not necessarily the delegated call's actual target -- and the
        // guard could check the wrong project's container/exemption status.
        cwd,
      })

      // Fail closed on anything but a clean allow (status 0). A spawn
      // failure, a missing script, a timeout (status null + signal set), or
      // an exit code the script never documented are all treated as a block
      // rather than let through -- mirroring d53a8a9's hardening of the
      // sibling hooks. A guard that silently stops guarding because of a
      // shim-level bug is worse than one that over-blocks.
      if (result.error) {
        throw new Error(
          `BLOCKED by kilo/plugin/require-devcontainer.ts: failed to run ${script}: ${result.error.message}. Refusing rather than letting this call through with the guard unable to run.`,
        )
      }
      if (result.status === 2) {
        throw new Error((result.stderr || "").trim() || "BLOCKED by require-devcontainer.sh (no stderr captured)")
      }
      if (result.status !== 0) {
        throw new Error(
          `BLOCKED by kilo/plugin/require-devcontainer.ts: require-devcontainer.sh exited ${String(result.status)} (expected 0 or 2), signal=${String(result.signal)}. stderr: ${(result.stderr || "").trim()}. Refusing rather than letting this call through with the guard in an unexpected state.`,
        )
      }
      // status === 0 -> allow. Return normally.
    },
  }
}

export default { id: "require-devcontainer", server: RequireDevcontainer }
