#!/usr/bin/env bash
# Read-only health check for the nightly iOS backup chain (modules/ios-backup.nix).
#
# The chain has six links, and a break in ANY of them presents identically from the outside
# ("no backups appeared"), so this walks all of them at once instead of making you bisect:
#
#   muxer + mDNS running → device paired to THIS host → device allows Wi-Fi lockdown
#     → device advertising on the LAN → UDID registered in the sops secret → timer armed
#
# The third link is the one that actually bites: EnableWifiConnections is set on the PHONE,
# nothing in libimobiledevice can read it back for you in context, and when it's off the
# nightly job just logs DISCOVERY-TIMEOUT forever while USB backups keep working fine.
#
# set -u, NOT -eu: every probe below is allowed to fail. The point is to show all the
# breakage in one pass, so an early exit would defeat it.
set -u

ok()   { printf '  %-26s \033[32mok\033[0m %s\n' "$1" "${2:-}"; }
bad()  { printf '  %-26s \033[31mMISSING\033[0m %s\n' "$1" "${2:-}"; }
warn() { printf '  %-26s \033[33mwarn\033[0m %s\n' "$1" "${2:-}"; }
info() { printf '  %-26s %s\n' "$1" "${2:-}"; }
hdr()  { printf '\n\033[1m%s\033[0m\n' "$1"; }

nas=/mnt/main_smb/Jon/ios_backups
# The NAS by IP, not FQDN: this repo is PUBLIC and the domain is a secret. The IP is already
# in modules/smb-mounts.nix, so it leaks nothing new.
nas_host=192.168.2.155
# The dataset that actually governs these backups. NOT a nested ios_backups dataset —
# smb_folder/Jon is a plain directory and ZFS can't nest a dataset under one, so snapshots of
# the whole share are the only retention available at this path. See modules/ios-backup.nix.
nas_ds=main_pool/main_dataset/smb_folder

# Point idevice* at netmuxd when it is up: it serves Wi-Fi devices itself and forwards USB on
# to usbmuxd2, so this one address covers both transports. When it is down, fall through to the
# plain unix socket so at least the USB half of this report still works.
if [ "$(systemctl is-active netmuxd 2>/dev/null)" = active ]; then
  export USBMUXD_SOCKET_ADDRESS=127.0.0.1:27015
fi

# Backups live on the share now (no local staging), and the CIFS mount is readable as the
# invoking user, so nothing here needs root.
SUDO=""

hdr "daemons"
for u in usbmuxd netmuxd avahi-daemon; do
  st=$(systemctl is-active "$u" 2>/dev/null)
  if [ "$st" = active ]; then ok "$u" "$st"; else bad "$u" "${st:-unknown}"; fi
done
# usbmuxd2 only owns USB here (netmuxd owns Wi-Fi), but name what is running anyway: a swap
# back to stock usbmuxd would still be worth noticing.
exec_line=$(systemctl show usbmuxd -p ExecStart --value 2>/dev/null)
case "$exec_line" in
  *usbmuxd2*) ok "usbmuxd flavour" "usbmuxd2 (USB path)" ;;
  "")         warn "usbmuxd flavour" "could not read ExecStart" ;;
  *)          warn "usbmuxd flavour" "not usbmuxd2 — fine for USB, but unexpected" ;;
esac

hdr "tooling"
for b in idevicepair idevicebackup2 idevice_id idevice-wifi-sync plistutil; do
  if command -v "$b" >/dev/null 2>&1; then ok "$b"; else bad "$b" "not on PATH"; fi
done

hdr "paired devices"
# SystemConfiguration.plist is this HOST's own lockdown identity, not a device — never a pairing.
paired=$(find /var/lib/lockdown -maxdepth 1 -name '*.plist' \
          ! -name 'SystemConfiguration.plist' -printf '%f\n' 2>/dev/null \
          | sed 's/\.plist$//' | sort)
if [ -z "$paired" ]; then
  bad "/var/lib/lockdown" "no device pairings — plug a phone in over USB and run: mise run ios:pair"
else
  printf '%s\n' "$paired" | while read -r u; do ok "$u" "pairing record present"; done
fi

hdr "visibility"
usb=$(idevice_id -l 2>/dev/null)
net=$(idevice_id -n 2>/dev/null)
[ -n "$usb" ] && info "over USB" "$(echo "$usb" | tr '\n' ' ')" || info "over USB" "(none plugged in)"
if [ -n "$net" ]; then
  ok "over Wi-Fi" "$(echo "$net" | tr '\n' ' ')"
else
  bad "over Wi-Fi" "no network devices — the nightly job will DISCOVERY-TIMEOUT (check netmuxd's journal)"
fi

# What usbmuxd2 actually keys off. Browsing this directly separates "phone isn't advertising"
# (device-side: EnableWifiConnections) from "usbmuxd2 isn't consuming it" (host-side).
adv=$(timeout 6 avahi-browse -rpt _apple-mobdev2._tcp 2>/dev/null | grep -c '^=' )
if [ "${adv:-0}" -gt 0 ]; then
  ok "mDNS _apple-mobdev2" "$adv record(s) on the LAN"
else
  bad "mDNS _apple-mobdev2" "nothing advertising — no paired phone has Wi-Fi lockdown enabled"
fi

# Registered device list. sops keeps YAML *keys* in plaintext, so whether the service is even
# declared is greppable without the age identity; the UDIDs inside are ciphertext and need it.
key_present=no
grep -q 'backup_devices' secrets/secrets.yaml 2>/dev/null && key_present=yes
registered=""
if [ "$key_present" = yes ] && [ -e "$HOME/.config/age/age.agekey" ]; then
  registered=$(SOPS_AGE_KEY_FILE="$HOME/.config/age/age.agekey" \
    sops --decrypt --extract '["ios"]["backup_devices"]' secrets/secrets.yaml 2>/dev/null)
fi

hdr "per-device"
if [ -z "$paired" ]; then
  info "" "(nothing paired yet)"
else
  printf '%s\n' "$paired" | while read -r u; do
    printf '  \033[1m%s\033[0m\n' "$u"

    # Wi-Fi lockdown key, straight off the device. Exit 0 = on, 1 = off/unset, 2 = unreachable.
    wifi=$(idevice-wifi-sync status -u "$u" 2>/dev/null); wrc=$?
    case $wrc in
      0) ok "  EnableWifiConnections" "$wifi" ;;
      1) bad "  EnableWifiConnections" "$wifi — run: idevice-wifi-sync on -u $u (needs USB)" ;;
      *) warn "  EnableWifiConnections" "device unreachable right now (plug in over USB to check)" ;;
    esac

    if printf '%s\n' "$registered" | grep -qF "$u"; then
      ok "  registered in sops"
    elif [ -z "$registered" ]; then
      warn "  registered in sops" "cannot read the list (no age key, or key absent)"
    else
      bad "  registered in sops" "not in ios/backup_devices — run: UDID=$u NAME=<name> mise run ios:register"
    fi

    sp="$nas/$u/Status.plist"
    if $SUDO test -r "$sp" 2>/dev/null; then
      # Binary plist — hence plistutil. Key and value land on separate XML lines.
      xml=$($SUDO plistutil -i "$sp" 2>/dev/null)
      state=$(printf '%s\n' "$xml" | grep -A1 '<key>SnapshotState</key>' | tail -1 \
              | sed 's:.*<string>\(.*\)</string>.*:\1:')
      when=$(printf '%s\n' "$xml" | grep -A1 '<key>Date</key>' | tail -1 \
              | sed 's:.*<date>\(.*\)</date>.*:\1:')
      if [ "$state" = finished ]; then
        ok "  last backup" "$state ${when:-}"
      else
        warn "  last backup" "${state:-unknown} ${when:-} — interrupted; --full recovers next run"
      fi
    else
      info "  last backup" "no backup on the share yet"
    fi
  done
fi

hdr "service + timer"
if systemctl cat ios-backup.service >/dev/null 2>&1; then
  ok "ios-backup.service" "declared"
  res=$(systemctl show ios-backup.service -p Result --value 2>/dev/null)
  ts=$(systemctl show ios-backup.service -p ExecMainExitTimestamp --value 2>/dev/null)
  [ -n "$ts" ] && info "last run" "${res:-?} @ $ts" || info "last run" "never"
  nt=$(systemctl list-timers ios-backup.timer --no-legend 2>/dev/null)
  [ -n "$nt" ] && info "next trigger" "$(echo "$nt" | awk '{print $1, $2, $3, $4}')" \
                || warn "next trigger" "timer not armed"
else
  # The module gates service+timer on the secret existing, so this is expected pre-registration.
  bad "ios-backup.service" "not declared — sops key ios/backup_devices is ${key_present/no/absent}"
fi

hdr "retention (the ONLY thing giving you history)"
# rsync --delete overwrites the NAS copy every run, so ZFS snapshots of the destination dataset
# are the whole history story. They were found DISABLED with zero snapshots on 2026-09-10, which
# is exactly why this is checked rather than assumed. Unreachable NAS => "unknown", never "ok".
snap_out=$(timeout 8 ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
             "root@$nas_host" "zfs list -H -t snapshot -o name,creation -s creation $nas_ds 2>/dev/null | tail -3" 2>/dev/null)
if [ -z "$snap_out" ]; then
  if timeout 5 ssh -o ConnectTimeout=4 -o BatchMode=yes "root@$nas_host" true 2>/dev/null; then
    bad "ZFS snapshots" "NONE on $nas_ds — every rsync overwrites your only copy"
  else
    warn "ZFS snapshots" "unknown — could not reach the NAS over ssh to check"
  fi
else
  ok "ZFS snapshots" "newest: $(printf '%s\n' "$snap_out" | tail -1 | tr '\t' ' ')"
  info "snapshot count" "$(timeout 8 ssh -o ConnectTimeout=5 -o BatchMode=yes "root@$nas_host" \
        "zfs list -H -t snapshot $nas_ds 2>/dev/null | wc -l" 2>/dev/null)"
fi

hdr "storage"
# A leftover local tree would just be wasted space now that backups go straight to the share.
if [ -d /var/backup/ios ]; then
  warn "stale local staging" "/var/backup/ios still exists — backups no longer use it, safe to remove"
fi
# Touching the path is what triggers the CIFS automount, so this doubles as a mount test.
if [ -d "$nas" ]; then
  ok "NAS" "$nas — $(du -sh "$nas" 2>/dev/null | cut -f1)"
elif [ -d "$(dirname "$nas")" ]; then
  info "NAS" "$nas — not created yet, the first rsync makes it"
else
  bad "NAS" "$nas — parent unreachable, is //fullernas/main_smb mounted?"
fi
printf '\n'
