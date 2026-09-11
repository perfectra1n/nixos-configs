"""Generate opencode's config from the Claude Code setup this repo already tracks.

WHY this exists: opencode and Claude Code overlap almost entirely in capability but share
almost no file formats, so "keep my two agents at parity" is a translation problem, not a
copy problem. Hand-maintaining a second config would drift the first time a server or plugin
is added -- exactly the "both channels must agree" failure docs/mcp-servers.md warns about.
So the Claude artifacts stay the single source of truth and this script derives opencode's.

Four translations, each forced by a verified incompatibility (see docs/opencode.md):
  1. MCP    -- Claude expands ${VAR}; opencode expands {env:VAR}. Same secrets.fish vars,
               different syntax, so the file cannot simply be shared.
  2. agents -- opencode derives the agent name from the FILENAME and ignores `name:`, so
               entries are namespaced <plugin>-<agent> (feature-dev and pr-review-toolkit
               both ship a `code-reviewer`; unnamespaced they would silently collide).
  3. skills -- opencode reads ~/.claude/skills natively but NOT the plugin cache, and
               skills.paths does not expand globs. Hence the symlink farm, whose rebuild
               lives in the chezmoi run_after_ script (paths carry plugin version hashes).
  4. hooks  -- opencode has no hooks config at all; see the bridge plugin.

PURITY: this script only reads and transforms. It never executes a plugin hook handler and
never touches $HOME -- output goes to the chezmoi SOURCE under dotfiles/, and reaches
~/.config/opencode only via `chezmoi apply`. That is what makes --check a meaningful
idempotency gate in CI: a second run must produce a byte-identical tree.
"""

import argparse
import json
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOME = os.path.expanduser("~")

CLAUDE_MCP = os.path.join(REPO, "dotfiles/dot_config/claude/mcp.json")
CLAUDE_SETTINGS = os.path.join(REPO, "dotfiles/dot_claude/settings.json")
INSTALLED = os.path.join(HOME, ".claude/plugins/installed_plugins.json")
OUT = os.path.join(REPO, "dotfiles/dot_config/opencode")

# The farm the chezmoi run_after_ script rebuilds. {env:HOME} rather than "~" because opencode
# interpolates env vars but does NOT expand tilde in skills.paths.
FARM = "{env:HOME}/.local/share/opencode-claude-skills"

# Claude's ${VAR} / ${VAR:-default}. opencode has no default syntax, so the default is
# DISCARDED and the bare var kept -- every var we translate is set by secrets.fish, and a
# silently-wrong fallback URL is worse than an empty one (which fails loudly at connect).
VAR_RE = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)(?::-[^}]*)?\}")

# Claude's `model` is a bare alias ("opus[1m]"); opencode needs "provider/model" and the
# gateway publishes concrete ids. Derived from the tracked settings.json rather than hardcoded
# so the two agents stay on the same tier. WHY this must be set at all: with no `model` key
# opencode falls back to ITS OWN default (claude-sonnet-4-6), which the Lupina pool rejects
# with 429 "Usage credits are required for long context requests" -- and opencode reports that
# as "Service Unavailable" and retries forever, so the symptom is an infinite hang, not an error.
MODEL_MAP = {"opus": "claude-opus-5", "sonnet": "claude-sonnet-5",
             "haiku": "claude-haiku-4-5-20251001"}
# Title generation and other cheap calls. Haiku is verified available on the gateway.
SMALL_MODEL = "anthropic/claude-haiku-4-5-20251001"


def pick_model(settings):
    """Map Claude's model alias onto a gateway model id, defaulting to opus."""
    alias = str(settings.get("model", "opus")).lower()
    for key, model in MODEL_MAP.items():
        if alias.startswith(key):
            return "anthropic/" + model
    return "anthropic/" + MODEL_MAP["opus"]


# Claude writes plain colour NAMES; opencode accepts only #RRGGBB or one of its SEMANTIC
# names, and hard-fails startup on anything else (it refused to boot on `color: red`). Mapped
# by meaning rather than hue so the intent survives; anything unrecognised is dropped, since a
# missing colour is cosmetic but a wrong value is fatal.
COLOR_MAP = {
    "red": "error", "green": "success", "blue": "info", "cyan": "info",
    "yellow": "warning", "orange": "warning", "purple": "accent",
    "magenta": "accent", "pink": "accent", "gray": "secondary", "grey": "secondary",
    "white": "primary", "black": "secondary",
}

# macOS-only, so it can never work on any host in this flake. Skipped with a note rather than
# emitted broken -- see docs/opencode.md.
SKIP_HOOKS = {"datadog@claude-plugins-official"}

# Claude hook event -> opencode Hooks key. PreCompact has no opencode analogue and is dropped.
EVENT_MAP = {
    "UserPromptSubmit": "chat.message",
    "PreToolUse": "tool.execute.before",
    "PostToolUse": "tool.execute.after",
    "SessionStart": "session.start",
    "Stop": "session.idle",
    "SessionEnd": "session.end",
}


def interpolate(value):
    """Rewrite Claude's ${VAR} into opencode's {env:VAR}, recursing through containers."""
    if isinstance(value, str):
        return VAR_RE.sub(lambda m: "{env:%s}" % m.group(1), value)
    if isinstance(value, dict):
        return {k: interpolate(v) for k, v in value.items() if k != "//"}
    if isinstance(value, list):
        return [interpolate(v) for v in value]
    return value


def plugin_roots(settings):
    """Map enabled plugin key -> on-disk root.

    A `directory`-source marketplace is resolved LIVE, not through the plugin cache: the cache
    copy is a snapshot taken at install time and goes stale silently. Verified on this box --
    custom-claude-skills had 1 skill cached vs 6 in the working tree, so trusting installPath
    would have quietly dropped five skills.
    """
    installed = json.load(open(INSTALLED))["plugins"]
    markets = settings.get("extraKnownMarketplaces", {})
    roots, notes = {}, []
    for key, on in sorted(settings.get("enabledPlugins", {}).items()):
        if not on:
            continue
        plugin, _, market = key.partition("@")
        src = markets.get(market, {}).get("source", {})
        if src.get("source") == "directory":
            live = os.path.join(src["path"], plugin)
            # Some directory marketplaces are the plugin itself rather than a parent of it.
            if not os.path.isdir(live):
                live = src["path"]
            if os.path.isdir(live):
                roots[key] = live
                notes.append("%s: live directory source" % key)
                continue
        entries = installed.get(key)
        if not entries:
            notes.append("%s: SKIPPED (enabled but not installed)" % key)
            continue
        roots[key] = entries[0]["installPath"]
    return roots, notes


def split_frontmatter(text):
    """Return (frontmatter dict-ish lines, body). Deliberately line-based, not a YAML parse.

    Claude frontmatter values routinely contain colons and quotes inside long description
    prose; a naive YAML load mangles them and a real YAML dep is not worth pulling into a
    writePython3Bin. Only top-level `key: value` lines matter for translation.
    """
    if not text.startswith("---"):
        return {}, text
    end = text.find("\n---", 3)
    if end == -1:
        return {}, text
    head, body = text[3:end], text[end + 4:]
    fields = {}
    for line in head.splitlines():
        if line[:1] in ("", " ", "\t", "#"):
            continue
        k, sep, v = line.partition(":")
        if sep:
            fields[k.strip()] = v.strip()
    return fields, body.lstrip("\n")


def yaml_quote(s):
    """Quote a scalar for YAML. Descriptions carry colons, quotes and newline escapes."""
    return json.dumps(s)


def convert_agent(plugin, name, text):
    """Claude subagent -> opencode agent markdown.

    Two fields are deliberately DROPPED rather than guessed:
      model -- Claude uses bare aliases ("opus"); opencode needs "provider/model" and the
               gateway's exact model ids are not knowable here. Dropping makes the agent
               inherit the session model, which is the intended one.
      tools -- Claude's list is an ALLOWlist; opencode's `tools` map defaults everything to
               true, so reproducing a restriction needs an explicit false for every tool not
               listed, against a tool set that differs between the two. A partial map would
               silently widen access, so it is omitted and documented as a parity gap.
    """
    fields, body = split_frontmatter(text)
    desc = fields.get("description") or "%s agent from %s" % (name, plugin)
    out = ["---",
           "description: %s" % yaml_quote(desc),
           # Every Claude agents/*.md is a subagent; opencode defaults to primary.
           "mode: subagent"]
    color = fields.get("color", "").strip().lower()
    if color.startswith("#") and len(color) == 7:
        out.append("color: %s" % color)
    elif color in COLOR_MAP:
        out.append("color: %s" % COLOR_MAP[color])
    out += ["---", "", body.rstrip(), ""]
    return "\n".join(out)


def convert_command(plugin, name, text):
    """Claude slash command -> opencode command markdown.

    `allowed-tools` is dropped (opencode governs tool access with global permission rules,
    not per-command), as is `disable-model-invocation`. $ARGUMENTS means the same in both.
    """
    fields, body = split_frontmatter(text)
    desc = fields.get("description") or "%s command from %s" % (name, plugin)
    out = ["---", "description: %s" % yaml_quote(desc), "---", "", body.rstrip(), ""]
    return "\n".join(out)


def collect_mcp(roots):
    """Remote servers from the tracked mcp.json + stdio/http servers shipped inside plugins."""
    servers = {}
    claude = json.load(open(CLAUDE_MCP))
    for name, block in sorted(claude.get("mcpServers", {}).items()):
        b = interpolate(block)
        b["type"] = "remote" if b.get("type") == "http" else b.get("type", "remote")
        servers[name] = b

    for key, root in sorted(roots.items()):
        path = os.path.join(root, ".mcp.json")
        if not os.path.exists(path):
            continue
        raw = json.load(open(path))
        # Two shapes in the wild: {"mcpServers": {...}} (memini) and a bare map (playwright).
        blocks = raw.get("mcpServers", {k: v for k, v in raw.items() if k != "//"})
        for name, block in sorted(blocks.items()):
            if name in servers:
                continue
            b = interpolate({k: v for k, v in block.items() if k != "//"})
            if b.get("type") == "http" or "url" in b:
                b["type"] = "remote"
                # Claude-only dynamic-header shell hook; opencode has no equivalent. Its own
                # documented fallback is a plain bearer, so emit that.
                if b.pop("headersHelper", None) and not b.get("headers"):
                    b["headers"] = {
                        "Authorization": "Bearer {env:%s_API_KEY}" % name.upper()
                    }
            else:
                cmd = [b.pop("command")] + list(b.pop("args", []))
                b = {"type": "local",
                     "command": [c.replace("${CLAUDE_PLUGIN_ROOT}", root) for c in cmd],
                     "environment": b.get("env", {})}
                if not b["environment"]:
                    b.pop("environment")
            servers[name] = b
    return servers


def collect_hooks(roots):
    """Build the manifest the bridge plugin replays. Pure: handlers are NOT run here."""
    manifest, notes = {}, []
    for key, root in sorted(roots.items()):
        if key in SKIP_HOOKS:
            notes.append("%s: hooks skipped (macOS-only)" % key)
            continue
        path = os.path.join(root, "hooks/hooks.json")
        if not os.path.exists(path):
            path = os.path.join(root, "hooks/hooks.claude.json")
        if not os.path.exists(path):
            continue
        spec = json.load(open(path)).get("hooks", {})
        for event, groups in sorted(spec.items()):
            target = EVENT_MAP.get(event)
            if not target:
                notes.append("%s: %s has no opencode analogue (dropped)" % (key, event))
                continue
            for group in groups:
                for h in group.get("hooks", []):
                    if h.get("type") != "command":
                        continue
                    cmd = h["command"]
                    if h.get("args"):
                        cmd = " ".join([cmd] + ['"%s"' % a for a in h["args"]])
                    manifest.setdefault(target, []).append({
                        "plugin": key,
                        "root": root,
                        "matcher": group.get("matcher"),
                        "command": cmd.replace("${CLAUDE_PLUGIN_ROOT}", root),
                    })
    return manifest, notes


def build(roots, settings):
    """Produce the full output tree in memory: path -> file contents."""
    files = {}
    agents = commands = 0
    for key, root in sorted(roots.items()):
        plugin = key.partition("@")[0]
        for src in sorted(_glob_md(os.path.join(root, "agents"))):
            name = os.path.basename(src)[:-3]
            files["agent/%s-%s.md" % (plugin, name)] = convert_agent(
                plugin, name, open(src).read())
            agents += 1
        for src in sorted(_glob_md(os.path.join(root, "commands"))):
            name = os.path.basename(src)[:-3]
            files["command/%s-%s.md" % (plugin, name)] = convert_command(
                plugin, name, open(src).read())
            commands += 1

    hooks, hook_notes = collect_hooks(roots)
    files["claude-hooks.json"] = json.dumps(hooks, indent=2, sort_keys=True) + "\n"

    config = {
        "$schema": "https://opencode.ai/config.json",
        "model": pick_model(settings),
        "small_model": SMALL_MODEL,
        # EXPLICIT, not ambient. This box exports a real ANTHROPIC_API_KEY *and* the gateway
        # pair; opencode's auto-detection picks the API key, which would silently bill the
        # direct account while Claude Code goes through the gateway. Pinning both ends that.
        "provider": {
            "anthropic": {
                "options": {
                    # The "/v1" suffix is LOAD-BEARING. ANTHROPIC_BASE_URL is the bare gateway
                    # origin (Claude Code appends the version segment itself), but the AI SDK
                    # provider opencode uses appends only "/messages" -- so without this it
                    # POSTs to BASE/messages, which the gateway's web UI answers with HTTP 200
                    # and an HTML body. The SDK cannot parse that, reports it as
                    # "AI_APICallError: Service Unavailable", and retries forever, so the
                    # symptom is an infinite hang with no failing status code anywhere.
                    "baseURL": "{env:ANTHROPIC_BASE_URL}/v1",
                    "apiKey": "{env:ANTHROPIC_AUTH_TOKEN}",
                },
            },
        },
        "mcp": collect_mcp(roots),
        # One stable entry. Plugin upgrades change the farm's link targets, never this file.
        "skills": {"paths": [FARM]},
        "instructions": ["CLAUDE.md", "AGENTS.md"],
        "plugin": ["./plugin/claude-hooks-bridge.ts"],
    }
    files["opencode.json"] = json.dumps(config, indent=2, sort_keys=True) + "\n"
    return files, {"agents": agents, "commands": commands,
                   "mcp": len(config["mcp"]), "hook_events": len(hooks),
                   "notes": hook_notes}


def _glob_md(d):
    if not os.path.isdir(d):
        return []
    return [os.path.join(d, f) for f in os.listdir(d) if f.endswith(".md")]


def write(files, check):
    """Write the tree, or in --check mode report drift without touching anything."""
    drift = []
    for rel, content in sorted(files.items()):
        dest = os.path.join(OUT, rel)
        old = open(dest).read() if os.path.exists(dest) else None
        if old != content:
            drift.append(rel)
        if not check:
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            with open(dest, "w") as fh:
                fh.write(content)
    # Prune generated files whose source plugin is gone, so a disabled plugin's agents do not
    # linger. Only the generated subdirs are swept -- plugin/ is hand-written and untouched.
    for sub in ("agent", "command"):
        d = os.path.join(OUT, sub)
        if not os.path.isdir(d):
            continue
        for f in sorted(os.listdir(d)):
            if os.path.join(sub, f) not in files:
                drift.append("%s/%s (stale)" % (sub, f))
                if not check:
                    os.remove(os.path.join(d, f))
    return drift


def self_test():
    """Pure-function tests for the translations. No filesystem, no plugin state -- so this
    runs identically in the Nix build sandbox, where $HOME holds no Claude install."""
    # ${VAR} -> {env:VAR}, including nested containers and Claude's ${VAR:-default} form,
    # whose default is intentionally discarded (see VAR_RE).
    assert interpolate("${A}") == "{env:A}"
    assert interpolate("${A:-http://localhost:8080}/mcp") == "{env:A}/mcp"
    assert interpolate({"h": {"Authorization": "Bearer ${T}"}}) == {
        "h": {"Authorization": "Bearer {env:T}"}}
    assert interpolate(["${A}", 1, None]) == ["{env:A}", 1, None]
    # opencode has no ${VAR} support, so anything we fail to translate would ship broken.
    assert "${" not in interpolate("url ${A} and ${B:-x}")
    # "//" comment keys are stripped (plugin .mcp.json files carry them).
    assert interpolate({"//": "note", "url": "${U}"}) == {"url": "{env:U}"}

    fm, body = split_frontmatter("---\nname: x\ndescription: a: b \"q\"\n---\n\nBody\n")
    assert fm["name"] == "x"
    # A colon and quotes inside description prose must survive verbatim -- this is exactly
    # what a naive YAML parse mangles, and why the split is line-based.
    assert fm["description"] == 'a: b "q"'
    assert body == "Body\n"
    assert split_frontmatter("no frontmatter")[1] == "no frontmatter"

    agent = convert_agent("p", "a", "---\nname: a\ndescription: d\nmodel: opus\n---\nB\n")
    assert "mode: subagent" in agent          # Claude agents/*.md are always subagents
    assert "model:" not in agent              # bare Claude aliases are not valid opencode ids
    assert "tools:" not in agent              # dropping beats silently widening access
    # opencode hard-fails startup on a bare colour name, so every colour we emit must be
    # either #RRGGBB or one of its semantic names. Regression: `color: red` broke boot.
    assert "color: error" in convert_agent("p", "a", "---\ndescription: d\ncolor: red\n---\nB\n")
    assert "color: success" in convert_agent("p", "a", "---\ndescription: d\ncolor: Green\n---\nB\n")
    # A missing `model` makes opencode silently fall back to a model the gateway 429s on,
    # which manifests as an infinite retry loop rather than an error. Regression guard.
    assert pick_model({"model": "opus[1m]"}) == "anthropic/claude-opus-5"
    assert pick_model({"model": "sonnet"}) == "anthropic/claude-sonnet-5"
    assert pick_model({}) == "anthropic/claude-opus-5"
    assert "color: #ff8800" in convert_agent("p", "a", "---\ndescription: d\ncolor: #ff8800\n---\nB\n")
    assert "color:" not in convert_agent("p", "a", "---\ndescription: d\ncolor: chartreuse\n---\nB\n")
    cmd = convert_command("p", "c", "---\nallowed-tools: Bash\ndescription: d\n---\nB\n")
    assert "allowed-tools" not in cmd
    assert '"d"' in cmd
    print("self-test OK")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--check", action="store_true",
                    help="report drift and exit 1; write nothing (CI idempotency gate)")
    ap.add_argument("--self-test", action="store_true",
                    help="run the pure translation tests (used by nix flake check)")
    args = ap.parse_args()

    if args.self_test:
        return self_test()

    if not os.path.exists(INSTALLED):
        sys.stderr.write("no Claude plugin state at %s -- nothing to do\n" % INSTALLED)
        return 0

    settings = json.load(open(CLAUDE_SETTINGS))
    roots, root_notes = plugin_roots(settings)
    files, stats = build(roots, settings)
    drift = write(files, args.check)

    for n in root_notes + stats["notes"]:
        print("note: %s" % n)
    print("plugins=%d agents=%d commands=%d mcp=%d hook-events=%d files=%d"
          % (len(roots), stats["agents"], stats["commands"],
             stats["mcp"], stats["hook_events"], len(files)))
    if args.check and drift:
        sys.stderr.write("drift (run `nix run .#gen-opencode`):\n  %s\n"
                         % "\n  ".join(drift))
        return 1
    if not args.check:
        print("wrote %s" % OUT)
    return 0


if __name__ == "__main__":
    sys.exit(main())
