{ config, pkgs, lib, username, ... }:

# Shared by all graphical hosts (desktop, laptop). NOT imported by server.
# WM-agnostic: networking, audio, fonts, graphical group memberships, shared GUI apps.
let
  # Second Trilium desktop instance, synced to the Atvik server (the default instance
  # syncs to the personal one). Everything hangs off two env vars, both verified against
  # the pinned upstream source (apps/{server,desktop}/src):
  #   TRILIUM_DATA_DIR — separate document.db + sync-server config (created on first run);
  #   TRILIUM_PORT     — REQUIRED, not cosmetic: the Electron build ignores config.ini's
  #     Network.port (port.ts hardcodes 37840 prod / 37740 dev), and Electron's userData
  #     dir + single-instance lock are keyed on this port (main.ts getUserData →
  #     "<appData>/<name>-<port>"), so a distinct port is what lets both instances run
  #     simultaneously with separate Chromium profiles. 37841 is clear of both defaults.
  # Set unconditionally (not ''${VAR:-default}) so a leaked ambient TRILIUM_DATA_DIR can
  # never silently point this client at the personal DB.
  # ⚠️ flake.nix's trilium bump warning now applies to BOTH data dirs: back up each
  # document.db before switching onto a bump, and bump the client only after the older
  # of the two servers has been upgraded (sync protocol must stay in step).
  trilium-atvik =
    let
      wrapper = pkgs.writeShellScriptBin "trilium-atvik" ''
        export TRILIUM_DATA_DIR="$HOME/.local/share/trilium-data-atvik"
        export TRILIUM_PORT=37841
        exec ${pkgs.trilium-desktop}/bin/trilium "$@"
      '';
    in
    pkgs.symlinkJoin {
      name = "trilium-atvik";
      paths = [
        wrapper
        # Launcher entry. Icon=trilium resolves from the base package's hicolor theme
        # (also in systemPackages). StartupWMClass=electron matches what the windows
        # actually report — see the shared-Electron app_id note in chromium-cm-fix.nix;
        # the shell cannot distinguish the two instances by class, only by title.
        (pkgs.makeDesktopItem {
          name = "trilium-atvik";
          desktopName = "Atvik Trilium Notes";
          exec = "${wrapper}/bin/trilium-atvik";
          icon = "trilium";
          comment = "Trilium desktop synced to the Atvik server";
          categories = [ "Office" ];
          startupWMClass = "electron";
        })
      ];
    };
in
{
  networking.networkmanager.enable = true; # nm-applet / waybar network module

  # NM ships at WARN, which logs nothing for a normal DHCP renewal, carrier event or
  # device state change. Two separate "the network keeps dropping" investigations here
  # stalled on exactly that hole: with the NIC counters clean and NM silent, there was no
  # way to tell an actual lease/carrier loss apart from an application-side stall, and both
  # had to be re-derived from live packet capture. INFO makes the next one answerable from
  # `journalctl -u NetworkManager` alone. Costs a couple hundred lines a day; veths and
  # vmnet are unmanaged by NM, so container churn does not land here.
  networking.networkmanager.logLevel = "INFO";

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
    trilium-desktop # TriliumNext notes. NOT nixpkgs' — modules/chromium-cm-fix.nix rebinds
                    # this attr to upstream's flake (built from source) + the HDR flag.
    trilium-atvik   # second instance (Atvik server) — wrapper defined above; wraps
                    # pkgs.trilium-desktop, so it inherits the rebind + HDR flag for free.
    posy-cursors    # Windows cursor (Posy's Improved Cursors). Theme name "Posy_Cursor"
                    # set in home/gui.nix dconf + chezmoi (hyprland.conf XCURSOR_THEME).
                    # cc-by-nc license → unfree (allowUnfree covers it).
  ];

  # Graphical-only groups, merged onto the common user.
  users.users.${username}.extraGroups = [ "networkmanager" "video" "audio" ];
}
