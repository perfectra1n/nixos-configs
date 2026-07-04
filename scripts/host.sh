#!/usr/bin/env bash
# Print the host-config name for THIS machine. Resolution order:
#   1. $HOST env override                       — explicit wins ("build a specific config")
#   2. root filesystem UUID matched against a committed hosts/*/hardware-configuration.nix
#      — the machine's real identity; works on a fresh box before the hostname is set, as
#      soon as `mise run hardware` has captured + committed the real hardware config.
#   3. /etc/hostname                            — but only if it names a real host config
#   4. interactive pick from hosts/*            — when a terminal is attached (fresh box:
#      hostname is still the installer default "nixos", which is no config)
#   5. error with the valid names               — non-interactive (CI/deploy): pass HOST=
set -eu

hosts=$(for d in hosts/*/; do basename "$d"; done)
valid() { printf '%s\n' $hosts | grep -qxF "$1"; }

# 1. explicit override
if [ -n "${HOST:-}" ]; then echo "$HOST"; exit 0; fi

# 2. root UUID → the machine's real identity (works before the hostname is set)
uuid=$(findmnt -no UUID / 2>/dev/null || true)
if [ -n "$uuid" ]; then
  for f in hosts/*/hardware-configuration.nix; do
    [ -f "$f" ] || continue
    grep -qiF "$uuid" "$f" && { basename "$(dirname "$f")"; exit 0; }
  done
fi

# 3. hostname, but only if it's actually one of our configs
hn=$(cat /etc/hostname 2>/dev/null || hostname || true)
if valid "$hn"; then echo "$hn"; exit 0; fi

# 4. ask, if someone's at the keyboard. Prompt on /dev/tty so this stays usable inside
#    `host=$(./scripts/host.sh)` — only the chosen name lands on stdout.
if [ -e /dev/tty ]; then
  {
    echo "Can't auto-detect this host (hostname '$hn' isn't a known config)."
    i=1; for h in $hosts; do echo "  $i) $h"; i=$((i + 1)); done
    printf 'pick a host (number or name) > '
  } >/dev/tty
  read -r pick </dev/tty
  case "$pick" in
    '' | *[!0-9]*) : ;;                               # not a pure number → treat as a name
    *) pick=$(printf '%s\n' $hosts | sed -n "${pick}p") ;;
  esac
  if valid "$pick"; then echo "$pick"; exit 0; fi
  echo ">> '$pick' isn't a valid host" >&2; exit 1
fi

# 5. no terminal → fail loudly with the fix instead of a cryptic Nix attribute error
echo ">> can't detect host (hostname '$hn' is not a config); valid: $(echo $hosts); rerun with HOST=<name>" >&2
exit 1
