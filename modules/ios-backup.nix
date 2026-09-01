{ config, pkgs, lib, secrets, ... }:

# Nightly full-device iOS backups over Wi-Fi (the iTunes/Finder-style backup that can restore
# a whole phone — messages, app data, settings). Photos are NOT this module's job; they go to
# Immich in the cluster. This covers the thing Immich can't: device restore.
#
# Apple only allows Wi-Fi backups from a machine the device has TRUSTED over USB, on the same
# local network — which is why this runs on the desktop (the box phones get plugged into) and
# why nobody runs it in Kubernetes: the pairing machine and the backup machine want to be the
# same physical host. idevicebackup2 keeps ONE incrementally-updated backup per device in
# place; history/versioning comes from rsyncing the finished state to the TrueNAS share, whose
# ZFS snapshots do the point-in-time work.
#
# ── Muxer: usbmuxd2, not stock usbmuxd ──
# Stock usbmuxd is USB-only. usbmuxd2 (tihmstar's reimplementation, in nixpkgs) additionally
# discovers Wi-Fi devices via Bonjour (_apple-mobdev2._tcp) once `idevicepair wifi on` has been
# run, and is a drop-in for the same services.usbmuxd module. If it ever proves flaky the
# fallback is stock usbmuxd + a transient netmuxd on a TCP socket inside the service — but
# usbmuxd2 keeps this module free of out-of-tree pins.
#
# ── One-time runbook, per device (over USB, phone unlocked) ──
#   1. idevicepair pair                # accept the Trust dialog on the phone
#   2. idevicebackup2 encryption on    # set a backup password — STORE IT IN BITWARDEN.
#                                      # Only restore ever needs it; the nightly job doesn't.
#                                      # Encrypted backups also include keychain/health data.
#   3. idevicepair wifi on             # allow lockdown connections over the network
#   4. idevice_id -l                   # note the UDID
#   5. mise run secrets:edit           # add "<UDID> <name>" line under ios: backup_devices
# Restore drill (documented, not automated): plug in over USB and
#   idevicebackup2 restore --system --settings /var/backup/ios
#
# ── Secret model ──
# The device list lives in sops (`ios/backup_devices`, one "<UDID> <name>" per line) because
# this repo is PUBLIC and family device UDIDs are identifying. Same eval gate as
# modules/smb-mounts.nix: the service is only declared once the key exists in secrets.yaml,
# so a fresh checkout still builds CI-green and a missing secret can't brick activation.
let
  declareSecret = secrets.has "ios/backup_devices";

  # sops-nix default path for a `group/key` secret; hardcoded because referencing `.path`
  # on a conditionally-declared secret errors at eval when undeclared.
  devicesPath = "/run/secrets/ios/backup_devices";

  # Local NVMe staging. Manifest.db is a heavily-rewritten sqlite file; backing up straight
  # onto the CIFS mount would be slow and corruption-prone, so back up locally, then sync.
  stagingDir = "/var/backup/ios";

  # The CIFS automount from modules/smb-mounts.nix — first access triggers the mount.
  nasDir = "/mnt/main_smb/iOSBackups";
in
{
  config = lib.mkMerge [
    {
      # Pairing + backup tooling on PATH for the runbook (idevicepair, idevicebackup2,
      # idevice_id) — useful even before the secret exists.
      environment.systemPackages = [ pkgs.libimobiledevice ];

      services.usbmuxd = {
        enable = true;
        package = pkgs.usbmuxd2; # Wi-Fi-capable; see the muxer note above
      };

      # usbmuxd2 finds Wi-Fi devices through an Avahi client, so the daemon must run.
      # Desktop already gets an identical block from modules/printing.nix — equal bool
      # definitions merge cleanly, and declaring it here keeps this module self-contained
      # (same convention printing.nix/miracast.nix already follow with each other).
      services.avahi = {
        enable = true;
        nssmdns4 = true;
        openFirewall = true;
      };
    }

    (lib.mkIf declareSecret {
      # root-only: the service runs as root (pairing records in /var/lib/lockdown).
      sops.secrets."ios/backup_devices".mode = "0400";

      systemd.tmpfiles.rules = [
        # 0700 root: an unencrypted-metadata backup tree is nobody else's business.
        "d ${stagingDir} 0700 root root -"
      ];

      systemd.services.ios-backup = {
        description = "Wi-Fi backup of paired iOS devices";
        # Best-effort network dependencies; the real gate is per-device discovery below.
        after = [ "network-online.target" "usbmuxd.service" ];
        wants = [ "network-online.target" ];
        path = [ pkgs.libimobiledevice pkgs.rsync ];
        serviceConfig = {
          Type = "oneshot";
          # Sequential devices × possibly-large first seeds: give it the whole night, but
          # never let a wedged transfer survive into the next scheduled run.
          TimeoutStartSec = "8h";
        };
        script = ''
          set -u
          failed=0

          # Devices file: "<UDID> <name>" per line; blank lines and #-comments allowed.
          while read -r udid name _; do
            case "$udid" in ""|\#*) continue ;; esac

            # Wait for the phone to show up on Wi-Fi (asleep on a charger counts; off the
            # LAN doesn't). 15 min covers "walked in late"; a miss is just tonight's miss.
            deadline=$(( $(date +%s) + 900 ))
            until idevice_id -n | grep -qF "$udid"; do
              if [ "$(date +%s)" -gt "$deadline" ]; then
                echo "DISCOVERY-TIMEOUT $name ($udid) — not on the network tonight" >&2
                failed=1
                continue 2
              fi
              sleep 15
            done

            # --full is the mode the network-backup guides validated: it recovers cleanly
            # from an interrupted previous run, and the device still only sends changed
            # files into the existing per-UDID tree.
            # </dev/null: we're inside `while read < devices`, and idevicebackup2 prompts on
            # stdin in some error paths — it must not eat the rest of the device list.
            echo "backing up $name ($udid)…"
            if idevicebackup2 -u "$udid" -n backup --full ${stagingDir} < /dev/null; then
              echo "OK $name"
            else
              echo "FAILED $name ($udid) — idevicebackup2 exit $?" >&2
              failed=1
            fi
          done < ${devicesPath}

          # Ship the finished state to the NAS even if one device failed — a fresh copy of
          # the others is worth having. -rt (not -a): the CIFS mount maps ownership/modes
          # itself, and mtimes are what keep re-syncs incremental. --delete keeps the NAS
          # tree an exact mirror; history lives in the dataset's ZFS snapshots, not here.
          rsync -rt --delete ${stagingDir}/ ${nasDir}/ || failed=1

          exit $failed
        '';
      };

      systemd.timers.ios-backup = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "03:00"; # phones docked and charging
          # Desktop asleep/off at 03:00 → run at the next boot instead of skipping a night.
          Persistent = true;
          RandomizedDelaySec = "15m";
        };
      };
    })
  ];
}
