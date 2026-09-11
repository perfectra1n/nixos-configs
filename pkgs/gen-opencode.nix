# Derives opencode's config from the Claude Code setup this repo already tracks. Same
# writePython3Bin pattern (and flake8 gate) as claude-cred.nix; packaged so `nix run
# .#gen-opencode` works and `nix flake check` realizes it. Unlike claude-cred this is ops
# tooling, so it is NOT installed into any host's PATH — it only writes the chezmoi source.
{ pkgs }:
pkgs.writers.writePython3Bin "gen-opencode" {
  # E501: the WHY-comments carry the verified opencode incompatibilities and read better
  # unwrapped, matching claude-cred.nix. W503: see the note there.
  flakeIgnore = [ "E501" "W503" ];
} (builtins.readFile ../scripts/gen_opencode.py)
