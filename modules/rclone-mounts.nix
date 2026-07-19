{ config, pkgs, lib, username, ... }:

# Files-on-demand "virtual drive" mounts, one systemd user service per rclone remote.
# Files appear instantly, download on access, and stay cached up to a size cap (rclone evicts
# the oldest). Currently: Nextcloud over WebDAV, and a Google Drive Shared Drive.
#
# Replaces the old single-remote modules/nextcloud-vfs.nix. That module hardcoded one remote's
# name, secret path and every systemd detail; adding a second mount meant copy-pasting ~120
# lines that would then drift — the same duplication the shared `graphical` list in flake.nix
# exists to kill. Mounts are now attrset ENTRIES and the boilerplate is generated.
#
# ── Secret model: chezmoi, NOT sops (this is the interesting part) ──
# The old module kept its rclone.conf as a read-only sops secret. That CANNOT work for Google
# Drive: WebDAV config is static (url + user + obscured password, valid forever), but Drive is
# OAuth2 — rclone holds a refresh_token, mints a new access_token roughly hourly, and then
# writes the refreshed token back to its config file. sops secrets land read-only on tmpfs
# under /run/secrets, so that write always fails.
#
# So the config moved to chezmoi, age-encrypted at rest, deployed to ~/.config/rclone/rclone.conf
# (0600) via the `create_` attribute — "seed if absent, then never touch again". rclone owns the
# file thereafter and its hourly token churn is invisible to `chezmoi status`. A plain managed
# file would instead report dirty forever and prompt to overwrite on every apply. See the long
# note in dotfiles/.chezmoiignore for the re-capture and re-seed procedures.
#
# This also stops DODGING the chezmoi boundary rather than respecting it: the old module chose
# sops explicitly so it wouldn't own a ~/.config file, but CLAUDE.md's ownership tree assigns
# ~/.config/* user config to chezmoi. The age key is the same one sops-nix uses, so the security
# model is unchanged — ciphertext in git, decrypted at apply.
#
# NB modules/smb-mounts.nix deliberately KEEPS its sops credentials: that is a root/kernel CIFS
# mount triggered by x-systemd.automount, not a user FUSE service, so its creds belong in
# system-land. Different mechanism, different secret store — not an inconsistency.
#
# ── No-choke design ──
# The old module needed TWO gates: an eval gate (`secrets.has`, so declaring an absent sops key
# couldn't brick nixos-rebuild) plus a runtime one. Moving off sops deletes the eval gate
# outright — there is no sops secret to declare, so nothing here can fail activation, and the
# "can't reference .path when conditionally declared" caveat goes with it.
#
# The runtime gate is all that remains and is all that is needed: ConditionPathExists on the
# config file means that on a box where `chezmoi apply` hasn't run, the unit is marked *skipped*
# (condition unmet), NOT failed. No crash loop, clean boot, and it starts working the moment the
# file lands. Graphical-host feature, opted into via the `graphical` list in flake.nix.
let
  cfg = config.services.rcloneMounts;
in
{
  options.services.rcloneMounts = lib.mkOption {
    default = { };
    description = "rclone FUSE mounts, keyed by remote name (the [section] header in rclone.conf).";
    type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
      options = {
        configFile = lib.mkOption {
          type = lib.types.str;
          default = "/home/${username}/.config/rclone/rclone.conf";
          description = ''
            rclone config holding this remote. ONE combined file for every remote, not one per
            remote, because `rclone --config` takes exactly one path — a split would break plain
            `rclone ls <remote>:` and `rclone config` re-auth unless every invocation passed
            --config explicitly. Doubles as the unit's ConditionPathExists gate.
          '';
        };

        mountPoint = lib.mkOption {
          type = lib.types.str;
          default = "/mnt/${name}";
          description = ''
            Where to mount. Under /mnt (alongside the SMB share) rather than ~ so all the
            "external storage" lives in one place. NOTE: /mnt is root-owned and these are *user*
            services that can't mkdir there, so mountpoints are pre-created via systemd.tmpfiles.
          '';
        };

        cacheMaxSize = lib.mkOption {
          type = lib.types.str;
          default = "20G";
          description = "VFS cache cap (--vfs-cache-max-size); rclone evicts the oldest past this.";
        };

        extraFlags = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          example = [ "--dir-cache-time" "5m" ];
          description = ''
            Extra rclone mount flags, appended last so they override the shared defaults below.
            Also the escape hatch for backend-specific behaviour (--drive-*) and for trading
            freshness against speed.
          '';
        };
      };
    }));
  };

  config = {
    # `rclone config`/`rclone obscure` available system-wide; fuse3 provides fusermount3.
    environment.systemPackages = [ pkgs.rclone pkgs.fuse3 ];

    # Pre-create each mountpoint owned by the user (at boot, as root) so the user mounts can
    # land on them — see mountPoint's note about root-owned /mnt.
    systemd.tmpfiles.rules =
      lib.mapAttrsToList (_: m: "d ${m.mountPoint} 0755 ${username} users - -") cfg;

    systemd.user.services = lib.mapAttrs'
      (name: m: lib.nameValuePair "rclone-${name}" {
        description = "rclone files-on-demand mount: ${name}";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        wantedBy = [ "default.target" ];

        # The whole no-choke story (see header): skip cleanly, not fail, until chezmoi has
        # deployed the config. Inert on a box that hasn't run `chezmoi apply` yet.
        unitConfig.ConditionPathExists = m.configFile;

        serviceConfig = {
          # rclone speaks sd_notify: it signals READY=1 only once the mount is actually usable.
          Type = "notify";
          # Mount needs the setuid fusermount3 wrapper (NixOS provides /run/wrappers/bin/
          # fusermount3 by default); put it first on PATH so rclone uses it rather than the
          # plain fuse3 binary.
          Environment = "PATH=/run/wrappers/bin:/run/current-system/sw/bin";
          ExecStart = lib.concatStringsSep " " ([
            "${pkgs.rclone}/bin/rclone mount"
            "${name}: ${m.mountPoint}"
            "--config ${m.configFile}"
            "--vfs-cache-mode full" # real files-on-demand: open downloads, then caches
            "--vfs-cache-max-size ${m.cacheMaxSize}"
            "--vfs-cache-max-age 168h"
            "--vfs-write-back 10s" # batch writes so the UI doesn't block on every save
            "--buffer-size 32M"
            "--transfers 4"
            "--log-level INFO"
          ] ++ m.extraFlags);
          # rclone unmounts itself on SIGTERM; this is just a lazy-unmount safety net (the
          # leading `-` makes a failure non-fatal, e.g. when already unmounted).
          ExecStop = "-/run/wrappers/bin/fusermount3 -uz ${m.mountPoint}";
          Restart = "on-failure";
          RestartSec = "15s";
        };

        # Don't hammer a persistently-broken config: give up after a few quick retries.
        startLimitIntervalSec = 300;
        startLimitBurst = 5;
      })
      cfg;

    # ── The mounts themselves ──
    # Both graphical hosts get both, so they live here rather than in per-host spec.nix.
    # Keys MUST match the [section] headers in the chezmoi-managed rclone.conf.
    services.rcloneMounts = {
      # WebDAV. Long dir-cache because WebDAV CANNOT push change notifications (--poll-interval
      # is a no-op here), so browsing is fast but remote-side edits only appear once the cache
      # expires. Lower it if you start editing from many devices at once.
      FullerNextcloud.extraFlags = [ "--dir-cache-time" "72h" ];

      # Google Shared Drive. team_drive + root_folder_id live in rclone.conf, not here: they
      # define the REMOTE, not the mount's behaviour.
      AtvikGoogleDrive.extraFlags = [
        # Google-native Docs/Sheets/Slides have no byte stream to serve, so rclone exports them.
        # This IS rclone's default — stated explicitly so the choice is reviewable rather than
        # implicit, since it decides whether the mount shows .docx or nothing at all.
        "--drive-export-formats"
        "docx,xlsx,pptx,svg"
        # Unlike WebDAV above, Drive DOES support change notification — so listings stay fresh
        # without shortening --dir-cache-time.
        "--poll-interval"
        "1m"
      ];
    };
  };
}
