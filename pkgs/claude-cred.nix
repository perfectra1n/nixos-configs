# claude-cred as a real PATH binary. One definition, two consumers: the flake's packages
# output (nix run .#claude-cred, and it rides `nix flake check`'s package realization) and
# home/common.nix (installed for the user on every host). writePython3Bin's flake8 pass is
# the Python analog of the shellcheck gate the writeShellApplication apps get.
{ pkgs }:
pkgs.writers.writePython3Bin "claude-cred" {
  # E501: the WHY-comments carry incident lore and read better unwrapped at ~100 cols.
  # W503: leading-binary-operator breaks are the PEP 8-preferred style; the writer's
  # flake8 config re-enables this off-by-default check, so silence it explicitly.
  flakeIgnore = [ "E501" "W503" ];
} (builtins.readFile ../scripts/claude_cred.py)
