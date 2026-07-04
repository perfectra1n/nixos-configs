{ config, pkgs, lib, ... }:

# Laptop-specific bits — the `laptop` host. Power management + lid/backlight.
# (m00n's ppd-auto idea: power-profiles-daemon switches profiles on AC/battery.)
{
  # power-profiles-daemon: integrates with the desktop power applet and switches
  # the platform profile. Mutually exclusive with TLP — pick one. PPD is the simpler,
  # GNOME/KDE-native choice; swap to services.tlp for finer-grained control.
  services.power-profiles-daemon.enable = true;

  # Suspend on lid close; logind handles the event. (NixOS renamed the old
  # services.logind.lidSwitch to the freedesktop-native settings.Login.* namespace.)
  services.logind.settings.Login.HandleLidSwitch = "suspend";

  # Backlight control without root (brightnessctl is in modules/hyprland.nix).
  hardware.acpilight.enable = true;

  # Once a facter.json exists for this host you can assert the detection instead of
  # trusting the host name, e.g.:
  #   warnings = lib.optional (!config.detected.isLaptop)
  #     "laptop.nix is imported but facter did not detect a laptop form factor";

  # Firmware updates (fwupdmgr) — handy on laptops with vendor firmware.
  services.fwupd.enable = true;
}
