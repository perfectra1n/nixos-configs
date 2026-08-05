{ config, pkgs, lib, username, ... }:

# GUI apps for the bare-metal desktops (desktop, laptop). Imported by both in flake.nix.
let
  # OBS's own bin/obs wrapper puts its libs + libglvnd on LD_LIBRARY_PATH but NOT
  # /run/opengl-driver/lib — so the obs-nvenc-test helper OBS spawns can't dlopen
  # libnvidia-encode.so.1, NVENC fails ("reason=nvenc_lib"), and the encoder list collapses
  # to x264 (CPU only). Prepend the driver lib dir; the test child inherits this env and
  # then finds the NVIDIA encode lib. addDriverRunpath.driverLink = /run/opengl-driver.
  # (The obs-backgroundremoval plugin + CUDA onnxruntime override that used to be wrapped in
  # here are retired — the blurred webcam is cleanroom now: modules/cleanroom.nix, BOTH graphical
  # hosts. OBS stays for screen recording/streaming and its own virtual camera.)
  obs-studio-nvenc = pkgs.symlinkJoin {
    name = "obs-studio-nvenc";
    paths = [ pkgs.obs-studio ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram $out/bin/obs \
        --prefix LD_LIBRARY_PATH : ${pkgs.addDriverRunpath.driverLink}/lib
    '';
  };

  # dms-idle-inhibit-watchdog — a small idle POLICY daemon (run by the dms-idle-watchdog user
  # service below). It lets the monitors DPMS-off when genuinely idle, while keeping them awake
  # whenever something real is happening. DMS honors every org.freedesktop.ScreenSaver inhibit
  # (mirroring it into a compositor-level Wayland idle-inhibitor that blocks DPMS for everything),
  # but several apps LEAK that inhibit — holding it when nothing needs the screen on (Steam's
  # gldriverquery after a game, teams-for-linux after a call, browser wake-locks…). A leaked
  # inhibit is byte-for-byte indistinguishable from a legit one, so rather than chase every
  # misbehaving app (unbounded), we watch the small, stable set of POSITIVE "stay awake" signals:
  # a game running (reaper/gamemode), media playing (MPRIS — so a *muted* video still counts and
  # a *paused* one doesn't), audio output, or mic capture (a call). When DMS reports an EXTERNAL
  # inhibit held while NONE of those is true — sustained across NEED checks to bridge brief gaps
  # (a track change, an MPRIS blip) — we remove the leaked cookies from the ScreenSaver daemon
  # itself (sweep_inhibitors below; NOT `dms ipc inhibit disable`, which only cleared DMS's mirror
  # bit and left the daemon's "inhibited" flag pinned true, silently ignoring every LATER legit
  # inhibit and leaving a stale "External app" reason that put a later manual hold at risk).
  # A deliberate manual coffee-cup hold (reason "Keep system awake") is NEVER touched. Fail-safe
  # is fail-CLOSED: if `dms` is down, the reason is unexpected, or any probe can't answer, it
  # does nothing. `dms` resolves from the user manager's PATH (verified to carry the session
  # PATH incl. /run/current-system/sw/bin, where the DMS module installs it).
  dms-idle-inhibit-watchdog = pkgs.writeShellApplication {
    name = "dms-idle-inhibit-watchdog";
    runtimeInputs = with pkgs; [ coreutils procps gamemode playerctl pulseaudio gnugrep gawk systemd ];
    text = ''
      POLL=30   # seconds between checks
      NEED=2    # consecutive "stuck" checks before releasing (~POLL*NEED grace)

      # Streams whose activity never counts, in EITHER direction (regex, matched against the
      # whole per-stream pactl record so app name / binary / media title all hit).
      # linux-wallpaperengine (the DMS wallpaper plugin) holds its PipeWire output streams open
      # and UNCORKED 24/7 even for silent wallpapers — a flat "any 'Corked: no'" check would be
      # always-true and hold every leak forever. Applied to sink-inputs AND source-outputs so a
      # future always-uncorked capture stream can't pin the mic signal the same way.
      EXCLUDE_STREAMS='linux-wallpaperengine'

      log(){ printf '%s\n' "$*"; }

      # glib-based tools (playerctl, gamemode's client) need DBUS_SESSION_BUS_ADDRESS set
      # explicitly — glib has no /run/user/$UID/bus fallback the way libdbus does. The user
      # manager's activation environment normally provides it; belt-and-braces for odd
      # activation orders (unit started before the session env import).
      if [ -z "''${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus"
        export DBUS_SESSION_BUS_ADDRESS
      fi

      # Every DMS IPC call goes through here: a wedged quickshell must surface as a FAILED
      # probe (fail-safe: leave the inhibit alone), never as the watchdog hung forever on a
      # blocking socket call — a hang is the one failure mode Restart= can't fix.
      dms_ipc(){ timeout 10 dms ipc "$@"; }

      # --- positive "keep the screen awake" probes ------------------------------------------
      # Three-state: each prints y / n / u (unknown) and always returns 0, so a bare $(probe)
      # capture is safe under `set -e`. The u state is the point: a probe that can't answer
      # must never read as "not active" — the old boolean probes turned every tool failure
      # into a vote for release, exactly the wrong bias.

      game_active(){
        if pgrep -f 'reaper SteamLaunch' >/dev/null 2>&1; then echo y; return; fi
        if gamemoded -s 2>/dev/null | grep -q 'is active'; then echo y; return; fi
        echo n   # pgrep rc1 = no match, gamemoded down = no gamemode session: both genuinely "no"
      }

      media_playing(){
        # Capture FIRST, inspect after: `playerctl | grep` under pipefail loses a real
        # "Playing" when playerctl exits nonzero AFTER printing valid statuses (one
        # misbehaving MPRIS player poisons the walk).
        local out rc
        rc=0
        out="$(playerctl -a status 2>/dev/null)" || rc=$?
        if printf '%s\n' "$out" | grep -qx 'Playing'; then echo y; return; fi
        # rc!=0 with NO output is the normal "No players found" — a real "no". rc!=0 WITH
        # output but no Playing: partial listing — we did not see every player, so we don't
        # KNOW nothing is playing.
        if [ "$rc" -ne 0 ] && [ -n "$out" ]; then echo u; return; fi
        echo n
      }

      # Shared per-stream check for both directions. pactl exits nonzero only when the audio
      # server is unreachable (zero streams => rc 0, empty output), so rc!=0 means "can't know".
      pa_streams(){ # $1: pactl object kind, $2: per-stream record separator
        local out
        if ! out="$(pactl list "$1" 2>/dev/null)"; then echo u; return; fi
        if printf '%s\n' "$out" | awk -v RS="$2" -v ex="$EXCLUDE_STREAMS" \
             '/Corked: no/ && $0 !~ ex { found=1 } END { exit !found }'; then
          echo y
        else
          echo n
        fi
      }
      audio_out(){ pa_streams sink-inputs 'Sink Input #'; }
      mic_in(){ pa_streams source-outputs 'Source Output #'; }

      # --- release mechanism ----------------------------------------------------------------
      # Remove the leaked cookies from the danklinux ScreenSaver daemon itself, via its PUBLIC
      # D-Bus API. Cookies are sequential (screensaver.go: atomic.AddUint32) and UnInhibit is
      # not sender-validated, so: take a probe Inhibit (returns the NEWEST cookie = ceiling),
      # then UnInhibit everything at/below it — the probe plus every pre-existing cookie, all
      # of which this loop just judged leaked (same policy the old mirror-disable applied, at
      # the root). Race-free: an inhibit taken after the probe gets a HIGHER cookie, so the
      # sweep can never touch it. Emptying the set makes the daemon's "inhibited" bool EDGE,
      # and DMS resets idleInhibited + the reason natively (IdleService.qml only reacts to
      # edges — why mirror-clearing pinned it). The probe reason must never contain "audio":
      # the daemon drops audio-only inhibits (returns cookie 0, not registered).
      # If some OTHER daemon owned the bus name this would sweep a stranger — unreachable in
      # practice: DMS would then see no external inhibitors and we'd never get here.
      SS=org.freedesktop.ScreenSaver
      sweep_inhibitors(){
        local out ceiling c
        out="$(busctl --user --timeout=10 call "$SS" /org/freedesktop/ScreenSaver "$SS" \
                 Inhibit ss dms-idle-watchdog 'leak sweep ceiling probe' 2>/dev/null)" || return 1
        ceiling="''${out#u }"                                    # busctl replies "u <n>"
        case "$ceiling" in ""|*[!0-9]*) return 1 ;; esac
        [ "$ceiling" -gt 0 ] || return 1                         # 0 = probe was dropped
        [ "$ceiling" -le 5000 ] || return 1                      # absurd ceiling: not the daemon we know
        c=1
        while [ "$c" -le "$ceiling" ]; do
          busctl --user --timeout=10 call "$SS" /org/freedesktop/ScreenSaver "$SS" \
            UnInhibit u "$c" >/dev/null 2>&1 || true
          c=$((c + 1))
        done
      }

      # DMS's IPC socket isn't up the instant the session starts — wait for it. Also keeps the
      # unit inert (quiet 5s loop) on a TTY/SSH login where no Hyprland session ever appears.
      until dms_ipc inhibit status >/dev/null 2>&1; do sleep 5; done
      log "started (poll ''${POLL}s, release after ''${NEED} stuck checks)"

      stuck=0
      last=$(date +%s)
      while true; do
        sleep "$POLL"

        # Suspend/clock-jump guard: `sleep` runs on monotonic time, so across a suspend the
        # wall clock advances far more than POLL between iterations. Pre-suspend "stuck"
        # counts are stale — the world changed while we weren't looking — and must not
        # contribute to a release decision made after resume.
        now=$(date +%s)
        if [ $((now - last)) -gt $((POLL * 2)) ]; then
          if [ "$stuck" -gt 0 ]; then
            log "wall clock jumped $((now - last))s (suspend/resume?) — resetting stuck counter"
          fi
          stuck=0
        fi
        last=$now

        # When DMS reports NO inhibit, idle/DPMS is working — stay silent (don't spam the journal).
        # We only ever log once an inhibit is ENABLED: that's the exact window where the screen
        # refuses to sleep, so we narrate every poll there with a full signal breakdown. Corollary
        # worth knowing when debugging: if the screen is stuck ON but this log is SILENT, the inhibit
        # is invisible to DMS (e.g. a Chromium/Electron compositor-level Wayland idle-inhibitor on its
        # own surface) — no ScreenSaver cookie exists to sweep, so it needs a different fix.
        #   The match is the exact upstream substring (DMSShellIPC.qml status(): precisely
        # "Idle inhibit is enabled" / "Idle inhibit is disabled"); an empty/garbled reply (dms
        # down, timeout) falls to the default arm = do nothing. The old looser *enabled* glob
        # happened not to match "disabled" — this is hardening, not a bug fix.
        status="$(dms_ipc inhibit status 2>/dev/null || true)"
        case "$status" in
          *"is enabled"*) ;;
          *) stuck=0; continue ;;
        esac

        # Evaluate every keep-awake probe exactly once so the logged breakdown matches the decision.
        g=$(game_active); m=$(media_playing); a=$(audio_out); i=$(mic_in)
        signals="game=$g media=$m audio=$a mic=$i"

        # Only ever clear an EXTERNAL-app inhibit, never a deliberate manual (coffee-cup) hold.
        # `reason ""` is a pure getter (DMSShellIPC.qml: empty arg returns the reason; a
        # NON-empty arg SETS it — never change that argument). The reason carries the leaking
        # app's name(s) ("External app: " + names, IdleService.qml), so it goes into every log
        # line from here: the journal answers WHO leaked, not just "someone".
        reason="$(dms_ipc inhibit reason "" 2>/dev/null || true)"
        reason="''${reason#Current reason: }"
        case "$reason" in
          "External app"*) ;;
          *) log "inhibit ENABLED but reason is not an external app ($reason) — leaving it. [$signals]"
             stuck=0; continue ;;
        esac

        # Any POSITIVE activity => hold, regardless of what the other probes said.
        case "$signals" in
          *=y*)
            log "inhibit ENABLED + external ($reason), but a keep-awake signal is active — holding. [$signals]"
            stuck=0; continue ;;
        esac
        # No positive signal, but a probe couldn't answer => we lack positive knowledge that
        # nothing is happening. Fail-closed: only release on CERTAINTY of silence.
        case "$signals" in
          *=u*)
            log "WARNING: a probe failed — holding ($reason) until every signal is readable. [$signals]"
            stuck=0; continue ;;
        esac

        stuck=$((stuck + 1))
        log "inhibit ENABLED + external ($reason) + nothing playing — stuck $stuck/$NEED. [$signals]"
        if [ "$stuck" -ge "$NEED" ]; then
          if sweep_inhibitors; then
            sleep 2   # daemon -> shell socket push latency before re-reading the mirror
            post="$(dms_ipc inhibit status 2>/dev/null || true)"
            case "$post" in
              *"is disabled"*)
                log "released leaked inhibit(s) at the source (was: $reason)" ;;
              *"is enabled"*)
                # Either a new inhibit landed mid-sweep (possibly legit — its cookie was above
                # the ceiling, correctly untouched) or an app instantly re-took one (wake-lock
                # cycling). Both re-enter the normal loop: signals decide next poll.
                log "sweep ran but an inhibit is still held — re-taken or new mid-sweep (was: $reason); re-evaluating next poll" ;;
              *)
                log "sweep ran but the post-release status check failed (was: $reason)" ;;
            esac
          else
            # busctl unavailable / probe dropped / garbled reply — fall back to the old
            # mirror-bit clear so a leak never survives on a degraded system. The explicit
            # reason reset guards the fallback's stale-reason trap: DMS's disable path never
            # touches inhibitReason, so without this a LATER manual coffee-cup hold would
            # surface as "External app: …" and get wrongly released.
            log "cookie sweep failed — falling back to clearing DMS's mirror bit (was: $reason)"
            dms_ipc inhibit disable >/dev/null 2>&1 || true
            dms_ipc inhibit reason "Keep system awake" >/dev/null 2>&1 || true
          fi
          stuck=0
        fi
      done
    '';
  };

in
{
  # Logitech wireless, QMK/VIA keyboard, and gaming-mouse/RGB device support moved to
  # modules/peripherals.nix (single home for physical-peripheral management).

  # GVfs is the backend Nautilus (our $fileManager) leans on for the things that look
  # broken without it: the Trash, "Other Locations", and mounting network/MTP/removable
  # volumes. Not pulled in automatically since we're not running full GNOME.
  services.gvfs.enable = true;

  # KDE Connect — phone↔desktop pairing (notifications, clipboard, file transfer, media
  # control). The NixOS module rather than a bare package because pairing needs firewall
  # ports 1714-1764 TCP+UDP open, which the module does; a plain home.packages entry
  # would install a client that can never discover the phone. Works fine outside Plasma
  # (it's Qt, not plasmashell-bound). The kdeconnectd daemon itself is exec-once'd in
  # autostart.conf below — Hyprland runs no XDG autostart, and D-Bus activation alone
  # would leave the daemon (and thus discovery) dormant until something first talked to it.
  programs.kdeconnect.enable = true;

  # NO camera WirePlumber rules here any more — modules/cleanroom.nix owns them now, and the two
  # that used to live here ("10-disable-libcamera" and "11-c922-obs-only") would be exact duplicates
  # of what its module emits ("50-cleanroom-disable-libcamera", "51-cleanroom-camera"). Keeping both
  # is not a build conflict — the keys differ, so they merge into separate WirePlumber files — but
  # it would leave two copies of the same decision drifting apart, and the ORIGINAL RATIONALE HERE
  # IS NOW FALSE: it read "hand the C922 to OBS alone … Teams/Zoom consume the blurred OBS virtual
  # cam at /dev/video10". Cleanroom is the camera owner now and there is no pinned /dev/video10.
  #
  # The underlying findings still hold and are preserved in cleanroom's own module, because they are
  # WHY it opens the device directly rather than reading through PipeWire:
  #   • libcamera double-enumerates a UVC cam and exposes only RAW/YUYV (1080p ≈ 5 fps over USB2),
  #     so which node a consumer binds was a coin-flip; it also holds the device fd open.
  #   • PipeWire's v4l2 source node advertises YUY2 ONLY and never passes the cam's MJPG modes
  #     through, so capture *via* PipeWire is structurally pinned to ~5 fps at 1080p. No knob fixes it.
  #   • Match on node.nick, NOT media.class: WirePlumber's v4l2 create-node hook evaluates rules
  #     against props that exist at creation time, and media.class is not among them — a media.class
  #     match silently never fires. (That was the first cut's bug here, and cleanroom repeats the
  #     warning in its own option docs so it cannot be relearned a third time.)
  #
  # OBS keeps its own "Start Virtual Camera": cleanroom provisions 2 loopback nodes and selects a
  # free one at runtime, so the two producers no longer take turns on a single pinned node.

  # Chrome-channel tools (the @playwright/mcp Claude Code plugin defaults to the `chrome`
  # channel) hardcode Chrome's FHS path /opt/google/chrome/chrome, which doesn't exist on
  # NixOS. Symlink it to the nix Chrome so that path resolves — a declarative replacement
  # for a manual `ln -s` (the `L+` recreates it, overwriting any hand-made symlink).
  systemd.tmpfiles.rules = [
    "d /opt/google 0755 root root - -"
    "d /opt/google/chrome 0755 root root - -"
    "L+ /opt/google/chrome/chrome - - - - /etc/profiles/per-user/${username}/bin/google-chrome-stable"
  ];

  # All home-manager settings for the user live under ONE binding: ${username} is a dynamic
  # (computed) attribute, and Nix refuses to merge a dynamic key across several separate
  # `home-manager.users.${username}.* = …` bindings in the same module (it errors with
  # "dynamic attribute already defined"). Nesting everything here keeps the key written once.
  home-manager.users.${username} = {
    home.packages = with pkgs; [
      slack
      discord
      vesktop             # modern-Electron Discord client — native Wayland fractional scaling
                          # (crisp text at fractional scale) + screenshare-with-audio. Trying
                          # alongside official `discord`; drop one once a winner is picked.
      signal-desktop      # Signal messenger
      element-desktop     # Matrix client (Element)
      telegram-desktop    # Telegram messenger (official Qt desktop client)
      ticktick            # TickTick to-do / task manager
      spotify
      # Nextcloud desktop sync client removed — replaced by the rclone WebDAV files-on-demand
      # mount in modules/rclone-mounts.nix (/mnt/FullerNextcloud). See docs/host-matrix.md.
      owncloud-client     # ownCloud desktop sync client
      obs-studio-nvenc    # screen recording / streaming (PipeWire screencast on Wayland).
                          # Wrapped to add /run/opengl-driver/lib so NVENC works (see let-binding).
      vlc                 # media player
      plex-desktop        # Plex desktop player/client (streams from a Plex Media Server; NOT the server)
      imv                 # Wayland-native image viewer (lightweight, GPU-accelerated)
      linux-wallpaperengine  # binary dep of the DMS `linuxWallpaperEngine` plugin (modules/hyprland.nix);
                             # the plugin launches/manages it — no exec-once here. Renders Steam WE workshop scenes.
      dms-idle-inhibit-watchdog  # releases leaked ScreenSaver inhibits so monitors can DPMS-off; runs as the
                                 # dms-idle-watchdog user service (below) — in PATH only for manual debug runs
      prismlauncher       # Minecraft launcher (maintained MultiMC fork)
      runelite            # Old School RuneScape client (open-source, plugin hub)
      hdos                # HDOS — alternative Old School RuneScape client (unfree)
      nomachine-client    # NoMachine remote-desktop client (unfree)
      rustdesk            # RustDesk remote-desktop client (FOSS, AGPL) — replaced anydesk, whose
                          #   pinned tarball 404s once AnyDesk deletes old versions from their CDN
      zoom-us             # Zoom video conferencing client (unfree)

      # WireGuard GUI — nm-connection-editor (+ nm-applet) from networkmanagerapplet.
      # The `wg`/`wg-quick` CLI is already in home/common.nix; this is the graphical
      # manager. NetworkManager (modules/desktop-base.nix) has native WireGuard support,
      # so add/import a tunnel here ("+" → WireGuard, or import a .conf via
      # `nmcli connection import type wireguard file <conf>`) and toggle it from the
      # DMS network module. No standalone WireGuard GUI (wireguird) is in nixpkgs yet.
      networkmanagerapplet

      # Playwright (browser automation / testing) + its MCP server.
      playwright          # playwright-core (the Node/Python client core)
      playwright-test     # the `playwright` CLI (test, codegen, install) — @playwright/test
      playwright-mcp      # Playwright MCP server (browser automation over MCP)
    ];

    # Point Playwright at the nix-built browsers (the ones `playwright install` downloads
    # don't run on NixOS) and skip the host-requirements check + download. The browser
    # version is pinned to match playwright / playwright-test (same nixpkgs rev), which
    # Playwright requires to launch them. Set for the user's session so CLI + MCP find them.
    home.sessionVariables = {
      PLAYWRIGHT_BROWSERS_PATH = "${pkgs.playwright-driver.browsers}";
      PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD = "1";
      PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS = "true";
    };

    # Session autostart — exec-once daemons, written by the flake and sourced by the chezmoi
    # hyprland.conf. This `hypr/autostart.conf` fragment is an allowed exception to the chezmoi
    # boundary (alongside hypr/gpu.conf — see CLAUDE.md): the flake owns it because it
    # autostarts daemons the flake itself installs. exec-once runs only at session start, NOT on
    # `hyprctl reload` — re-login after changes.
    # Historically exec-once was also the ONLY thing that worked here, because nothing activated
    # graphical-session.target so graphical-session-BOUND user services never fired (default.target
    # -bound ones did — see the watchdog unit below). The first exec-once below now activates that
    # target, so this file's entries are a convention rather than a constraint.
    # REQUIRES the chezmoi ~/.config/hypr/hyprland.conf to `source ~/.config/hypr/autostart.conf`.
    xdg.configFile."hypr/autostart.conf".text = ''
      # FIRST, before any daemon: tell systemd a graphical session exists. greetd launches
      # `start-hyprland` directly, which is a "non-systemd-aware session" — it exports the env to
      # systemd/dbus but never activates graphical-session.target, so that target sat inactive for
      # the whole session. nixos-fake-graphical-session.target is NixOS's own shim for exactly this
      # (`BindsTo=graphical-session.target`); starting it pulls the real target in. It has to be
      # started INDIRECTLY like this because graphical-session.target sets RefuseManualStart=yes.
      #
      # Latent until 2026-08-05, when xdg-desktop-portal 1.20.4 → 1.22.1 swapped its unit's
      # `Requires=dbus.service` for `Requisite=graphical-session.target`. Requisite fails outright
      # if the target is not ALREADY active, so the portal broke on the first switch that shipped
      # 1.22.1 — "Failed to start user unit xdg-desktop-portal.service" and no file pickers or
      # screenshare, in a session where the portal had happily run for hours before.
      #
      # Everything below deliberately STAYS exec-once (and dms-idle-watchdog stays bound to
      # default.target) — that is unchanged behavior, not an oversight. Migrating them onto
      # graphical-session.target is now POSSIBLE but is a separate change with its own testing.
      exec-once = systemctl --user start nixos-fake-graphical-session.target

      # NO hypridle here — DMS owns idle/lock/DPMS. DMS ships a full idle pipeline
      # (Services/IdleService.qml: monitor-off + lock + suspend timers, AC/battery-aware)
      # and explicitly replaces swayidle/hypridle. Running both = two ext-idle-notify
      # clients fighting over `dpms off`, and DMS surfaces could pause idle so hypridle
      # never fired under the lock. Set the monitor-off timeout in DMS Settings →
      # Power & Sleep (acMonitorTimeout/batteryMonitorTimeout, in seconds); DMS's
      # IdleService keeps running while its own lock is shown, so it blanks on the lock
      # screen too. lock-before-suspend + DPMS-on-wake are handled by DMS (loginctl
      # integration), so the old before/after_sleep hooks are redundant.

      # Status bar / shell — DankMaterialShell (Quickshell): bar + dock + notifications +
      # launcher. Uses exec-once (NOT DMS's systemd unit); keep
      # programs.dank-material-shell.systemd.enable = false (modules/hyprland.nix). The original
      # reason — an inactive graphical-session.target — is gone as of the first exec-once above,
      # so switching to DMS's unit is now a real option; it just hasn't been tested here yet.
      # To use Waybar instead, swap for ~/.config/waybar/launch.sh.
      exec-once = dms run

      # NO idle-inhibit watchdog exec-once here anymore — it runs as the dms-idle-watchdog
      # systemd user service (defined below in this module). A unit gets Restart=on-failure
      # supervision (a bare exec-once died permanently on the first SIGPIPE from a journald
      # hiccup) and auto-restarts on rebuild via sd-switch (exec-once needed a re-login). It
      # binds to default.target because graphical-session.target is inactive here — the same
      # fact that forces everything ELSE in this file to stay exec-once. Watch it with:
      #   journalctl --user -t dms-idle-watchdog

      # Clipboard manager daemon
      exec-once = copyq

      # pyprland daemon — dropdown terminal scratchpad (config in ~/.config/pypr/config.toml).
      # Toggle bound to Super+grave. Needs the pyprland package (modules/hyprland.nix).
      exec-once = pypr

      # hyprshell — GTK4 Alt+Tab window switcher daemon. It registers the Alt+Tab switch key
      # itself (config: chezmoi ~/.config/hyprshell/config.ron), so there are NO Hyprland binds
      # for it. Package (hyprshell) comes from the hyprswitch flake input (modules/hyprland.nix).
      exec-once = hyprshell run

      # flameshot screenshot daemon — owns the tray icon and serves `flameshot gui` (bound to
      # PrintScreen in chezmoi ~/.config/hypr/hyprland.conf) without a cold-start spawn on each
      # capture. Wayland grabs go through the xdg-desktop-portal Screenshot path. Package:
      # modules/hyprland.nix.
      exec-once = flameshot

      # ownCloud sync client, minimized to tray.
      exec-once = owncloud --background

      # KDE Connect daemon (programs.kdeconnect in this module) — must run persistently for
      # the phone to discover/stay paired with this host; D-Bus activation would only start
      # it on first use. kdeconnect-indicator (tray UI) is intentionally NOT autostarted —
      # launch it (or kdeconnect-app) on demand; the daemon alone handles sync/notifications.
      exec-once = kdeconnectd

      # NOTE: no OBS autostart, and no cleanroom exec-once either — cleanroom (modules/cleanroom.nix)
      # ships its own systemd user unit bound to graphical-session.target, plus D-Bus activation, so
      # an exec-once here would race its own single-instance guard. Unlike the old NV Broadcast setup
      # there IS a reason to have it running before a call: cleanroom is the producer, and a
      # producerless v4l2loopback advertises no format at all.

      # NOTE: no linux-wallpaperengine exec-once — the DMS `linuxWallpaperEngine` plugin
      # (modules/hyprland.nix) owns wallpaper launch + saved state (output, scene id) now.
    '';

    # The idle-inhibit watchdog as a SUPERVISED user service — the one daemon here that is NOT
    # exec-once. Why: under exec-once, `set -euo pipefail` plus a single SIGPIPE from its
    # systemd-cat/journald pipe killed it silently until re-login; a unit restarts it in 15s,
    # guarantees a single instance, and (systemd.user.startServices defaults to sd-switch)
    # restarts it on `nixos-rebuild switch` whenever the script changes — no re-login.
    # WantedBy=default.target, NOT graphical-session.target: the latter is INACTIVE under this
    # Hyprland+DMS setup. Verified safe: the user manager's activation environment carries the
    # session PATH (incl. /run/current-system/sw/bin, where `dms` lives — runtimeInputs merely
    # PREPEND to it) and DBUS_SESSION_BUS_ADDRESS, and the script waits for DMS's IPC socket
    # before acting — so an early start is inert until the session is actually up.
    systemd.user.services.dms-idle-watchdog = {
      Unit.Description = "DMS idle-inhibit watchdog — releases leaked external ScreenSaver inhibits";
      Service = {
        ExecStart = lib.getExe dms-idle-inhibit-watchdog;
        Restart = "on-failure";
        RestartSec = 15;
        # Keeps the documented `journalctl --user -t dms-idle-watchdog` working (the tag the
        # old systemd-cat wrapper provided); `-u dms-idle-watchdog` works too.
        SyslogIdentifier = "dms-idle-watchdog";
      };
      Install.WantedBy = [ "default.target" ];
    };
  };
}
