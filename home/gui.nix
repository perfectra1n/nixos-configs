{ config, pkgs, lib, osConfig, inputs, ... }:

# GUI apps — imported only by graphical hosts (desktop, laptop) via flake.nix's
# `homeModules`. Never reaches the headless server host.
let
  # Blender — GPU Cycles where the hardware can do it, with ZERO local compiling (the user's
  # explicit call, 2026-07-20: GPU rendering beats version freshness). Cycles only offers a GPU
  # device in a cudaSupport build (upstream gates CUDA and OptiX both on that flag), but that
  # override can never be cached (CUDA EULA; community caches key on their own nixpkgs rev) and
  # rebuilding blender + opensubdiv + openusd locally on every nixpkgs bump was brutal — tried
  # and dropped earlier the same day. So the NVIDIA desktop gets the blender-bin flake instead:
  # upstream's official binaries, CUDA + OptiX baked in, `default` = newest (5.0.1 vs nixpkgs'
  # 5.1.2 when added — the accepted trade-off; it auto-tracks upstream's newest on lock bumps).
  #   The laptop keeps the cached nixpkgs build, and NEWER than the desktop's: its AMD APU can't
  # do GPU Cycles either way (blender-bin's HIP path wants a supported discrete Radeon), so
  # blender-bin would cost it version freshness for nothing. EEVEE/viewport use the GPU on both.
  #   Gated on videoDrivers, NOT config.detected.nvidia: no host has committed a facter.json yet,
  # so `detected.nvidia` is false everywhere and would silently hand the desktop the CPU build.
  blender =
    if lib.elem "nvidia" osConfig.services.xserver.videoDrivers
    then inputs.blender-bin.packages.${pkgs.system}.default
    else pkgs.blender;

  # Seed content for ~/.config/kdeglobals (see home.activation.seedKdeglobals below).
  # BreezeDark.colors is already a near-complete kdeglobals — it ships [General] ColorScheme,
  # [KDE], [WM] and every [Colors:*] group — so this only appends the one group it lacks.
  # Built as a derivation rather than a heredoc inside the activation script: HM's `run`
  # wrapper echoes instead of executing under dry-run, which would swallow a heredoc body.
  kdeglobalsSeed = pkgs.runCommand "kdeglobals-breeze-dark" { } ''
    cat ${pkgs.kdePackages.breeze}/share/color-schemes/BreezeDark.colors > "$out"
    printf '\n[Icons]\nTheme=breeze-dark\n' >> "$out"
  '';
in
{
  home.packages = with pkgs; [
    kitty       # terminal
    google-chrome
    firefox
    brave
    vscode      # unfree; swap for `vscodium` for the MS-free build
    dbeaver-bin # universal DB GUI (Postgres/SQLite/MySQL/…); the binary is `dbeaver`, not
                # `dbeaver-bin`. Attr is `dbeaver-bin` and NOT `dbeaver` — upstream's switch to
                # prebuilt binaries took the old name with it, so plain `dbeaver` no longer
                # evaluates. Apache-2.0 despite the -bin, so no unfree gate. Its state lives in
                # ~/.local/share/DBeaverData, nowhere near chezmoi. CLIs are in home/common.nix.
    # ── KDE file stack ── Dolphin is $fileManager in hyprland.conf. Dolphin is a KIO client,
    # not a self-contained binary, so the companions below are load-bearing, not nice-to-haves.
    kdePackages.dolphin
    kdePackages.kio-extras        # Trash, network (smb/sftp/mtp), "Remote" places. WITHOUT this
                                  # Dolphin has no working Trash at all — deletes fail and the
                                  # Trash entry dead-ends, which reads as a broken file manager
                                  # rather than a missing package. services.gvfs (desktop-apps.nix)
                                  # is the GTK-side equivalent and is still needed for Nautilus.
    kdePackages.ark               # right-click Extract/Compress. Dolphin's counterpart to the
                                  # nemo-fileroller shim we just dropped; file-roller stays for
                                  # Nautilus (the two archive managers don't conflict).
    kdePackages.kdegraphics-thumbnailers  # PDF/SVG/RAW thumbnails in the grid
    kdePackages.ffmpegthumbs      # video thumbnails. Dolphin does NOT use ffmpegthumbnailer —
                                  # that's the GNOME/tumbler path (kept below for Nautilus).
                                  # Same job, different plugin ABI; both are needed here.
    kdePackages.breeze-icons      # icon theme KDE apps assume exists. Papirus (below) covers the
                                  # GTK side but has no Breeze-named symbolic aliases, so Dolphin's
                                  # toolbar renders half-empty without this.
    kdePackages.gwenview          # photo viewer. Claims all 10 image MIME types listed in
                                  # xdg.mimeApps below — a clean 1:1 replacement for imv.
    haruna                        # video player (mpv-based, KDE). NOTE: top-level attr, NOT
                                  # kdePackages.haruna — it isn't in the KDE Gear set.

    nautilus            # GTK fallback file manager — deliberately kept after the Dolphin swap.
                        # Still the host for sushi (Space-preview) and gnome-disk-utility's
                        # "Open in Disks", and the sane target when a GTK app hands off a folder.
    papirus-icon-theme  # actual icons for the GTK apps. `nautilus` does NOT propagate an icon
                        # theme into the HM profile, so without this XDG_DATA_DIRS has only
                        # `hicolor` (the empty fallback) and every folder/place/toolbar icon
                        # renders as a broken generic. Papirus has the widest coverage.
    adwaita-icon-theme  # base layer Papirus inherits from — covers any symbolic icons Papirus
                        # lacks, and what GNOME apps expect as the ultimate fallback.
    nautilus-python     # extension runtime (enables third-party Nautilus extensions)
    sushi               # GNOME quick-preview: select a file, hit Space to preview (no app launch)
    file-roller         # archive manager — Nautilus's "Extract"/"Compress" right-click actions
    gnome-disk-utility  # GNOME Disks — provides Nautilus's "Open in Disks" (org.gnome.DiskUtility D-Bus service)
    ffmpegthumbnailer   # video thumbnails for the GTK/tumbler side (Nautilus). Dolphin uses
                        # kdePackages.ffmpegthumbs above instead.
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
    blender     # 3D suite. blender-bin (upstream binaries, CUDA + OptiX Cycles, no compiling)
                # on the NVIDIA desktop; cached nixpkgs build (CPU Cycles) on the AMD laptop —
                # see the let-binding above for the full why. Docs: docs/packages.md.
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

  # Qt apps don't follow the portal color-scheme at all, so Qt gets themed explicitly here.
  # Breeze rather than the previous adwaita-dark: Dolphin/Gwenview/Haruna are KDE apps and
  # only look right under their native style. This also covers the pre-existing Qt apps
  # (handbrake, copyq, telegram, kdeconnect) — they were being forced into a GTK-lookalike
  # theme before, so moving them to Breeze is a lateral change, not a regression.
  #
  # platformTheme.package is pinned rather than left to auto-detect. home-manager's map for
  # name = "kde" is [ kio plasma-integration systemsettings ], and systemsettings is the whole
  # Plasma System Settings app — meaningless without plasmashell and a large closure for a
  # Hyprland session. The module takes platformTheme.package INSTEAD of the auto list (a
  # findFirst, not a merge), so naming the two we actually want drops the third.
  #
  # No widgetStyle key is set in kdeglobals: style.name exports QT_STYLE_OVERRIDE=breeze, and
  # the env var outranks kdeglobals, so writing it there too would be dead config.
  qt = {
    enable = true;
    platformTheme = {
      name = "kde";
      package = with pkgs.kdePackages; [ plasma-integration kio ];
    };
    style.name = "breeze";  # auto-resolves to kdePackages.breeze + .qt5
  };

  # Breeze reads its palette from the [Colors:*] groups in ~/.config/kdeglobals, and OUTSIDE a
  # Plasma session nothing ever populates them — so style.name alone gives Breeze-shaped but
  # BLINDING WHITE KDE apps. Seed the file from the BreezeDark scheme that ships in
  # kdePackages.breeze (it already carries [General] ColorScheme, [KDE] and [WM]; only [Icons]
  # is missing, and there's no existing [Icons] group to collide with).
  #
  # Seed-if-absent into a REAL writable file, deliberately not xdg.configFile: kdeglobals is
  # app-owned — Dolphin's and Gwenview's own settings dialogs write to it — and a read-only
  # store symlink would make those dialogs silently fail to save. Same reasoning as the DMS
  # settings.json snapshot rule. Delete the file and re-switch to reset to defaults.
  home.activation.seedKdeglobals = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    kg="${config.xdg.configHome}/kdeglobals"
    if [ ! -e "$kg" ]; then
      run mkdir -p "$(dirname "$kg")"
      run install -m644 ${kdeglobalsSeed} "$kg"
    fi
  '';

  # Default application handlers — the flake now OWNS ~/.config/mimeapps.list. Safe to own
  # here because chezmoi does NOT manage that file (no boundary collision). Captured from the
  # imperative file that accumulated via GUI "Set as default" clicks; home-manager renders the
  # WHOLE file, so every default must live here or it gets dropped. The rendered file is a
  # read-only store symlink, so GUI right-click "Set as default" no longer persists — edit
  # this block instead (it's now the single source of truth across graphical hosts).
  xdg.mimeApps = {
    enable = true;
    defaultApplications =
      # Video → Haruna (KDE, mpv-based). Enumerated per-type rather than a `video/*` glob —
      # explicit MIME types are the portable form of [Default Applications]. VLC stays
      # installed and still shows up under "Open With"; it just isn't the default any more.
      #   Four of these (x-flv, 3gpp, x-m4v, application/x-matroska) are NOT claimed by
      # org.kde.haruna.desktop's own MimeType= line. That's fine and intentional: the XDG
      # spec honors a [Default Applications] entry regardless of what the target .desktop
      # claims, and mpv plays all of them. Both .avi spellings are listed because Haruna
      # claims video/vnd.avi while the old VLC list used video/x-msvideo — which one your
      # shared-mime-info resolves to varies, so cover both rather than guess.
      (lib.genAttrs [
        "video/mp4"
        "video/x-matroska"    # .mkv
        "video/webm"
        "video/quicktime"     # .mov
        "video/x-msvideo"     # .avi (freedesktop spelling)
        "video/vnd.avi"       # .avi (IANA spelling — the one Haruna's .desktop claims)
        "video/mpeg"          # .mpg / .mpeg
        "video/x-flv"         # .flv
        "video/x-ms-wmv"      # .wmv
        "video/3gpp"          # .3gp
        "video/ogg"           # .ogv
        "video/x-m4v"         # .m4v
        "video/mp2t"          # .ts (MPEG transport stream)
        "application/x-matroska"
      ] (_: "org.kde.haruna.desktop"))
      # Images → Gwenview (KDE). Verified: org.kde.gwenview.desktop's MimeType= claims all
      # ten of these, so this is a straight 1:1 swap for the imv entry it replaces.
      // (lib.genAttrs [
        "image/png" "image/jpeg" "image/gif" "image/webp" "image/bmp"
        "image/tiff" "image/svg+xml" "image/avif" "image/heif" "image/jxl"
      ] (_: "org.kde.gwenview.desktop"))
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
        # Folders → Dolphin. NEW entry: there was no inode/directory default before, so any
        # app asking the system to "open containing folder" had no registered handler.
        "inode/directory" = "org.kde.dolphin.desktop";

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
