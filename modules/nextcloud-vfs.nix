{ config, pkgs, lib, username, secrets, ... }:

# Files-on-demand "virtual drive" for Nextcloud — the thing the official desktop client
# still does NOT do natively on Linux (its only Linux VFS is the clunky, experimental
# `.nextcloud`-suffix placeholder mode). Instead we mount Nextcloud's WebDAV with rclone's
# VFS cache, which gives a real on-demand mount: files appear instantly, download on access,
# and stay cached up to a size cap (rclone evicts the oldest). This is SEPARATE from the
# `nextcloud-client` sync folder (~/Nextcloud) — that one fully syncs; this one is the
# "huge archive visible but not stored locally" view, mounted at ~/NextcloudVFS.
#
# ── Secret model ──
# The whole rclone remote (url + vendor + user + obscured password) lives as ONE sops secret
# `nextcloud/rclone_conf` (a multi-line rclone.conf), decrypted to /run/secrets at activation.
# rclone reads it read-only via `--config`; nothing host-specific touches the nix store. Build
# the value once and add it with `mise run secrets:edit`:
#
#   pass=$(rclone obscure 'YOUR_NEXTCLOUD_APP_PASSWORD')   # app password, NOT your login pw
#   # then paste under the `nextcloud:` key in secrets/secrets.yaml:
#   #   nextcloud:
#   #     rclone_conf: |
#   #       [FullerNextcloud]           # section name must match services.nextcloudVfs.remote
#   #       type = webdav
#   #       url = https://your-server/remote.php/dav/files/<user>/
#   #       vendor = nextcloud          # Nextcloud-specific: chunked uploads + correct moves/quota
#   #       user = <user>
#   #       pass = <the obscured string from above>
#
# ── No-choke design (two layers) ──
#   1. EVAL gate: the sops secret is only DECLARED once secrets.yaml actually contains the
#      `rclone_conf` key (sops leaves keys in plaintext, only values are encrypted, so a raw
#      readFile can detect it). Until then, declaring it would make sops activation fail with
#      "the key 'nextcloud' cannot be found" and brick `nixos-rebuild`. So a fresh checkout /
#      placeholder secrets.yaml switches cleanly and this module adds nothing but the package.
#   2. RUNTIME gate: the mount is a *user* service (can't block system activation) AND carries
#      `ConditionPathExists` on the decrypted config. If the secret isn't there, systemd marks
#      the unit *skipped* (condition not met) — not failed — so there's no crash loop and the
#      login/system comes up totally clean. The mount simply starts working the moment the
#      secret lands and you rebuild.
#
# Graphical-host feature → the flake (not chezmoi). Opted into by the Hyprland hosts via
# extraModules. The rclone.conf is a sops secret, NOT a chezmoi/home-manager ~/.config file,
# so it does not touch the chezmoi boundary.
let
  cfg = config.services.nextcloudVfs;

  # sops leaves YAML KEYS in plaintext (only values are encrypted), so a raw read tells us
  # whether the secret has actually been added yet — the tolerate-missing-secret gate, now shared
  # via lib/secrets.nix. `has` also rejects the shipped unencrypted stub.
  declareSecret = secrets.has "nextcloud/rclone_conf";

  # sops-nix default location for a `name/subname` secret. Hardcoded (not the `.path` attr)
  # because the secret is only conditionally declared — referencing `.path` when undeclared
  # would error at eval. When undeclared, this path simply never exists → the unit skips.
  secretPath = "/run/secrets/nextcloud/rclone_conf";
in
{
  options.services.nextcloudVfs = {
    remote = lib.mkOption {
      type = lib.types.str;
      default = "FullerNextcloud";
      description = "rclone remote name — must match the [section] header in the sops rclone_conf.";
    };

    mountPoint = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/FullerNextcloud";
      description = ''
        Where to mount. Under /mnt (alongside the SMB share) rather than ~ so all the
        "external storage" lives in one place. Kept distinct from ~/Nextcloud (the
        nextcloud-client sync folder) on purpose — mounting over a synced dir would collide.
        NOTE: /mnt is root-owned, and this is a *user* service that can't mkdir there, so the
        mountpoint is pre-created (owned by the user) via systemd.tmpfiles below.
      '';
    };

    cacheMaxSize = lib.mkOption {
      type = lib.types.str;
      default = "20G";
      description = "VFS cache cap (--vfs-cache-max-size); rclone evicts the oldest cached files past this.";
    };

    extraFlags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "--dir-cache-time" "5m" ];
      description = ''
        Extra rclone mount flags, appended last (so they override the defaults below). Use this
        to trade freshness for speed: a long --dir-cache-time makes browsing fast but, because
        WebDAV CANNOT push change notifications (--poll-interval is a no-op here), remote-side
        changes only appear when the dir cache expires. Lower it if you edit from many devices.
      '';
    };
  };

  config = {
    # `rclone config`/`rclone obscure` available system-wide; fuse3 provides fusermount3.
    environment.systemPackages = [ pkgs.rclone pkgs.fuse3 ];

    # /mnt is root-owned and this is a *user* service that can't mkdir there. Pre-create the
    # mountpoint owned by the user (at boot, as root) so the user mount can land on it.
    systemd.tmpfiles.rules = [ "d ${cfg.mountPoint} 0755 ${username} users - -" ];

    # See no-choke layer #1. Owner=user so the user mount service can read it.
    sops.secrets = lib.mkIf declareSecret {
      "nextcloud/rclone_conf" = {
        owner = username;
        mode = "0400";
      };
    };

    systemd.user.services.nextcloud-vfs = {
      description = "Nextcloud files-on-demand mount (rclone WebDAV + VFS cache)";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "default.target" ];

      # No-choke layer #2: skip cleanly (condition unmet, NOT a failure) until the sops secret
      # exists. So this unit is inert on a box that hasn't added the secret yet.
      unitConfig.ConditionPathExists = secretPath;

      serviceConfig = {
        # rclone speaks sd_notify: it signals READY=1 only once the mount is actually usable.
        Type = "notify";
        # Mount needs the setuid fusermount3 wrapper (NixOS provides /run/wrappers/bin/fusermount3
        # by default); put it first on PATH so rclone uses it rather than the plain fuse3 binary.
        Environment = "PATH=/run/wrappers/bin:/run/current-system/sw/bin";
        # No ExecStartPre mkdir: the mountpoint is pre-created (owned by the user) by the
        # systemd.tmpfiles rule above — a user service can't mkdir under root-owned /mnt.
        ExecStart = lib.concatStringsSep " " ([
          "${pkgs.rclone}/bin/rclone mount"
          "${cfg.remote}: ${cfg.mountPoint}"
          "--config ${secretPath}"
          "--vfs-cache-mode full"          # real files-on-demand: open downloads, then caches
          "--vfs-cache-max-size ${cfg.cacheMaxSize}"
          "--vfs-cache-max-age 168h"
          "--vfs-write-back 10s"           # batch writes so the UI doesn't block on every save
          "--dir-cache-time 72h"           # fast listings (WebDAV can't push changes anyway)
          "--buffer-size 32M"
          "--transfers 4"
          "--log-level INFO"
        ] ++ cfg.extraFlags);
        # rclone unmounts itself on SIGTERM; this is just a lazy-unmount safety net (the leading
        # `-` makes a failure non-fatal, e.g. when already unmounted).
        ExecStop = "-/run/wrappers/bin/fusermount3 -uz ${cfg.mountPoint}";
        Restart = "on-failure";
        RestartSec = "15s";
      };

      # Don't hammer a persistently-broken config: give up after a few quick retries.
      startLimitIntervalSec = 300;
      startLimitBurst = 5;
    };
  };
}
