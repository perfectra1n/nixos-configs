# Body of the suspects flake app (flake.nix packages.x86_64-linux.suspects).
# writeShellApplication injects the shebang, `set -euo pipefail`, and shellcheck — invoke via
#   nix run .#suspects -- <binary-or-store-path> [from-gen] [to-gen]
# or the mise wrapper: BIN=flameshot [FROM=87 TO=88] mise run suspects
#
# "Something broke after a bump and the changed-package list is full of names I don't know."
# You don't need to know them — the culprit MUST be in the intersection of (a) the broken
# app's runtime closure and (b) the store paths that changed between two generations. This
# computes that intersection mechanically and prints the `nix why-depends` chain for each
# hit, so an unknown transitive dep points back to the app through a readable path.
# Empty [from-gen]/[to-gen] default to the two newest kept generations.

profile=/nix/var/nix/profiles/system
bin="${1:-}"
from="${2:-}"
to="${3:-}"

if [ -z "$bin" ]; then
  echo "usage: suspects <binary-or-store-path> [from-gen] [to-gen]" >&2
  exit 1
fi

shopt -s nullglob
mapfile -t links < <(printf '%s\n' "$profile"-*-link | sort -V)
if [ "${#links[@]}" -lt 2 ]; then
  echo "error: need at least two kept generations under $profile" >&2
  exit 1
fi
from_link="${links[-2]}"
to_link="${links[-1]}"
[ -n "$from" ] && from_link="$profile-$from-link"
[ -n "$to" ] && to_link="$profile-$to-link"
for l in "$from_link" "$to_link"; do
  [ -e "$l" ] || { echo "error: $l does not exist (gc'd?)" >&2; exit 1; }
done
from_gen="${from_link#"$profile"-}"; from_gen="${from_gen%-link}"
to_gen="${to_link#"$profile"-}"; to_gen="${to_gen%-link}"

# Resolve the broken thing to its store root. A bare name resolves against the TO
# generation's system path first (so historical queries use that era's binary), then
# falls back to PATH; explicit paths (incl. raw store paths) dereference directly.
if [ -e "$bin" ]; then
  target=$(readlink -f "$bin")
elif [ -e "$to_link/sw/bin/$bin" ]; then
  target=$(readlink -f "$to_link/sw/bin/$bin")
else
  target=$(readlink -f "$(command -v "$bin")") || {
    echo "error: '$bin' not found in gen $to_gen or on PATH" >&2; exit 1
  }
fi
store_root=$(grep -oE '^/nix/store/[a-z0-9]{32}-[^/]+' <<<"$target" || true)
if [ -z "$store_root" ]; then
  echo "error: $target is not in /nix/store" >&2
  exit 1
fi

# Suspects = paths in the app's closure that did NOT exist in the FROM generation's closure
# — i.e. every piece of the app's dependency tree this bump changed or introduced.
app_closure=$(nix-store --query --requisites "$store_root" | sort -u)
old_closure=$(nix-store --query --requisites "$from_link" | sort -u)
suspects=$(comm -23 <(printf '%s\n' "$app_closure") <(printf '%s\n' "$old_closure"))

name_of() { sed -E 's|^/nix/store/[a-z0-9]{32}-||' <<<"$1"; }

echo "app:  $(name_of "$store_root")  ($store_root)"
echo "gens: $from_gen → $to_gen"
if [ -z "$suspects" ]; then
  echo
  echo "CLEAR: nothing in this app's runtime closure changed between gen $from_gen and gen $to_gen."
  echo "The breakage is not from packages this app depends on — check services it talks to"
  echo "(portals, daemons) with their own binaries, or config/dotfile changes."
  exit 0
fi

count=$(wc -l <<<"$suspects")
echo "suspects: $count path(s) in its closure changed in this bump"
echo
i=0
while IFS= read -r s; do
  i=$((i + 1))
  echo "[$i/$count] $(name_of "$s")"
  if [ "$s" = "$store_root" ]; then
    echo "    (the app itself was rebuilt)"
  else
    # The dependency chain from the app to the suspect — how an unknown package reaches you.
    # why-depends emits ANSI codes even when piped; strip them for clean terminal/log output.
    nix why-depends "$store_root" "$s" 2>/dev/null | head -8 \
      | sed -e $'s/\x1b\\[[0-9;]*m//g' -e 's/^/    /' || true
  fi
  echo
done <<<"$suspects"
echo "Next: A/B each suspect against the old generation, e.g."
echo "  $from_link/sw/bin/<tool> …   # does the symptom vanish with the OLD binary?"
echo "See docs/package-versioning.md → runbook."
