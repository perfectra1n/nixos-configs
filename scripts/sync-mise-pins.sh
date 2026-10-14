# sync-mise-pins — rewrite mise.toml's [tools] pins to the versions in the LOCKED nixpkgs.
#
# BODY ONLY: writeShellApplication (flake.nix) injects the shebang + `set -euo pipefail`, gates it
# on shellcheck at build time, and pins runtimeInputs — same treatment as gen-manifests/whatchanged.
#
# Why this exists: checks.x86_64-linux.mise-nixpkgs-versions requires every [tools] pin to EQUAL
# pkgs.<name>.version, so nixpkgs is the single source of truth and mise.toml just follows it.
# Renovate's own mise manager is disabled (renovate.json) because it bumps to the newest upstream
# release, which nixpkgs usually hasn't packaged yet — a PR that can never pass. Instead every
# flake-input PR runs this as a postUpgradeTask, so a nixpkgs bump drags the pins along with it.
# Idempotent: on a non-nixpkgs input PR it rewrites nothing.
#
# Reads the same nixpkgs the check reads: --inputs-from resolves `nixpkgs` through flake.lock.

file="${1:-mise.toml}"

# Tool names = the `name = "x.y.z"` lines inside the [tools] table only.
mapfile -t tools < <(awk '
  /^\[/ { in_tools = ($0 == "[tools]"); next }
  in_tools && /^[A-Za-z0-9_-]+ = "/ { print $1 }
' "$file")

[ "${#tools[@]}" -gt 0 ] || { echo ">> sync-mise-pins: no [tools] pins in $file" >&2; exit 0; }

for t in "${tools[@]}"; do
  want=$(nix eval --raw --inputs-from . "nixpkgs#$t.version")
  # Anchored on the exact `name = "` prefix, which only occurs in [tools] (task names are quoted
  # table headers, settings are dotted keys) — so the replace can't hit another table.
  sed -i -E "s/^($t = \")[^\"]*\"/\1$want\"/" "$file"
  echo ">> $t = $want"
done
