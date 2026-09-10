{ config, pkgs, lib, secrets, ... }:

# Nightly full-device iOS backups over Wi-Fi (the iTunes/Finder-style backup that can restore
# a whole phone — messages, app data, settings). Photos are NOT this module's job; they go to
# Immich in the cluster. This covers the thing Immich can't: device restore.
#
# Apple only allows Wi-Fi backups from a machine the device has TRUSTED over USB, on the same
# local network — which is why this runs on the desktop (the box phones get plugged into) and
# why nobody runs it in Kubernetes: the pairing machine and the backup machine want to be the
# same physical host.
#
# ⚠ HISTORY IS NOT AUTOMATIC. idevicebackup2 keeps ONE incrementally-updated backup per device
# and updates it IN PLACE on the share, so nothing here keeps versions: point-in-time
# recovery rests ENTIRELY on ZFS snapshots of the destination dataset. Do not assume those
# exist — on 2026-09-10 every periodic snapshot task on fullernas was found DISABLED with zero
# snapshots, which had quietly reduced this whole scheme to one overwritable copy. That is why
# `mise run ios:status` now asserts a recent snapshot instead of trusting the arrangement.
#
# ── Muxer: usbmuxd2 for USB, netmuxd for Wi-Fi ──
# Two daemons, because on modern iOS neither covers both:
#   usbmuxd2 (nixpkgs)  — USB devices + the /var/run/usbmuxd socket every idevice* tool expects.
#   netmuxd  (nvfetcher)— Wi-Fi devices, on 127.0.0.1:27015, in --upstream-usbmuxd SHIM mode so
#                         it forwards USB requests to usbmuxd2. A client pointed at that address
#                         therefore sees BOTH transports through one socket.
#
# Why not usbmuxd2 alone, given it advertises Wi-Fi support? Its Dec-2023 snapshot cannot see
# modern iOS. Verified against iOS 26.6.1 on 2026-09-10: the phone advertises itself as
#   de:08:9f:a6:76:cb@fe80::dc08:9fff:fea6:76cb-supportsRP-24._apple-mobdev2._tcp
# and serves lockdown on 62078 — while its mDNS SRV record points at a port that is CLOSED.
# usbmuxd2 parses that instance name and trusts that port, so its WIFIDeviceManager inits, finds
# nothing usable, and logs NOTHING: `idevice_id -n` stays empty forever while USB works
# perfectly. --allow-heartless-wifi does not help, which is what puts the failure at discovery
# rather than at the heartbeat. netmuxd instead identifies devices by matching the mDNS TXT
# record against the pairing records in /var/lib/lockdown, so neither quirk touches it.
#
# This does cost the module the "free of out-of-tree pins" property it used to claim. Worth it:
# the alternative is no Wi-Fi backups at all.
#
# Full runbook (setup, verification, restore, troubleshooting): docs/ios-backup.md.
#
# ── One-time runbook, per device: `mise run ios:pair` (over USB, phone unlocked) ──
# The task runs the sequence below. It's spelled out here because two of these commands are
# widely mis-documented, so the wrong version is easy to "fix" it back to:
#   1. idevicepair pair                        # accept Trust on the phone, re-run to confirm
#   2. idevicebackup2 -i encryption on <dir>   # -i or it never PROMPTS for the password, and
#                                              # DIRECTORY is a required positional — the bare
#                                              # `idevicebackup2 encryption on` in every guide
#                                              # just prints usage. Password → BITWARDEN; only
#                                              # RESTORE needs it, the nightly job doesn't.
#                                              # Encrypted backups also carry keychain/health
#                                              # data, so this isn't really optional.
#   3. idevice-wifi-sync on                    # allow lockdown connections over the network.
#                                              # NOT `idevicepair wifi on` — that subcommand has
#                                              # never existed in ANY release (upstream or fork);
#                                              # it exits "Invalid command" NON-fatally, which is
#                                              # how it survives in half the guides online. See
#                                              # pkgs/idevice-wifi-sync.c for the whole story.
#   4. idevice_id -l                           # note the UDID
#   5. mise run ios:register                   # add "<UDID> <name>" under ios: backup_devices
# Then `mise run apply`, and `mise run ios:status` to check every link in the chain at once.
# Restore drill (documented, not automated): plug in over USB and
#   idevicebackup2 restore --system --settings /mnt/main_smb/Jon/ios_backups
# (reading a restore straight off CIFS is slow but this is a rare, attended operation)
#
# ── Secret model ──
# The device list lives in sops (`ios/backup_devices`, one "<UDID> <name>" per line) because
# this repo is PUBLIC and family device UDIDs are identifying. Same eval gate as
# modules/smb-mounts.nix: the service is only declared once the key exists in secrets.yaml,
# so a fresh checkout still builds CI-green and a missing secret can't brick activation.
let
  declareSecret = secrets.has "ios/backup_devices";

  sources = pkgs.callPackage ../_sources/generated.nix { };

  # netmuxd — see the muxer section above for WHY this exists. Upstream ships a single
  # dynamically-linked Rust binary needing only glibc + libgcc_s, so unpack + autoPatchelf
  # rather than build the tree — the same treatment sofka gets in modules/common.nix.
  netmuxd = pkgs.stdenv.mkDerivation {
    inherit (sources.netmuxd) pname version src;
    sourceRoot = ".";                         # flat tarball: just `netmuxd` at the root
    nativeBuildInputs = [ pkgs.autoPatchelfHook ];
    buildInputs = [ pkgs.stdenv.cc.cc.lib ];  # libgcc_s.so.1 (Rust unwinder)
    dontConfigure = true;
    dontBuild = true;
    installPhase = "install -Dm755 netmuxd $out/bin/netmuxd";
  };

  # netmuxd's TCP listener. Clients reach BOTH transports through it (shim mode forwards USB on
  # to usbmuxd2), but this is deliberately NOT exported as a global environment variable: if
  # netmuxd were down, a global USBMUXD_SOCKET_ADDRESS would break plain USB tooling too —
  # including GVfs/Nemo mounting an iPhone for photos. The backup service sets it for itself,
  # and the ios:* mise tasks set it for themselves.
  muxAddr = "127.0.0.1:27015";

  # sops-nix default path for a `group/key` secret; hardcoded because referencing `.path`
  # on a conditionally-declared secret errors at eval when undeclared.
  devicesPath = "/run/secrets/ios/backup_devices";


  # idevicebackup2 writes STRAIGHT here — no local staging, by explicit request (2026-09-10):
  # "just have it go straight to the SMB, I don't want it locally". What that trades away,
  # recorded so the reasoning isn't lost if this ever looks slow or flaky:
  #   - Speed. A backup is 86,484 files / 514 dirs, 76% under 64 KB (measured, not guessed), and
  #     SMB is latency-bound PER FILE — so this is ~86k open/write/close round trips instead of
  #     one bulk transfer off local NVMe. Expect the seed to take substantially longer.
  #   - Availability. The NAS must now stay up for the WHOLE multi-hour transfer, not just a
  #     closing sync; the 3x retry below is what makes a blip survivable rather than fatal.
  #   - Resume state. Status.plist and the existing tree are read over CIFS on every retry.
  # What it buys: no permanent ~40-50 GB per device on the desktop's NVMe, and no `rsync
  # --delete` step that destroys the previous copy on every run.
  #
  # The CIFS automount from modules/smb-mounts.nix — first access triggers the mount.
  # NB the //…/main_smb share is the dataset main_pool/main_dataset/smb_folder — NOT
  # main_dataset, which this module and its doc both used to claim.
  #
  # ⚠ This path is a plain DIRECTORY inside that dataset, and it cannot become its own: ZFS
  # requires a dataset's parent to be a dataset, and `smb_folder/Jon` is a directory holding
  # ~830 GB of unrelated files. So iOS retention cannot be scheduled independently here — any
  # snapshot policy covering these backups necessarily covers the whole 2.3 TB share. The
  # alternative (its own dataset under computer_backups_dataset/, beside jonbackups and
  # nicolebackups, which is where this NAS already keeps device backups) would need its own SMB
  # share + mount. Unresolved as of 2026-09-10; ios:status reports the snapshot state so the
  # gap stays visible rather than silent.
  nasDir = "/mnt/main_smb/Jon/ios_backups";
in
{
  config = lib.mkMerge [
    {
      # Pairing + backup tooling on PATH for the runbook (idevicepair, idevicebackup2,
      # idevice_id) — useful even before the secret exists. idevice-wifi-sync fills the one
      # gap in that toolkit: nothing upstream can SET a lockdown value in a named domain.
      environment.systemPackages = [
        pkgs.libimobiledevice
        (import ../pkgs/idevice-wifi-sync.nix { inherit pkgs; })
        # plistutil — a backup's Status.plist is a BINARY plist, so `mise run ios:status`
        # can't just grep it to report SnapshotState.
        pkgs.libplist
      ];

      services.usbmuxd = {
        enable = true;
        # Kept over stock usbmuxd for USB even though netmuxd now owns the Wi-Fi path: it is a
        # drop-in for this same option and has proven fine on the wire we actually use it for.
        package = pkgs.usbmuxd2;
      };

      # The Wi-Fi half of the muxer story (see the header). Declared unconditionally, not behind
      # the secret gate, because pairing and `mise run ios:status` need network discovery before
      # any device has been registered for nightly backups.
      systemd.services.netmuxd = {
        description = "netmuxd — Bonjour discovery of Wi-Fi iOS devices for usbmuxd clients";
        wantedBy = [ "multi-user.target" ];
        after = [ "network-online.target" "usbmuxd.service" "avahi-daemon.service" ];
        wants = [ "network-online.target" ];
        serviceConfig = {
          # --disable-unix: usbmuxd2 owns /var/run/usbmuxd; netmuxd must not fight it for the
          #   socket, so it listens on TCP only.
          # --upstream-usbmuxd <path>: given EXPLICITLY rather than relying on its default
          #   ("system usbmuxd or $USBMUXD_SOCKET_ADDRESS"), so this can never resolve back to
          #   netmuxd itself and forward in a loop.
          ExecStart = lib.concatStringsSep " " [
            "${netmuxd}/bin/netmuxd"
            "--disable-unix"
            "--host 127.0.0.1"
            "-p 27015"
            "--upstream-usbmuxd /var/run/usbmuxd"
          ];
          # Runs as root to read the pairing records in /var/lib/lockdown. A muxer that dies
          # takes the whole Wi-Fi path with it and the nightly job would only ever report
          # DISCOVERY-TIMEOUT, so always bring it back.
          Restart = "always";
          RestartSec = "5s";
        };
        # info: logs each "Adding network device <UDID>" and the heartbeat failures that explain
        # an aborted transfer — the SleepyTime line is how we diagnosed the first real seed.
        environment.RUST_LOG = "info";
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

      systemd.services.ios-backup = {
        description = "Wi-Fi backup of paired iOS devices";
        # Best-effort dependencies; the real gate is per-device discovery below. netmuxd is the
        # one that actually matters — without it there are no network devices to find at all.
        after = [ "network-online.target" "usbmuxd.service" "netmuxd.service" ];
        wants = [ "network-online.target" "netmuxd.service" ];
        # The backup now writes directly into the CIFS automount, so it is a hard requirement
        # for the whole run rather than a final-step nicety. RequiresMountsFor pulls in the
        # automount unit and fails fast with a clear reason if the share is unreachable.
        unitConfig.RequiresMountsFor = nasDir;
        # rsync is gone with the staging step — idevicebackup2 writes to the share itself.
        path = [ pkgs.libimobiledevice ];
        # Point every idevice* call in this unit at netmuxd, which serves Wi-Fi devices itself
        # and forwards USB up to usbmuxd2. Not set globally — see muxAddr above.
        environment.USBMUXD_SOCKET_ADDRESS = muxAddr;
        serviceConfig = {
          Type = "oneshot";
          # Sequential devices × possibly-large first seeds: give it the whole night, but
          # never let a wedged transfer survive into the next scheduled run.
          TimeoutStartSec = "8h";
        };
        script = ''
          set -u
          failed=0
          seen=0

          # Devices file: "<UDID> <name>" per line; blank lines and #-comments allowed.
          #
          # `|| [ -n "$udid" ]` is load-bearing, not defensive noise: `read` returns non-zero at
          # EOF, so a final line with NO trailing newline is parsed into $udid and then DROPPED
          # by a plain `while read`. That bit us on 2026-09-10 — sops --set had written the
          # secret without a trailing newline (command substitution strips them), so this loop
          # ran ZERO times, the script fell through to the rsync, and the unit would have
          # exited 0 having backed up nothing at all. Never assume the secret is newline-
          # terminated; a hand edit via `mise run secrets:edit` can do the same thing.
          while read -r udid name _ || [ -n "$udid" ]; do
            case "$udid" in ""|\#*) continue ;; esac
            seen=$((seen + 1))

            # Wait for the phone to show up on Wi-Fi (asleep on a charger counts; off the
            # LAN doesn't). 15 min covers "walked in late"; a miss is just tonight's miss.
            # Announce it: this used to poll in COMPLETE silence for up to 15 minutes, which
            # made `mise run ios:backup` look hung and, worse, looked identical to the
            # zero-devices bug above.
            echo "waiting for $name ($udid) on the network (up to 15 min)…"
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
            #
            # RETRIES, because one interruption used to cost the whole night. A phone that
            # sleeps mid-transfer drops the lockdown connection: netmuxd logs
            # Heartbeat(SleepyTime) and idevicebackup2 dies with "Could not receive from
            # mobilebackup2 (-4)" — observed 15 GB and 86k files into the first real seed on
            # 2026-09-10. Because --full RESUMES into the existing tree, the partial transfer
            # is kept and a retry only pays for what's left, so retrying is nearly free.
            # Apple's own Wi-Fi sync assumes the device is on power; at 03:00 it should be, but
            # a phone left off the charger would otherwise lose everything to one drop.
            ok=0
            for attempt in 1 2 3; do
              echo "backing up $name ($udid) — attempt $attempt/3…"
              if idevicebackup2 -u "$udid" -n backup --full ${nasDir} < /dev/null; then
                ok=1
                break
              fi
              # Give the device time to come back (netmuxd re-adds it within ~30s of waking).
              [ "$attempt" -lt 3 ] && sleep 60
            done
            if [ "$ok" = 1 ]; then
              echo "OK $name"
            else
              echo "FAILED $name ($udid) — 3 attempts, see the netmuxd journal for why" >&2
              failed=1
            fi
          done < ${devicesPath}

          # A device list that yields nothing is a FAILURE, not a quiet no-op. Without this the
          # unit still rsyncs and exits 0, which is indistinguishable from a healthy run — the
          # exact way the missing-newline bug above hid itself.
          if [ "$seen" = 0 ]; then
            echo "NO DEVICES parsed from ${devicesPath} — nothing was backed up" >&2
            failed=1
          fi

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
