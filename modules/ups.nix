{ config, pkgs, lib, ... }:

# NUT (Network UPS Tools) for the CyberPower CP1500PFCLCDa on the desktop's USB.
# Standalone mode: the usbhid-ups driver talks HID Power Device to the UPS, upsd serves
# state on localhost, and upsmon shuts the box down cleanly once the UPS reports
# on-battery + low-battery (the nixpkgs module's SHUTDOWNCMD/POWERDOWNFLAG defaults
# already do the right thing). Status on demand: `upsc cyberpower`.
#
# ── Password model: per-boot random, not sops ──
# NUT has no anonymous mode — upsd.users and upsmon's MONITOR line hard-require a
# password even for loopback. But it only authenticates upsmon→upsd on 127.0.0.1, so it
# protects nothing worth managing: a oneshot generates a fresh one into /run each boot
# and both services read it at start via systemd LoadCredential (runtime, never eval —
# keeps the no-secrets-at-eval rule without burning a secrets.yaml key on a throwaway).
let
  passFile = "/run/nut-upsmon-password";
in
{
  power.ups = {
    enable = true;
    mode = "standalone";

    ups.cyberpower = {
      driver = "usbhid-ups";
      port = "auto";
      description = "CyberPower CP1500PFCLCDa";
      # Pin the exact USB device — usbhid-ups with port=auto would otherwise probe every
      # HID device, and this box is full of them (QMK keyboard, MYSTIC LIGHT, headset).
      directives = [
        "vendorid = 0764"
        "productid = 0601"
      ];
    };

    users.upsmon = {
      passwordFile = passFile;
      upsmon = "primary";
    };

    # monitor.<name>.system defaults to the attr name (= the ups.* entry above) and
    # passwordFile defaults to users.upsmon.passwordFile — only the user needs naming.
    upsmon.monitor.cyberpower.user = "upsmon";
  };

  # requiredBy (not wantedBy): if generation somehow fails, upsd/upsmon must not start
  # and then loop on a missing LoadCredential path.
  systemd.services.nut-upsmon-password = {
    description = "Generate per-boot NUT upsmon password";
    before = [ "upsd.service" "upsmon.service" ];
    requiredBy = [ "upsd.service" "upsmon.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      UMask = "0077";
    };
    # -s guard: keep the password stable across `nixos-rebuild switch` restarts within a
    # boot, or upsd and a not-yet-restarted upsmon would briefly disagree. /run is tmpfs,
    # so a reboot still rolls it. base64 charset is safe in both generated config files
    # (replace-secret substitutes literally; the value sits inside quotes in upsd.users).
    script = ''
      if [ ! -s ${passFile} ]; then
        ${pkgs.coreutils}/bin/head -c 24 /dev/urandom | ${pkgs.coreutils}/bin/base64 -w0 > ${passFile}
      fi
    '';
  };
}
