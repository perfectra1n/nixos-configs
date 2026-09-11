#!/usr/bin/env bash
# Rebuild the opencode skill farm. Runs after EVERY `chezmoi apply` (no _once/_onchange),
# because what it fixes drifts outside chezmoi's view.
#
# WHY a farm instead of listing the real dirs in opencode.json:
#   opencode's skills.paths takes literal parent directories -- globs do NOT expand (verified:
#   a `*/*/skills` entry silently matched nothing). The real skill dirs live under
#   ~/.claude/plugins/cache/<market>/<plugin>/<VERSION>/skills, and that version segment
#   changes on every plugin update. A generated literal list would therefore be committed
#   already-rotting, and its failure mode is silence: opencode skips a missing path without
#   warning. So opencode.json holds ONE stable path -- this farm -- and only the LINKS move.
#
# The farm deliberately lives under ~/.local/share, i.e. OUTSIDE chezmoi's managed tree. A
# chezmoi-managed symlink whose target changes every plugin update would report dirty forever;
# worse, a managed-file collision is the "would be clobbered" failure that silently halts ALL
# home-manager file updates (see CLAUDE.md).
#
# Plugin skills are NOT linked into ~/.claude/skills even though opencode reads that natively:
# Claude Code reads it too, so every skill would load twice there -- once from the plugin, once
# from the link.
set -euo pipefail

FARM="${XDG_DATA_HOME:-$HOME/.local/share}/opencode-claude-skills"
SETTINGS="$HOME/.claude/settings.json"
INSTALLED="$HOME/.claude/plugins/installed_plugins.json"

# A box without Claude Code installed is a legitimate state (fresh provision, server host):
# leave no farm rather than an empty one, and let opencode fall back to its built-ins.
if [ ! -f "$INSTALLED" ] || [ ! -f "$SETTINGS" ]; then
  exit 0
fi

mkdir -p "$FARM"

# Resolve enabled plugin -> current skills dir. Directory-source marketplaces resolve to their
# LIVE path: the plugin cache is an install-time snapshot and goes stale silently (observed --
# custom-claude-skills cached 1 skill while its working tree had 6).
mapfile -t LINKS < <(python3 - "$SETTINGS" "$INSTALLED" <<'PY'
import json, os, sys
settings, installed = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))["plugins"]
markets = settings.get("extraKnownMarketplaces", {})
for key, on in sorted(settings.get("enabledPlugins", {}).items()):
    if not on:
        continue
    plugin, _, market = key.partition("@")
    root = None
    src = markets.get(market, {}).get("source", {})
    if src.get("source") == "directory":
        for cand in (os.path.join(src["path"], plugin), src["path"]):
            if os.path.isdir(cand):
                root = cand
                break
    if root is None:
        entries = installed.get(key)
        if not entries:
            continue
        root = entries[0]["installPath"]
    skills = os.path.join(root, "skills")
    if not os.path.isdir(skills):
        continue
    for name in sorted(os.listdir(skills)):
        if os.path.exists(os.path.join(skills, name, "SKILL.md")):
            # Namespaced: skill names collide across plugins, and opencode keys a skill by its
            # directory name, so an unnamespaced farm would drop all but one of each collision.
            print("%s-%s\t%s" % (plugin, name, os.path.join(skills, name)))
PY
)

declare -A WANT=()
for row in "${LINKS[@]}"; do
  name="${row%%$'\t'*}"
  target="${row#*$'\t'}"
  WANT["$name"]=1
  link="$FARM/$name"
  # -h not -e: a link to a GC'd/updated store path is broken, and `-e` is false for those, so
  # testing existence alone would leave stale links in place forever.
  if [ ! -h "$link" ] || [ "$(readlink "$link")" != "$target" ]; then
    ln -sfn "$target" "$link"
  fi
done

# Prune links for skills that are gone (plugin disabled, uninstalled, or renamed upstream).
# Without this a disabled plugin's skills keep loading in opencode with no way to see why.
for link in "$FARM"/*; do
  [ -h "$link" ] || continue
  name="$(basename "$link")"
  [ -n "${WANT[$name]:-}" ] || rm -f "$link"
done

printf 'opencode: %d skills linked in %s\n' "${#WANT[@]}" "$FARM"
