{ config, pkgs, lib, inputs, ... }:

# Wayland + Hyprland stack (desktop, laptop). The ~/.config/hypr + waybar dotfiles
# these tools expect are owned by chezmoi, NOT this repo (see README "Boundary").
let
  # hypr-cheatsheet — a searchable rofi overlay of every active keybind. The data is read
  # LIVE from `hyprctl binds -j`, so it never drifts from the chezmoi-owned binds. Those binds
  # use the `bindd =` variant (MODS, KEY, <description>, dispatcher, args), so each row carries
  # a human-readable `.description` — the middle column below. Binds with no description fall
  # back to just showing the dispatcher, so this degrades gracefully if any plain `bind =` slips in.
  # The jq filter decodes Hyprland's modmask bitmask (SHIFT=1, CTRL=4, ALT=8, SUPER=64) into
  # readable combos and drops the noise `submap → reset` rows. Bind it in hyprland.conf, e.g.
  #   bindd = SUPER, slash, Show this keybind cheatsheet, exec, hypr-cheatsheet
  hypr-cheatsheet =
    let
      filter = pkgs.writeText "hypr-binds.jq" ''
        def mods(m):
          [ if (m/1|floor)%2==1 then "SHIFT" else empty end,
            if (m/4|floor)%2==1 then "CTRL"  else empty end,
            if (m/8|floor)%2==1 then "ALT"   else empty end,
            if (m/64|floor)%2==1 then "SUPER" else empty end ] | join("+");
        .[]
        | select((.dispatcher == "submap" and .arg == "reset") | not)
        | ( (if .submap != "" then "[" + .submap + "] " else "" end)
            + (mods(.modmask) as $m | if $m=="" then "" else $m + " + " end)
            + (if .key != "" then .key else "code:" + (.keycode|tostring) end) ) as $combo
        | ( .description // "" ) as $desc
        | ( .dispatcher + (if (.arg // "") != "" then " " + .arg else "" end) ) as $action
        | $combo + "\t" + $desc + "\t" + $action
      '';
    in
    pkgs.writeShellApplication {
      name = "hypr-cheatsheet";
      runtimeInputs = with pkgs; [ hyprland jq gawk rofi ];
      # Two columns: key combo │ what it does (the bind's description, falling back to the raw
      # dispatcher for any plain `bind =`). Two things make rofi render this nicely, and BOTH
      # are forced here so the sheet is self-contained rather than at the mercy of the
      # chezmoi-owned ~/.config/rofi/config.rasi:
      #   * a real MONOSPACE font — column alignment is space-padding, which only lines up in a
      #     fixed-width font (config.rasi asks for "Envy Code R", which isn't installed → rofi
      #     silently falls back to proportional Noto Sans and the columns wander).
      #   * columns:1 + no icons — config.rasi defaults to a 2-up icon grid, wrong for a text list.
      #   * OPAQUE backgrounds — the nord theme makes the window fully transparent (a desktop
      #     "screenshot" backdrop) and the list only 90% opaque, so text is hard to read over a
      #     busy desktop. We paint the window + listview solid nord0 (#2e3440) for legibility.
      # rofi's fuzzy match runs over the whole line, so typing "monitor", "scratch", … filters.
      text = ''
        hyprctl binds -j \
          | jq -r -f ${filter} \
          | sort \
          | awk -F'\t' '{ printf "%-26s  %s\n", $1, ($2 != "" ? $2 : $3) }' \
          | rofi -dmenu -i -no-custom -p "keybinds" \
              -font "JetBrainsMono Nerd Font Mono 11" \
              -theme-str 'window { width: 50%; height: 75%; background-color: #2e3440; } listview { columns: 1; lines: 28; background-color: #2e3440; } element-icon { enabled: false; } element { padding: 2px 8px; }'
      '';
    };
in
{
  imports = [
    ./chromium-cm-fix.nix                            # HDR brightness fix for Chromium/Electron (overlay)
    inputs.dms.nixosModules.dank-material-shell      # DankMaterialShell (Quickshell shell) — config below
    inputs.dms-plugin-registry.nixosModules.default  # exposes programs.dank-material-shell.plugins.<id>
  ];

  programs.hyprland.enable = true; # compositor + xdg-desktop-portal-hyprland

  # ── DankMaterialShell (DMS) — Quickshell-based Wayland shell (bar + dock + notifications +
  # launcher). Available alongside Waybar on both Hyprland hosts.
  #   systemd.enable = false ON PURPOSE: DMS is autostarted via `exec-once = dms run` in
  #   modules/desktop-apps.nix, because graphical-session.target is inactive in this session
  #   so the systemd user unit wouldn't fire (same reason Waybar uses exec-once). Don't set true.
  # The module bundles its own pinned quickshell, compiled from source → expect a long FIRST build.
  programs.dank-material-shell = {
    enable = true;
    systemd.enable = false;
    # Hyprland submap indicator — the Waybar `hyprland/submap` replacement. Plugin source +
    # hash come from the registry module (imported above); `enable` installs it. You still
    # place the widget on the bar once in DMS's own settings (control center → DankBar).
    plugins.hyprlandSubmapIndicator.enable = true;
    # Animated wallpapers (sgtaziz/dms-wallpaperengine) — replaces the old
    # linux-wallpaperengine exec-once. The plugin drives the binary (a package dep, kept in
    # modules/desktop-apps.nix) and persists the chosen output + Steam Workshop scene in DMS
    # settings. Pinned here so it survives a fresh checkout rather than living in DMS state.
    plugins.linuxWallpaperEngine.enable = true;
    # Network speed bar widget — the registry's `networkIndicator`, but sourced from our
    # fork's `reliability-hardening` branch (flake input, see flake.nix). mkForce because
    # the registry module also sets `src` (upstream gemb0-0) at normal priority.
    # ⚠️ On a machine that dev-symlinked ~/.config/DankMaterialShell/plugins/networkIndicator
    # to a local clone, remove that symlink after switching — the config-dir copy and this
    # /etc/xdg/quickshell/dms-plugins one are both discovered (duplicate plugin id).
    plugins.networkIndicator = {
      enable = true;
      src = lib.mkForce inputs.network-indicator;
    };
  };

  # Drop Qt's compiled-QML cache on every switch, or DMS plugin updates silently no-op.
  # Qt validates a cached compilation unit by (source path, mtime) — never by content. Nix
  # pins every store file's mtime to epoch 1, and DMS loads plugins through the STABLE
  # /etc/xdg/quickshell/dms-plugins/<id>/ symlink, so bumping a plugin changes NEITHER the
  # cache key nor the timestamp: Qt keeps running the OLD compiled QML forever. DMS itself is
  # immune — `quickshell -p` points at a hashed store path, so its key moves with its content.
  # Only /etc/xdg-installed plugins (the ones above) are exposed.
  # Diagnosed 2026-07-15: linuxWallpaperEngine's settings pane had been silently stuck on a
  # 3-commits-old build, then went blank when a refactor moved SceneBrowserModal.qml into ui/
  # and the stale unit's root-level type reference stopped resolving. It fails INVISIBLY:
  # DMS collapses the failed loader to height 0 and clips its own "Failed to load settings"
  # text, so nothing reaches the logs. Tell-tale is a QML error citing a line past EOF.
  # Cost: DMS recompiles its QML on the first login after a switch (cache refills once).
  # Fix upstream instead if DMS ever realpath()s plugin dirs before Qt.createComponent.
  system.activationScripts.clearQuickshellQmlCache = ''
    rm -rf /home/*/.cache/quickshell/qmlcache
  '';

  # Electron/Chromium apps default to XWayland (blurry under fractional scale). This
  # makes them use the Wayland (Ozone) backend → crisp. Hint=auto, so it falls back
  # to X11 where there's no Wayland.
  environment.sessionVariables.NIXOS_OZONE_WL = "1";

  # Login via greetd + tuigreet. Launch through `start-hyprland` (the wrapper that
  # programs.hyprland.enable installs — it exports the session env to systemd/dbus so
  # portals, screenshare, Electron, … work). Running `Hyprland` directly triggers the
  # "started without start-hyprland" warning.
  services.greetd = {
    enable = true;
    settings.default_session = {
      command = "${pkgs.tuigreet}/bin/tuigreet --time --cmd start-hyprland";
      user = "greeter";
    };
  };

  security.polkit.enable = true;

  # Wayland userland the chezmoi-managed ~/.config/hypr + waybar dotfiles expect.
  environment.systemPackages = with pkgs; [
    hypr-cheatsheet  # searchable rofi overlay of all live keybinds (let-binding above); bind in hyprland.conf
    waybar
    rofi          # launcher; wayland support is merged into rofi (rofi-wayland removed)
    wl-clipboard
    # grim, wrapped to kill screenshot latency. The Hyprland screenshot portal
    # (xdg-desktop-portal-hyprland) shells out to `grim <tmpfile>` with grim's default PNG
    # compression (zlib level 6); across this DP-1 4K + DP-2 1440p canvas that's the bulk of
    # flameshot's ~6s "time to selector". The portal's capture is an EPHEMERAL temp file
    # (/run/user/.../hypr/xdph_*) the requesting app decodes immediately and deletes, so for
    # those we force `-l 0` (no compression) → ~300ms; the uncompressed PNG lives in tmpfs for a
    # blink and also decodes faster. Every other grim call (saved screenshots, scripts) passes
    # through with normal compression. Matched on the xdph_ temp-name so it's surgical.
    (pkgs.writeShellScriptBin "grim" ''
      for arg in "$@"; do
        case "$arg" in
          *xdph_*) exec ${pkgs.grim}/bin/grim -l 0 "$@" ;;
        esac
      done
      exec ${pkgs.grim}/bin/grim "$@"
    '')
    slurp
    imagemagick   # general CLI image tooling (was the wedged-HDR-grab detector for the retired screenshot-hdr.sh)
    swappy
    satty         # ShareX-style annotation editor; pipe `grim -g "$(slurp)" - | satty -f -`
    grimblast     # screenshot helper (clipboard + file)
    flameshot     # primary screenshot GUI; bound to PrintScreen (`flameshot gui`) in chezmoi hyprland.conf,
                  # tray daemon autostarted in desktop-apps.nix. Wayland grabs go via the grim portal above.
    wf-recorder   # screen recording (GIF/mp4) — the piece grim/satty don't cover
    hyprlock
    hypridle
    brightnessctl
    playerctl
    pavucontrol
    hyprsome     # per-monitor workspaces (IPC binary); chezmoi binds call `hyprsome workspace|move N`
    pyprland     # pypr daemon — scratchpads = Wayland tdrop (quake terminal); config in chezmoi pyprland.toml
    inputs.hyprswitch.packages.${pkgs.stdenv.hostPlatform.system}.default # GUI Alt+Tab switcher (flake input; not in nixpkgs)
  ];

  xdg.portal = {
    enable = true;
    extraPortals = [ pkgs.xdg-desktop-portal-gtk ]; # file pickers, etc.
  };
}
