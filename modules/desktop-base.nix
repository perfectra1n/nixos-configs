{ config, pkgs, lib, username, ... }:

# Shared by all graphical hosts (desktop, laptop). NOT imported by server/wsl.
# WM-agnostic: networking, audio, fonts, graphical group memberships, shared GUI apps.
{
  networking.networkmanager.enable = true; # nm-applet / waybar network module

  # ── UPower (power-source daemon) ──
  # NixOS doesn't enable it on a WM-only setup, but DankMaterialShell reads battery/power
  # data from it (BatteryService → Quickshell.Services.UPower) — without it the DMS battery
  # widget is blank on the laptop. Distinct from power-profiles-daemon (modules/laptop.nix),
  # which only drives the AC/battery profile selector, not the battery readout.
  services.upower.enable = true;

  # ── Audio (PipeWire) ──
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    pulse.enable = true;
  };

  # ── OpenGL / graphics drivers ──
  # Without this, GL apps fall back to LLVMpipe (software GL). Matters for the real GPU.
  hardware.graphics.enable = true;

  # ── Fonts — bar/prompt glyphs (waybar, starship) ──
  fonts.packages = with pkgs; [
    nerd-fonts.jetbrains-mono
    nerd-fonts.fira-code
    noto-fonts
    noto-fonts-color-emoji # renamed from noto-fonts-emoji in nixpkgs
  ];

  fonts.fontconfig = {
    antialias = true;
    hinting = {
      enable = true;
      # "slight" suits high-DPI panels — enough grid-snapping to stay crisp without
      # "full" distorting glyph shapes. Bump to "full" on a low-DPI screen if fuzzy.
      style = "slight";
    };
    subpixel.rgba = "none"; # grayscale AA — safe default across OLED + LCD
    defaultFonts = {
      sansSerif = [ "Noto Sans" ];
      serif = [ "Noto Serif" ];
      monospace = [ "JetBrainsMono Nerd Font" ];
      emoji = [ "Noto Color Emoji" ];
    };
  };

  # ── System dark mode ──
  # xdg-desktop-portal-gtk serves the color-scheme over the portal; GTK4/libadwaita,
  # Electron, and Firefox follow it. dconf must be on; the value is set in home/gui.nix.
  programs.dconf.enable = true;

  # ── Browser CA trust: Firefox ──
  # Firefox uses its own NSS store and ignores the system CA bundle unless told to import
  # OS/enterprise roots. This policy makes it trust the custom CAs added via
  # security.pki.certificateFiles. Chrome/Brave use ~/.pki/nssdb instead — handled by
  # home.activation.trustCustomCAs in home/gui.nix. Inert until you add custom CAs.
  environment.etc."firefox/policies/policies.json".text = builtins.toJSON {
    policies.Certificates.ImportEnterpriseRoots = true;
  };

  # ── Shared graphical apps (all graphical hosts) ──
  environment.systemPackages = with pkgs; [
    trilium-desktop # TriliumNext notes
    posy-cursors    # Windows cursor (Posy's Improved Cursors). Theme name "Posy_Cursor"
                    # set in home/gui.nix dconf + chezmoi (hyprland.conf XCURSOR_THEME).
                    # cc-by-nc license → unfree (allowUnfree covers it).
  ];

  # Graphical-only groups, merged onto the common user.
  users.users.${username}.extraGroups = [ "networkmanager" "video" "audio" ];
}
