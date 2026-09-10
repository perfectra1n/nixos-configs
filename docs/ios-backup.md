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
disappears. Stack: `libimobiledevice` (`idevicebackup2 -n`) over **two** muxers —
**usbmuxd2** for USB (drop-in for `services.usbmuxd`) and **netmuxd** for Wi-Fi, running as a
shim on `127.0.0.1:27015` that forwards USB requests up to usbmuxd2.

usbmuxd2 advertises Wi-Fi support, and this module originally relied on it to avoid any
out-of-tree pin. That does not survive contact with modern iOS. Verified against **iOS 26.6.1**
on 2026-09-10: the phone advertises itself as
`de:08:9f:a6:76:cb@fe80::…-supportsRP-24._apple-mobdev2._tcp` and serves lockdown on **62078**,
while its mDNS SRV record points at a port that is **closed**. usbmuxd2's Dec-2023 snapshot
parses that instance name and trusts that port, so its `WIFIDeviceManager` initialises, finds
nothing usable, and logs *nothing* — `idevice_id -n` stays empty forever while USB works
perfectly. `--allow-heartless-wifi` does not help, which places the failure at discovery rather
than at the heartbeat. netmuxd matches the mDNS TXT record against the pairing records in
`/var/lib/lockdown` instead, so neither quirk affects it. It is pinned via `nvfetcher.toml`
(v0.4.3) — the cost of a working Wi-Fi path.

## Setting up a new device (one-time, over USB)

Plug the phone into the desktop via USB, unlock it, then just run:

```sh
mise run ios:pair
```

That drives the whole sequence and refuses to report success unless every step took. What it
does, and why each command looks the way it does:

```sh
idevicepair pair                            # tap "Trust", re-run to confirm "SUCCESS"
idevicebackup2 -i encryption on /mnt/main_smb/Jon/ios_backups
idevice-wifi-sync on                        # allow lockdown connections over the network
idevice_id -l                               # note the UDID
```

- **`-i` and the directory are both mandatory** on the encryption command. Without `-i` it
  never prompts for the password (it only reads `BACKUP_PASSWORD` from the environment), and
  `DIRECTORY` is a required positional — so the bare `idevicebackup2 encryption on` printed by
  every guide online just dumps usage and exits.
- The **backup password** goes in Bitwarden. Only a *restore* ever needs it; the nightly job
  doesn't. Encrypted backups are also strictly better: they include keychain, health, and
  Wi-Fi data that unencrypted ones omit.
- **`idevice-wifi-sync on` is ours** (`pkgs/idevice-wifi-sync.nix`), and it is the step people
  get wrong. It sets `EnableWifiConnections` in the `com.apple.mobile.wireless_lockdown`
  domain — what Finder calls "Show this iPhone when on Wi-Fi". Pairing alone does **not**
  enable network access ([upstream #88](https://github.com/libimobiledevice/libusbmuxd/issues/88),
  [#757](https://github.com/libimobiledevice/libimobiledevice/issues/757)), and no
  libimobiledevice tool can set it — `ideviceinfo` is get-only. The `idevicepair wifi on`
  you'll find in most write-ups **has never existed in any release**; it exits
  "Invalid command" *non-fatally*, so tutorials that print it appear to work whenever the
  author's phone already had Wi-Fi sync on from a past iTunes life.
- The pairing record lands in `/var/lib/lockdown/<UDID>.plist` and stays there — nothing to
  copy anywhere. The Wi-Fi key lives on the *phone* and persists across reboots.

Then register the device:

```sh
UDID=00008120-XXXX NAME=jon-iphone mise run ios:register
```

which appends one `<UDID> <name>` line to the sops `ios/backup_devices` key, building up (blank
lines and `#` comments are allowed):

```yaml
ios:
  backup_devices: |
    00008120-XXXXXXXXXXXXXXXX jon-iphone
    00008130-YYYYYYYYYYYYYYYY spouse-iphone
```

Use `mise run secrets:edit` if you'd rather hand-edit that block directly.

Rebuild (`mise run apply` or `sudo nixos-rebuild switch`). The `ios-backup.timer` only exists
once that sops key is present — the module is inert (packages only) on checkouts without it.

## Verifying / first run

```sh
mise run ios:status     # every link in the chain, read-only
mise run ios:backup     # kick it now + follow the journal
```

Expect per-device: discovery wait (up to 15 min), `backing up <name>…`, transfer progress,
`OK <name>`. Success artifacts:

- `/mnt/main_smb/Jon/ios_backups/<UDID>/Status.plist` with `SnapshotState = finished`.

`idevicebackup2` writes **straight to the share** — there is no local staging copy. That was a
deliberate choice (2026-09-10) to keep ~40-50 GB per device off the desktop's NVMe. The cost is
speed: a backup is 86,484 files across 514 directories with 76% under 64 KB, and SMB is
latency-bound *per file*, so the seed is materially slower than it would be locally. It also
means the NAS must stay reachable for the whole transfer, which is what the 3x retry covers.

> ⚠ **There is no history unless you arrange it.** `idevicebackup2` keeps one backup per device
> and updates it **in place** on the share, so each run overwrites the previous state and no
> layer here keeps versions. Point-in-time
> recovery depends entirely on ZFS snapshots of the destination dataset — and on 2026-09-10
> every periodic snapshot task on the NAS was found **disabled, with zero snapshots**, which had
> quietly reduced this scheme to a single overwritable copy.
>
> Worse, the destination cannot get its *own* retention policy: the share is the dataset
> `main_pool/main_dataset/smb_folder` (not `main_dataset`, as this doc used to say), and
> `smb_folder/Jon` is a plain directory holding ~830 GB — ZFS cannot nest a dataset under a
> directory. So any snapshot policy covering these backups covers the whole 2.3 TB share. The
> clean fix is a dataset under `computer_backups_dataset/` (beside `jonbackups`/`nicolebackups`,
> where this NAS already keeps device backups), which needs its own SMB share + mount.
> `mise run ios:status` reports the snapshot state so this stays visible instead of silent.

A second manual run finishing quickly proves the incremental path. First seeds can be
50–200 GB per device and run sequentially, so give the first night slack (the service caps
itself at 8 h). `systemctl list-timers ios-backup` shows the next 03:00 trigger; the timer is
`Persistent`, so a desktop that was off at 03:00 catches up at next boot.

## Restore (drill, not automated)

Plug the target phone in over USB and:

```sh
idevicebackup2 restore --system --settings /mnt/main_smb/Jon/ios_backups
```

It will ask for the backup password from Bitwarden. Restoring onto a brand-new phone requires
pairing it first (`idevicepair pair`).

## Troubleshooting

| Symptom | Likely cause |
|---------|--------------|
| `DISCOVERY-TIMEOUT <name>` in the journal | **First check `mise run ios:status` for `EnableWifiConnections`** — if it's off/unset the phone never advertises at all and every night misses. Otherwise: phone wasn't on the LAN/Wi-Fi that night (or is on a VLAN whose mDNS doesn't reach the desktop — Bonjour needs L2 adjacency or an mDNS reflector on the router). |
| Device never appears in `idevice_id -n` even nearby | `idevice-wifi-sync on` not run (see above — note it is NOT `idevicepair wifi on`, which does not exist), trust revoked (re-pair over USB), or netmuxd wedged — `systemctl restart netmuxd`. Remember `idevice_id -n` needs `USBMUXD_SOCKET_ADDRESS=127.0.0.1:27015` to reach netmuxd at all. |
| Backup fails right after an iOS major update | libimobiledevice lagging Apple's protocol changes — check nixpkgs for a bump; this historically happens around September releases. |
| `Backup Aborted.` + `Could not receive from mobilebackup2 (-4)` partway through | The phone slept mid-transfer — check the netmuxd journal for `Heartbeat(SleepyTime)`. Apple's Wi-Fi sync assumes the device is **on power**; the 03:00 timer targets that. The service retries 3× and `--full` resumes into the existing tree, so a partial transfer is never wasted. |
| `idevice_id -n` empty but `avahi-browse -rt _apple-mobdev2._tcp` shows the phone | The muxer isn't consuming the advertisement. `systemctl status netmuxd` — if it's down, the Wi-Fi path is gone. This is also the exact signature of usbmuxd2 trying to serve Wi-Fi (see above); netmuxd must own that path. |
| Wi-Fi tools work in the service but not by hand | `USBMUXD_SOCKET_ADDRESS=127.0.0.1:27015` is set only inside `ios-backup.service` and the `ios:*` tasks, deliberately — a global would break plain USB tooling (and GVfs iPhone mounting) whenever netmuxd was down. Export it for ad-hoc `idevice*` calls. |
| Backup fails immediately with a mount error | The share is unreachable. The unit declares `RequiresMountsFor` on it, so it fails fast rather than half-writing a backup. Check `findmnt /mnt/main_smb` and the NAS. |
| `NO DEVICES parsed from /run/secrets/…` | The device list is empty or malformed. Note the service treats zero devices as a FAILURE — it previously exited 0 after backing up nothing, which is how a missing trailing newline in the secret hid for a whole run. |
