/**
 * Replays Claude Code hooks inside opencode.
 *
 * WHY a bridge and not N ported plugins: opencode has no hooks config of any kind -- the only
 * extension point is a TypeScript module. Hand-porting each plugin's hook logic would mean
 * maintaining a second copy of behaviour that upstream keeps changing. Instead this runs the
 * SAME handler executables Claude Code runs, driven by claude-hooks.json, which
 * scripts/gen_opencode.py derives from each plugin's own hooks.json. One bridge, regenerated
 * config -- adding a plugin needs no code change here.
 *
 * Fidelity is partial by construction, and the gaps are deliberate:
 *   - PreCompact has no opencode analogue; the generator drops it.
 *   - A handler's exit code cannot BLOCK a tool call. Claude's PreToolUse can veto; opencode's
 *     tool.execute.before cannot (only permission.ask can, and it carries no handler output).
 *     So handlers run for their side effects and their context, never as a gate.
 *   - Handlers must not be trusted to be fast: each is capped, because opencode awaits these
 *     hooks inline and a hung handler would wedge the session rather than just delay it.
 */
import type { Plugin } from "@opencode-ai/plugin"
import { homedir } from "os"
import { join } from "path"
import { readFileSync, existsSync } from "fs"

type Entry = { plugin: string; root: string; matcher?: string | null; command: string }
type Manifest = Record<string, Entry[]>

const MANIFEST = join(homedir(), ".config/opencode/claude-hooks.json")

/**
 * opencode names tools lowercase ("edit"); Claude matchers are written against its own
 * capitalised names ("Edit|Write"). Without this mapping every matcher silently fails to
 * match and the hooks appear installed but never fire -- the exact failure that is hardest
 * to notice, since nothing errors.
 */
const TOOL_NAMES: Record<string, string> = {
  bash: "Bash", edit: "Edit", write: "Write", read: "Read", glob: "Glob",
  grep: "Grep", list: "LS", patch: "MultiEdit", task: "Task",
  webfetch: "WebFetch", todowrite: "TodoWrite", todoread: "TodoRead",
}

const HOOK_TIMEOUT_MS = 10_000

function load(): Manifest {
  if (!existsSync(MANIFEST)) return {}
  try {
    return JSON.parse(readFileSync(MANIFEST, "utf8")) as Manifest
  } catch {
    // A malformed manifest must not take the session down with it -- degrade to no hooks.
    return {}
  }
}

function matches(entry: Entry, toolName?: string): boolean {
  if (!entry.matcher) return true
  if (!toolName) return true
  try {
    return new RegExp(entry.matcher).test(toolName)
  } catch {
    return false
  }
}

/**
 * Run one handler with a Claude-shaped payload on stdin and return any additionalContext.
 * CLAUDE_PLUGIN_ROOT is re-exported because handlers resolve their own sibling scripts
 * through it even though the generator already expanded it inside the command string.
 */
async function run(entry: Entry, payload: Record<string, unknown>): Promise<string | null> {
  try {
    const proc = Bun.spawn(["bash", "-lc", entry.command], {
      stdin: new TextEncoder().encode(JSON.stringify(payload)),
      stdout: "pipe",
      stderr: "ignore",
      env: { ...process.env, CLAUDE_PLUGIN_ROOT: entry.root },
    })
    const timer = setTimeout(() => proc.kill(), HOOK_TIMEOUT_MS)
    const out = await new Response(proc.stdout).text()
    clearTimeout(timer)
    await proc.exited
    if (!out.trim()) return null
    try {
      const j = JSON.parse(out)
      return j?.hookSpecificOutput?.additionalContext ?? j?.systemMessage ?? null
    } catch {
      // Handlers that print plain text (rather than the JSON protocol) still carry context.
      return out.trim()
    }
  } catch {
    return null
  }
}

async function fire(
  manifest: Manifest, event: string, payload: Record<string, unknown>, toolName?: string,
): Promise<string[]> {
  const entries = (manifest[event] ?? []).filter((e) => matches(e, toolName))
  const out = await Promise.all(entries.map((e) => run(e, { ...payload, hook_event_name: event })))
  return out.filter((x): x is string => !!x)
}

export const ClaudeHooksBridge: Plugin = async ({ directory }) => {
  const manifest = load()
  // SessionStart has no opencode hook, so it is emulated on the first message of each session.
  const started = new Set<string>()

  return {
    "chat.message": async ({ sessionID }, output) => {
      const base = { session_id: sessionID, cwd: directory, transcript_path: "" }
      const context: string[] = []

      if (!started.has(sessionID)) {
        started.add(sessionID)
        // "startup" is the only source these matchers can truthfully see; opencode exposes no
        // resume/clear/compact distinction, so the compact-triggered variants never replay.
        context.push(...await fire(manifest, "session.start", { ...base, source: "startup" }))
      }
      const text = output.parts.filter((p) => p.type === "text").map((p: any) => p.text).join("\n")
      context.push(...await fire(manifest, "chat.message", { ...base, prompt: text }))

      // Prepend into the EXISTING text part rather than pushing new ones. A synthesized part
      // is rejected at runtime: opencode's Part schema requires id/sessionID/messageID, and a
      // partial object fails validation ("SchemaError: Missing key at [\"id\"]") and then the
      // durable-event write ("Expected string aggregate field sessionID"), which surfaces to
      // the user as an opaque "UnknownError: Unexpected server error". Reusing an already-valid
      // part keeps those ids intact and needs no id generation.
      if (context.length) {
        const target = output.parts.find((p) => p.type === "text") as { text: string } | undefined
        if (target) target.text = context.join("\n\n") + "\n\n" + target.text
      }
    },

    "tool.execute.before": async ({ tool, sessionID }, output) => {
      await fire(manifest, "tool.execute.before",
        { session_id: sessionID, cwd: directory, tool_name: TOOL_NAMES[tool] ?? tool, tool_input: output.args },
        TOOL_NAMES[tool] ?? tool)
    },

    "tool.execute.after": async ({ tool, sessionID }, output) => {
      await fire(manifest, "tool.execute.after",
        { session_id: sessionID, cwd: directory, tool_name: TOOL_NAMES[tool] ?? tool, tool_response: output },
        TOOL_NAMES[tool] ?? tool)
    },

    event: async ({ event }) => {
      // Stop / SessionEnd analogues. session.idle is the closest thing to Claude's Stop: the
      // model has finished and is awaiting input.
      const id = (event as any)?.properties?.sessionID ?? ""
      if (event.type === "session.idle") {
        await fire(manifest, "session.idle", { session_id: id, cwd: directory })
      }
      if (event.type === "session.deleted") {
        await fire(manifest, "session.end", { session_id: id, cwd: directory, reason: "exit" })
        started.delete(id)
      }
    },
  }
}
