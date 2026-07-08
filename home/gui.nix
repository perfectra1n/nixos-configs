{ config, pkgs, lib, osConfig, ... }:

# GUI apps — imported only by graphical hosts (desktop, laptop) via flake.nix's
# `homeModules`. Never reaches the headless server host.
{
  home.packages = with pkgs; [
    kitty       # terminal
    google-chrome
    firefox
    brave
    vscode      # unfree; swap for `vscodium` for the MS-free build
    nautilus            # file manager ($fileManager in hyprland.conf). GTK4/libadwaita, so
                        # it follows the portal color-scheme + DMS's matugen gtk-4.0 colors.
    papirus-icon-theme  # actual icons. `nautilus` does NOT propagate an icon theme into the
                        # HM profile, so without this XDG_DATA_DIRS has only `hicolor` (the
                        # empty fallback) and every folder/place/toolbar icon renders as a
                        # broken generic. Papirus has the widest coverage; theme name (below).
    adwaita-icon-theme  # base layer Papirus inherits from — covers any symbolic icons Papirus
                        # lacks, and what GNOME apps expect as the ultimate fallback.
    nautilus-python     # extension runtime (enables third-party Nautilus extensions)
    sushi               # GNOME quick-preview: select a file, hit Space to preview (no app launch)
    file-roller         # archive manager — Nautilus's "Extract"/"Compress" right-click actions
    nemo                # default file manager ($fileManager in hyprland.conf), Cinnamon/GTK3.
                        # Preferred over Nautilus for the things GNOME stripped out — dual-pane,
                        # type-ahead find, "Open as root", configurable columns — and it follows
                        # the gtk-3.0 settings.ini + dank-colors.css import. Nautilus stays
                        # installed (below) as a GTK4 fallback + host for sushi/Open-in-Disks.
    nemo-fileroller     # wires file-roller into Nemo's right-click Extract/Compress menu
    gnome-disk-utility  # GNOME Disks — provides Nautilus's "Open in Disks" (org.gnome.DiskUtility D-Bus service)
    ffmpegthumbnailer   # video thumbnails in the file grid (images work out of the box)
    bitwarden-desktop # Bitwarden vault GUI (the `bw` CLI lives in home/common.nix)
    evolution   # ~/.config/evolution
    slack       # official Slack desktop client (unfree)
    teams-for-linux # Teams: MS killed the official Linux desktop client (EOL 2022); this is the maintained Electron wrapper
    copyq       # clipboard manager (works on X11 + Wayland)
    handbrake   # video transcoder (GUI + HandBrakeCLI) — graphical hosts only
    libreoffice-fresh # full office suite (Writer/Calc/Impress/…); `-fresh` is the newer feature
                      # branch over `-still`. GTK3 frontend, so it follows the gtk-3.0 dark theme.
    wineWow64Packages.stable # Wine, new WoW64 build (64-bit, runs 32-bit exes too): `wine program.exe`
    winetricks  # installs Windows DLLs/runtimes into a wine prefix
  ];

  # System dark mode + cursor for GTK apps. color-scheme is what the portal advertises, so
  # GTK4/libadwaita, Electron, and Firefox render dark. cursor-theme/-size stop GTK apps
  # falling back to Adwaita's default cursor; all must name the SAME installed theme
  # (Posy_Cursor, from posy-cursors in modules/desktop-base.nix) or the cursor flip-flops
  # per-app. Requires programs.dconf.enable (set in modules/desktop-base.nix).
  dconf.settings."org/gnome/desktop/interface" = {
    color-scheme = "prefer-dark";
    cursor-theme = "Posy_Cursor";
    cursor-size = 24;
    # GTK4/libadwaita reads the icon theme from GSettings (no gnome-settings-daemon needed,
    # same path as cursor-theme above) and it overrides chezmoi's settings.ini. Names the
    # papirus-icon-theme added to home.packages — without this Nautilus falls back to
    # `hicolor` and shows broken icons everywhere.
    icon-theme = "Papirus-Dark";
  };

  # NOTE: deliberately NO `gtk = { ... }` here. home-manager's gtk module writes
  # ~/.config/gtk-{3,4}.0/settings.ini, which CHEZMOI owns (the boundary) — HM refuses to
  # clobber chezmoi's file and the WHOLE activation aborts (taking monitors.conf etc. with
  # it). The GTK3 dark-theme hint (gtk-application-prefer-dark-theme=1) lives in chezmoi's
  # settings.ini instead; GTK4/libadwaita follow color-scheme via the dconf block above.

  # Qt apps (handbrake, copyq, …) don't follow the portal color-scheme at all. Point the Qt
  # platform theme at Adwaita and force the dark variant so they match the GTK look. This
  # exports QT_QPA_PLATFORMTHEME + QT_STYLE_OVERRIDE and pulls in adwaita-qt for Qt5/Qt6.
  qt = {
    enable = true;
    platformTheme.name = "adwaita";
    style.name = "adwaita-dark";
  };

  # Default application handlers — the flake now OWNS ~/.config/mimeapps.list. Safe to own
  # here because chezmoi does NOT manage that file (no boundary collision). Captured from the
  # imperative file that accumulated via GUI "Set as default" clicks; home-manager renders the
  # WHOLE file, so every default must live here or it gets dropped. The rendered file is a
  # read-only store symlink, so GUI right-click "Set as default" no longer persists — edit
  # this block instead (it's now the single source of truth across graphical hosts).
  xdg.mimeApps = {
    enable = true;
    defaultApplications =
      # Video → VLC (the point of this change). Enumerated per-type rather than a `video/*`
      # glob — explicit MIME types are the portable form of [Default Applications].
      (lib.genAttrs [
        "video/mp4"
        "video/x-matroska"    # .mkv
        "video/webm"
        "video/quicktime"     # .mov
        "video/x-msvideo"     # .avi
        "video/mpeg"          # .mpg / .mpeg
        "video/x-flv"         # .flv
        "video/x-ms-wmv"      # .wmv
        "video/3gpp"          # .3gp
        "video/ogg"           # .ogv
        "video/x-m4v"         # .m4v
        "video/mp2t"          # .ts (MPEG transport stream)
        "application/x-matroska"
      ] (_: "vlc.desktop"))
      # Images → imv (Wayland image viewer, desktop-apps.nix)
      // (lib.genAttrs [
        "image/png" "image/jpeg" "image/gif" "image/webp" "image/bmp"
        "image/tiff" "image/svg+xml" "image/avif" "image/heif" "image/jxl"
      ] (_: "imv.desktop"))
      # Audio → VLC. Enumerated for the same reason as video: an `audio/*` glob is NOT honored
      # as a default, so HandBrake (which also claims audio types) wins otherwise.
      // (lib.genAttrs [
        "audio/mpeg"          # .mp3
        "audio/flac"
        "audio/x-flac"
        "audio/ogg"
        "audio/x-vorbis+ogg"
        "audio/opus"
        "audio/aac"
        "audio/mp4"           # .m4a
        "audio/x-m4a"
        "audio/wav"
        "audio/x-wav"
        "audio/webm"
        "audio/x-ms-wma"      # .wma
        "audio/aiff"
        "audio/x-aiff"
      ] (_: "vlc.desktop"))
      // {
        # Web / mail / generic schemes + PDF → Chrome
        "text/html" = "google-chrome.desktop";
        "x-scheme-handler/http" = "google-chrome.desktop";
        "x-scheme-handler/https" = "google-chrome.desktop";
        "x-scheme-handler/about" = "google-chrome.desktop";
        "x-scheme-handler/unknown" = "google-chrome.desktop";
        "x-scheme-handler/mailto" = "google-chrome.desktop";
        "application/pdf" = "google-chrome.desktop";

        # App-specific scheme handlers
        "x-scheme-handler/slack" = "slack.desktop";
        "x-scheme-handler/discord" = "vesktop.desktop";  # dropped the stale numeric
                                                         # discord-<id> handler (official
                                                         # Discord → now vesktop)
        "x-scheme-handler/claude-cli" = "claude-code-url-handler.desktop";
        "application/sql" = "code.desktop";
      };
    # [Added Associations] — extra (non-default) openers offered in "Open With".
    associations.added = {
      "text/csv" = "calc.desktop";
      "application/sql" = "code.desktop";
    };
  };

  # ── Browser CA trust: Chrome / Brave / Chromium ──
  # These use the per-user NSS db (~/.pki/nssdb), not the system bundle, so import the
  # custom CAs there. Driven by osConfig.security.pki.certificateFiles — the SAME
  # per-host-merged list the system trusts — so each host's browsers trust exactly its
  # shared+host CAs, no duplication. (Firefox is covered by the enterprise-roots policy in
  # modules/desktop-base.nix.) certutil from pkgs.nssTools. Inert when the list is empty.
  home.activation.trustCustomCAs = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    db="$HOME/.pki/nssdb"
    run mkdir -p "$db"
    [ -f "$db/cert9.db" ] || run ${pkgs.nssTools}/bin/certutil -N -d sql:"$db" --empty-password
    ${lib.concatMapStringsSep "\n" (c: ''
      run ${pkgs.nssTools}/bin/certutil -D -d sql:"$db" -n "${baseNameOf c}" 2>/dev/null || true
      run ${pkgs.nssTools}/bin/certutil -A -a -d sql:"$db" -t "C,," -n "${baseNameOf c}" -i "${c}"
    '') osConfig.security.pki.certificateFiles}
  '';
}
