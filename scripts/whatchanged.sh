# Body of the whatchanged flake app (flake.nix packages.x86_64-linux.whatchanged).
# writeShellApplication injects the shebang, `set -euo pipefail`, and shellcheck — invoke via
#   nix run .#whatchanged [-- <package-name>]
# and from any box: nix run github:perfectra1n/nixos-configs#whatchanged -- <pkg>
#
# Package history across THIS machine's kept system generations (runtime closures of built
# generations — unlike manifests/, which are eval-time build closures).
#   no arg → version-level diff for every consecutive generation pair
#   <pkg>  → generations where <pkg>'s STORE PATH set changed — catches same-version rebuilds:
#            xdg-desktop-portal-hyprland once regressed at an UNCHANGED 1.3.12 (store path
#            moved, rebuilt against a changed grim); version diffs were blind to it.
# Works unprivileged: profiles and the store are world-readable. Note: generations pruned by
# `mise run gc` (14d) are gone from history — git manifests are the durable record.

profile=/nix/var/nix/profiles/system
pkg="${1:-}"

if [ -z "$pkg" ]; then
  nix profile diff-closures --profile "$profile"
  exit 0
fi

shopt -s nullglob
# sort -V: numeric-aware, so system-100-link sorts after system-28-link (glob order doesn't)
mapfile -t links < <(printf '%s\n' "$profile"-*-link | sort -V)
if [ "${#links[@]}" -eq 0 ]; then
  echo "error: no system generations found under $profile" >&2
  exit 1
fi

indent() {
  if [ -z "$1" ]; then echo "    <absent>"; else echo "    ${1//$'\n'/$'\n'    }"; fi
}

prevpaths="" prevgen="" seen=0 changes=0
for link in "${links[@]}"; do
  gen="${link#"$profile"-}"
  gen="${gen%-link}"
  # grep exits 1 when the package is absent from a generation — legitimate, not an error
  paths=$(nix-store --query --requisites "$link" 2>/dev/null | grep -E -- "-${pkg}(-[0-9][^/]*)?$" | sort) || paths=""
  if [ "$seen" -eq 1 ] && [ "$paths" != "$prevpaths" ]; then
    changes=$((changes + 1))
    date=$(stat -c %y "$link" | cut -d. -f1) # symlink's OWN mtime = switch time (no -L)
    rev=$("$link/sw/bin/nixos-version" --configuration-revision 2>/dev/null) || rev="unknown"
    echo "gen $prevgen → $gen  (switched $date, config rev: ${rev:-unknown})"
    echo "  before:"
    indent "$prevpaths"
    echo "  after:"
    indent "$paths"
    echo
  fi
  prevpaths="$paths" prevgen="$gen" seen=1
done
if [ "$changes" -eq 0 ]; then
  echo "no store-path changes for '$pkg' across ${#links[@]} kept generations"
fi
