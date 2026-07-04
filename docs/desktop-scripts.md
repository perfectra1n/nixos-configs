# Custom desktop scripts

The hand-rolled tools baked into the graphical hosts (desktop + laptop) as `let`-bindings — none
of these is a nixpkgs package. Each exists to solve one specific, non-obvious problem; this doc
records what and why. The full source + local rationale live as comments next to each binding.

| Tool | Defined in | What it is |
|------|-----------|------------|
| `dms-idle-inhibit-watchdog` | [`modules/desktop-apps.nix`](../modules/desktop-apps.nix) | Idle-policy daemon — releases leaked ScreenSaver inhibits. **Own doc: [idle-watchdog.md](idle-watchdog.md)** |
| `blurcam` | [`modules/desktop-apps.nix`](../modules/desktop-apps.nix) | Manual toggle for the OBS blurred virtual webcam |
| `hypr-cheatsheet` | [`modules/hyprland.nix`](../modules/hyprland.nix) | Searchable rofi overlay of every live Hyprland keybind |
| `grim` (shim) | [`modules/hyprland.nix`](../modules/hyprland.nix) | Surgical wrapper that kills screenshot-portal latency |

## blurcam — the OBS blurred webcam, deliberately manual

**What it does.** Toggle: run it before a call → OBS cold-starts to the tray on the scene named
exactly **"Blurred Cam"** with the virtual camera (`/dev/video10`) already producing the blurred
feed. Run it again (or quit OBS) → stops and releases the webcam + GPU. Also a launcher entry
("Blurred Webcam", findable by *blur/webcam/camera*).

**Why it's manual, not a daemon.** The obvious design — a daemon that starts OBS when an app
grabs the camera — structurally loses a race: OBS cold-starts in ~4s, and a **producerless
v4l2loopback advertises no format at all** (`G_FMT` fails), so the calling app opens a formatless
device and errors out before OBS ever produces a frame. Keeping a format alive without a producer
needs `keep_format`, which v4l2loopback only exposes through the `v4l2loopback-ctl` ioctl utility
(not shipped by the kernel-module package). Launching OBS *by hand before the call* sidesteps the
whole problem; a fast-producer tool (linux-blurcam) is the only clean zero-idle+instant
alternative.

**The supporting cast** (same module — blurcam is just the visible tip):

- `v4l2loopback` pinned to `/dev/video10` with `exclusive_caps=1` — Chromium/Teams/Zoom ignore a
  loopback node advertising both output+capture caps, so this forces capture-only.
- WirePlumber's **libcamera monitor disabled** — a UVC cam enumerated twice (v4l2 MJPEG vs
  libcamera raw-only ≈5fps) made captures a coin-flip.
- The C922's **PipeWire v4l2 node disabled** — PipeWire only passes YUY2 through (raw 1080p
  saturates USB2 → ~5fps ceiling), so OBS opens `/dev/video0` directly for MJPG 1080p30; apps only
  ever consume the blurred `/dev/video10`.

**One-time setup** (app-owned OBS config, chezmoi-snapshotted): a scene named exactly
`Blurred Cam` whose source is a Video Capture Device (V4L2) @ MJPEG 1080p30 with a Background
Removal filter. `--scene` forces it active on every launch, so other scenes (streaming,
recording) coexist freely.

## hypr-cheatsheet — live keybind overlay

**What it does.** A rofi dmenu listing *every active keybind* with a human description; fuzzy-type
to filter. Bound in the chezmoi `hyprland.conf` (e.g. `SUPER + /`).

**Why it never drifts.** The data comes **live from `hyprctl binds -j`** at invocation — not from
parsing the config file — so it reflects exactly what the compositor has loaded, including submaps.
It relies on the chezmoi binds using the `bindd =` variant (which carries a `.description`);
plain `bind =` rows degrade gracefully to showing the raw dispatcher.

**Implementation notes** (the non-obvious bits):

- A jq filter decodes Hyprland's modmask bitmask (SHIFT=1, CTRL=4, ALT=8, SUPER=64) into readable
  combos and drops the noise `submap → reset` rows.
- rofi's look is **forced inline** (`-font`, `-theme-str`) rather than trusting
  `~/.config/rofi/config.rasi`: the column alignment is space-padding (needs a real monospace
  font — config.rasi names one that isn't installed), and the nord theme's transparent window
  made text unreadable over a busy desktop. Self-contained beats theme-dependent here.

## grim shim — 6s → 300ms screenshot selector

**The problem.** The Hyprland screenshot portal (`xdg-desktop-portal-hyprland`) shells out to
`grim <tmpfile>` with grim's default PNG compression (zlib level 6). Across the desktop's
4K + 1440p canvas, that compression was the bulk of flameshot's ~6-second "time to selector".

**The fix.** A `writeShellScriptBin "grim"` wrapper that shadows the real grim in PATH and matches
the portal's temp-file name (`/run/user/…/hypr/xdph_*`): those calls get `-l 0` (no compression →
~300ms; the file is ephemeral tmpfs the app decodes and deletes immediately, and uncompressed PNG
also *decodes* faster). Every other grim call — saved screenshots, scripts — passes through with
normal compression. Matching on `xdph_` keeps it surgical.

**HDR context.** Screenshots on the HDR output used to wedge (black/stale grabs); that was fixed
compositor-side with `render:keep_unmodified_copy = 0` in the chezmoi `hyprland.conf` (`=2`
freezes the HDR monitor, `=1` forces an FP16 copy everywhere). The old `screenshot-hdr.sh`
SDR-flip wrapper is retired — `dotfiles/.chezmoiremove` actively deletes it from every machine —
and **flameshot is the sole screenshot tool** (PrintScreen → `flameshot gui`, grabs via the
wrapped grim portal above).

## Conventions these follow

- **`writeShellApplication` over `writeShellScriptBin`** wherever possible: it runs shellcheck at
  build time and pins `runtimeInputs` on PATH, so the script can't silently depend on host state.
  (The grim shim uses `writeShellScriptBin` because it must be a transparent argv-preserving
  `exec` wrapper.)
- **`let`-binding in the owning module, installed via `home.packages`/`systemPackages`** — no
  separate `scripts/` dir for deployed tools, so the source, rationale comment, and installation
  live in one place. (Repo-side helper scripts like `scripts/host.sh` are a different category:
  they run from the checkout, not from PATH.)
- **Session daemons autostart via `exec-once`** in the flake-owned `hypr/autostart.conf` fragment,
  not systemd user units — `graphical-session.target` is inactive under this session (see
  [idle-watchdog.md](idle-watchdog.md#why-exec-once-and-not-a-systemd-user-unit)).
