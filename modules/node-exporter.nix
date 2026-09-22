{ config, pkgs, lib, ... }:

# Host metrics for the homelab's VictoriaMetrics (`vmetrics` — the thing promtool in
# home/common.nix queries). On EVERY host, so a box is never invisible when it stalls.
#
# Two exporters, because one genuinely cannot do the other's job:
#   node     (9100) — /proc + statfs: CPU, memory, systemd unit states, disk IO, fs space.
#   smartctl (9633) — the drive's own health registers: wear level, media errors,
#                     temperature, power-on hours. node-exporter's diskstats collector
#                     CANNOT reach these — they come from NVMe/ATA ioctls needing
#                     CAP_SYS_RAWIO, which is exactly why upstream ships smartctl as a
#                     separate unit with a scoped capability set and DeviceAllow list.
#
# Both default to listenAddress 0.0.0.0. The global firewall is off (modules/common.nix),
# so openFirewall is a no-op today — set anyway to stay honest if that ever flips, same
# as services.avahi in modules/miracast.nix.
{
  services.prometheus.exporters.node = {
    enable = true;
    openFirewall = true;

    # Beyond the always-on defaults (diskstats, filesystem, cpu, meminfo, …):
    #   systemd  — per-unit active/failed state. Catches a failed home-manager-<user>.service,
    #              which silently freezes ALL home-manager file updates until resolved
    #              (the chezmoi-collision failure mode documented in CLAUDE.md).
    #   processes — per-state process counts; spots runaway or zombie build jobs.
    #   textfile  — scrapes any *.prom file dropped in the directory below, so future
    #              one-off metrics need no new exporter, port, or scrape config.
    enabledCollectors = [ "systemd" "processes" "textfile" ];
    extraFlags = [ "--collector.textfile.directory=/var/lib/node-exporter-textfiles" ];
  };

  # The textfile directory must exist BEFORE the collector starts, or node-exporter logs a
  # read error on every single scrape. Root-owned: the exporter only reads it, and anything
  # writing metrics here is a root systemd unit.
  systemd.tmpfiles.rules = [
    "d /var/lib/node-exporter-textfiles 0755 root root -"
  ];

  services.prometheus.exporters.smartctl = {
    enable = true;
    openFirewall = true;
    # Empty = autodiscover every disk. Deliberate: swapping a drive (the U.2 that prompted
    # this module) must not require editing a device list here to keep being monitored.
    devices = [ ];
  };

  # NOTE for whoever enables this on a new host and sees ZERO device metrics while the unit
  # sits happily "active", every scrape logging "Smartctl open device: /dev/nvme0 failed:
  # Permission denied":
  #
  # Nothing is missing from this module. nixpkgs already ships the fix — exporters.nix adds a
  # udev rule setfacl'ing g:smartctl-exporter-access:rw onto the NVMe char devices, and that
  # ACL is what grants access. (systemd's DeviceAllow=char-nvme only opens the cgroup device
  # gate; the ordinary DAC check on a crw------- root root node runs after it and would still
  # refuse — both layers have to agree.)
  #
  # The catch is that the rule is ACTION=="add". udev does NOT re-apply rules to device nodes
  # that already exist, so on the rebuild that first enables this exporter the live /dev/nvme*
  # nodes — created back at boot — never see the ACL. It looks broken and is not.
  #
  # Fix: reboot, or `udevadm trigger --action=add --subsystem-match=nvme`. The --action=add is
  # load-bearing and easy to miss: bare `udevadm trigger` defaults to --action=change, which
  # does NOT match this rule, so it leaves the ACL unset and looks like the fix didn't work.
  #
  # Verify with `getfacl /dev/nvme0` and expect a g:smartctl-exporter-access:rw entry — NOT
  # with `ls`, which renders the ACL mask in the group triad and so reads 0660 either way.
  #
  # SATA/SAS hosts never hit this: /dev/sda is brw-rw---- root disk and the unit already holds
  # the `disk` group. It is NVMe-only because SMART there is read from the char CONTROLLER
  # (/dev/nvme0), not the block namespace (/dev/nvme0n1).
}