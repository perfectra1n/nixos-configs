# iOS device backups — `modules/ios-backup.nix` (desktop)

Nightly Wi-Fi **full-device** backups of the family's iPhones/iPads — the iTunes/Finder-style
backup that can restore a whole phone (messages, app data, settings). Photos are deliberately
not this module's job (Immich in the cluster does that); this covers the one thing Immich
can't: device restore.

## Why it lives on the desktop, not the cluster

Apple only allows Wi-Fi backups from a machine the device has **trusted over USB**, on the
**same local network** (Bonjour discovery, no unicast fallback). Nobody in the kubesearch.dev
corpus runs `idevicebackup2` in Kubernetes for exactly this reason — a pod would need
`hostNetwork`, a custom image, and the pairing records smuggled in as secrets. The desktop is
the box the phones physically plug into, so pairing machine = backup machine and all of that
disappears. Stack: `libimobiledevice` (`idevicebackup2 -n`) over **usbmuxd2** (the
Wi-Fi-capable muxer, drop-in for `services.usbmuxd`) + Avahi for mDNS. All in nixpkgs — no
out-of-tree pins.

## Setting up a new device (one-time, over USB)

Plug the phone into the desktop via USB, unlock it, then:

```sh
idevicepair pair            # tap "Trust" on the phone, re-run to confirm "SUCCESS"
idevicebackup2 encryption on
idevicepair wifi on         # allow lockdown connections over the network
idevice_id -l               # note the UDID
```

- `encryption on` asks for a **backup password** — store it in Bitwarden. Only a *restore*
  ever needs it; the nightly job doesn't. Encrypted backups are also strictly better: they
  include keychain, health, and Wi-Fi data that unencrypted ones omit.
- The pairing record lands in `/var/lib/lockdown/<UDID>.plist` and stays there — nothing to
  copy anywhere.

Then register the device:

```sh
mise run secrets:edit
```

and add/extend the block (one `<UDID> <name>` per line, `#` comments allowed):

```yaml
ios:
  backup_devices: |
    00008120-XXXXXXXXXXXXXXXX jon-iphone
    00008130-YYYYYYYYYYYYYYYY spouse-iphone
```

Rebuild (`mise run apply` or `sudo nixos-rebuild switch`). The `ios-backup.timer` only exists
once that sops key is present — the module is inert (packages only) on checkouts without it.

## Verifying / first run

```sh
sudo systemctl start ios-backup.service
journalctl -fu ios-backup
```

Expect per-device: discovery wait (up to 15 min), `backing up <name>…`, transfer progress,
`OK <name>`. Success artifacts:

- `/var/backup/ios/<UDID>/Status.plist` with `SnapshotState = finished` (local staging), and
- the same tree mirrored to `//fullernas/main_smb/iOSBackups/` (versioned by the dataset's
  ZFS snapshots — that's the *entire* history story, since `idevicebackup2` updates one
  backup in place).

A second manual run finishing quickly proves the incremental path. First seeds can be
50–200 GB per device and run sequentially, so give the first night slack (the service caps
itself at 8 h). `systemctl list-timers ios-backup` shows the next 03:00 trigger; the timer is
`Persistent`, so a desktop that was off at 03:00 catches up at next boot.

## Restore (drill, not automated)

Plug the target phone in over USB and:

```sh
idevicebackup2 restore --system --settings /var/backup/ios
```

It will ask for the backup password from Bitwarden. Restoring onto a brand-new phone requires
pairing it first (`idevicepair pair`).

## Troubleshooting

| Symptom | Likely cause |
|---------|--------------|
| `DISCOVERY-TIMEOUT <name>` in the journal | Phone wasn't on the LAN/Wi-Fi that night (or is on a VLAN whose mDNS doesn't reach the desktop — Bonjour needs L2 adjacency or an mDNS reflector on the router). |
| Device never appears in `idevice_id -n` even nearby | `idevicepair wifi on` not run, trust revoked (re-pair over USB), or usbmuxd2 wedged — `systemctl restart usbmuxd`. |
| Backup fails right after an iOS major update | libimobiledevice lagging Apple's protocol changes — check nixpkgs for a bump; this historically happens around September releases. |
| Wi-Fi discovery chronically flaky | nixpkgs' `usbmuxd2` is an unstable 2023 snapshot. Fallback documented in the module header: stock `usbmuxd` + transient `netmuxd` (nvfetcher-pinned) on `USBMUXD_SOCKET_ADDRESS=127.0.0.1:27015`. |
| Sync step fails, backups OK | fullernas / the `/mnt/main_smb` automount unreachable — the local staging copy is still current; the next successful run re-syncs. |
