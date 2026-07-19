# Generic rclone mounts + Google Drive (AtvikGoogleDrive)

**Date:** 2026-07-19 · **Status:** approved

## Problem

`modules/nextcloud-vfs.nix` mounts exactly one rclone remote, with the remote name, sops
secret path and every systemd detail hardcoded. Adding Google Drive as a second on-demand
mount would mean copy-pasting ~120 lines that then drift apart — the same duplication the
shared `graphical` list in `flake.nix` was created to eliminate.

Google Drive also breaks the module's secret model outright. Nextcloud's WebDAV config is
static (url + user + obscured password, valid forever), so shipping it as a read-only
`0400` sops secret works. Drive uses OAuth2: rclone holds a `refresh_token`, mints a new
`access_token` roughly hourly, and then tries to **write the refreshed token back to its
config file**. sops secrets land read-only on tmpfs under `/run/secrets`, so that write
always fails.

A working `[AtvikGoogleDrive]` remote already exists at `~/.config/rclone/rclone.conf` —
unmanaged, unencrypted, and backed up nowhere. It is already authorized (`token` present),
uses its own `client_id`/`client_secret` rather than rclone's rate-limited shared OAuth
client, and is scoped to a Shared Drive folder via `team_drive` + `root_folder_id`.

## Design

### 1. Config ownership moves from sops to chezmoi, via `create_`

The rclone config becomes `dotfiles/dot_config/rclone/create_encrypted_private_rclone.conf.age`,
deployed to `~/.config/rclone/rclone.conf` (0600), holding **both** `[FullerNextcloud]` and
`[AtvikGoogleDrive]`.

chezmoi's `create_` attribute means *seed if absent, then never touch again*. Verified
empirically on v2.70.5:

| Behavior | Result |
|---|---|
| `create_encrypted_private_rclone.conf.age` parses | manages `rclone.conf` |
| first `apply` | decrypts, writes at `0600` |
| app rewrites file, then `apply` | app's version **untouched** |
| `chezmoi status` afterwards | **clean** — excluded from the dirty check |
| `apply --force` | **still** does not re-seed; `create_` is absolute |
| `chezmoi re-add` | **silent no-op** — does *not* update the source |
| `chezmoi add --create --encrypt` | updates the source, attributes preserved |

`re-add` being inert on `create_` entries is consistent (`create_` is the attribute that tells
chezmoi to stop tracking content) but it **fails open**: no error, no diff, and the stale source
ships to the next box. Verify a re-capture by decrypting the **source** — `age -d -i
~/.config/age/age.agekey <file>.age` — never with `chezmoi cat`, which reports the *target's*
content and therefore cannot detect a missed update.

This is the same family as the DMS `settings.json` and kubeconfig/talosconfig convention
(live-writable snapshots, never `readonly_`), but `create_` rather than a plain
`re-add`-captured snapshot, because rclone rewrites **hourly**: a plain managed file would
report dirty permanently and prompt to overwrite on every apply. Retrofitting `create_`
onto the existing kubeconfig/talosconfig snapshots is deliberately out of scope here.

This also *stops dodging* the chezmoi boundary. `nextcloud-vfs.nix` used sops explicitly to
avoid owning a `~/.config` file; per CLAUDE.md's ownership tree, `~/.config/*` user config
belongs to chezmoi, so this is the more compliant home for it. The age key is the same one
sops-nix uses, so the security model is unchanged: ciphertext in git, decrypt at apply.

**One combined file, not one per remote.** `rclone --config` accepts exactly one file
(verified, v1.74.3), so a per-remote split would break `rclone ls AtvikGoogleDrive:` and
`rclone config` re-auth unless every invocation passed an explicit `--config`. The
accepted cost: because `create_` will not overwrite an existing target, adding a **third**
remote later does not propagate to an already-provisioned machine. The documented fix,
which must go in the module header comment:

```sh
rm ~/.config/rclone/rclone.conf && chezmoi apply    # re-seed to pick up a new remote
```

This is safe — the seed carries the `refresh_token`, and rclone mints fresh access tokens
from it on start, so nothing is lost by re-seeding.

### 2. `modules/rclone-mounts.nix` replaces `modules/nextcloud-vfs.nix`

An attrset of mounts; each entry generates its own systemd user unit and tmpfiles rule.

```nix
services.rcloneMounts.<name> = {
  configFile   = "/home/${username}/.config/rclone/rclone.conf";  # default
  mountPoint   = "/mnt/<name>";                                   # default
  cacheMaxSize = "20G";                                           # default
  extraFlags   = [ ];
};
```

Generated per entry:

- `systemd.user.services.rclone-<name>` — `Type=notify` (rclone signals READY=1 only once
  the mount is usable), `PATH=/run/wrappers/bin:...` so the setuid `fusermount3` wrapper
  wins, `ExecStop` lazy-unmount as a `-`-prefixed safety net, `Restart=on-failure` /
  `RestartSec=15s`, `startLimitIntervalSec=300` / `startLimitBurst=5`.
- `systemd.tmpfiles.rules` — pre-creates the user-owned mountpoint, since `/mnt` is
  root-owned and a *user* service cannot mkdir there.

Shared: `environment.systemPackages = [ pkgs.rclone pkgs.fuse3 ]`.

**The sops eval gate disappears from this module.** No `secrets` module argument, no
`secrets.has` call, no hardcoded `/run/secrets/...` path with its "cannot reference
`.path` at eval when conditionally declared" caveat. The no-choke property survives on the
runtime gate alone: `unitConfig.ConditionPathExists = configFile` means that on a machine
where `chezmoi apply` has not run, the unit is marked *skipped* (condition unmet), not
failed — no crash loop, clean boot, and it starts working the moment the file lands.
`lib/secrets.nix` itself stays; other modules still use it.

### 3. Mount declarations

Both graphical hosts get both mounts, so the two entries live in the same module's
`config`:

```nix
FullerNextcloud  = { extraFlags = [ "--dir-cache-time" "72h" ]; };
AtvikGoogleDrive = { extraFlags = [ "--drive-export-formats" "docx,xlsx,pptx,svg"
                                    "--poll-interval" "1m" ]; };
```

Shared mount flags (from the current module): `--vfs-cache-mode full`,
`--vfs-cache-max-size`, `--vfs-cache-max-age 168h`, `--vfs-write-back 10s`,
`--buffer-size 32M`, `--transfers 4`, `--log-level INFO`.

Rationale for the Drive-specific flags:

- `--drive-export-formats docx,xlsx,pptx,svg` — Google-native Docs/Sheets/Slides surface as
  real Office files. This is rclone's default; stated explicitly so the choice is
  reviewable rather than implicit.
- `--poll-interval 1m` — Drive supports change notification, so listings stay fresh
  *without* shortening `--dir-cache-time`. Deliberately **not** applied to Nextcloud, where
  WebDAV cannot push changes and the flag is a no-op.

`team_drive` and `root_folder_id` stay in the config file — they define the remote, not the
mount behavior. Mount is read-write, matching the SMB and Nextcloud mounts.

### 4. Wiring, migration and cleanup

1. `flake.nix` `graphical` list: `./modules/nextcloud-vfs.nix` → `./modules/rclone-mounts.nix`.
2. Capture the existing config **in place** (non-destructive — no delete step, and the live
   Nextcloud mount never breaks during migration):
   `chezmoi add --create --encrypt ~/.config/rclone/rclone.conf`
3. Delete `modules/nextcloud-vfs.nix`.
4. Drop the now-unused `nextcloud/rclone_conf` key from `secrets/secrets.yaml`
   (`mise run secrets:edit`).
5. Update the stale cross-references: the comment at `modules/desktop-apps.nix:337`,
   `docs/host-matrix.md`, and the `nextcloud-vfs` mention in `docs/architecture.md`.

`modules/smb-mounts.nix` is untouched and keeps its sops credentials — it is a root/kernel
CIFS mount triggered by `x-systemd.automount`, not a user FUSE service, so its creds
correctly stay in system-land.

## Error handling / verification

Failure modes: a missing age key fails `chezmoi apply` loudly at decrypt (existing
behavior); a missing `~/.config/rclone/rclone.conf` leaves each unit *skipped*, not failed;
an unreachable remote hits `Restart=on-failure` and then the start limit rather than
looping forever; a revoked OAuth token fails the unit, and recovery is `rclone config
reconnect AtvikGoogleDrive:` followed by `chezmoi add --create --encrypt
~/.config/rclone/rclone.conf` to re-capture (**not** `re-add` — see above).

Verify:

```sh
git add -A && nix flake check --no-build       # evaluates every host
systemctl --user status rclone-AtvikGoogleDrive.service
systemctl --user status rclone-FullerNextcloud.service   # regression: must still mount
ls /mnt/AtvikGoogleDrive /mnt/FullerNextcloud
rclone ls AtvikGoogleDrive: | head             # no --config needed
chezmoi status                                 # must be clean after rclone refreshes tokens
```

The Nextcloud check is the important one: this change touches a working mount, so the
regression risk is concentrated there rather than in the new Drive mount.
