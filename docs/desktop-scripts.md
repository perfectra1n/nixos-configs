# Custom desktop scripts

The hand-rolled tools baked into the graphical hosts (desktop + laptop) as `let`-bindings — none
of these is a nixpkgs package. Each exists to solve one specific, non-obvious problem; this doc
records what and why. The full source + local rationale live as comments next to each binding.

| Tool | Defined in | What it is |
|------|-----------|------------|
| `dms-idle-inhibit-watchdog` | [`modules/desktop-apps.nix`](../modules/desktop-apps.nix) | Idle-policy daemon — releases leaked ScreenSaver inhibits. **Own doc: [idle-watchdog.md](idle-watchdog.md)** |
| `hypr-cheatsheet` | [`modules/hyprland.nix`](../modules/hyprland.nix) | Searchable rofi overlay of every live Hyprland keybind |
| `grim` (shim) | [`modules/hyprland.nix`](../modules/hyprland.nix) | Surgical wrapper that kills screenshot-portal latency |

## blurcam — RETIRED (replaced by NV Broadcast)

The OBS-based blurred-webcam toggle (`blurcam` + the obs-backgroundremoval filter + a CUDA
onnxruntime rebuild for the 5090) is gone — replaced on the desktop by **NV Broadcast**
([`modules/nvbroadcast.nix`](../modules/nvbroadcast.nix)): a purpose-built app (unofficial
NVIDIA Broadcast port) that produces the same blurred/virtual-background feed into the same
`/dev/video10` without OBS in the loop. Launch `nvbroadcast` (GUI, also a launcher entry)
before a call. The laptop keeps no blur stack at all — plain OBS + virtual camera only.

**Lore worth keeping** (still true, still the reason things are shaped this way):

- **On-demand, not a daemon.** A producerless v4l2loopback advertises no format at all
  (`G_FMT` fails), so any "auto-start the producer when an app grabs the cam" design loses the
  open() race. Start the producer *before* the call.
- `v4l2loopback` config now lives in [`modules/virtual-camera.nix`](../modules/virtual-camera.nix):
  `/dev/video10`, `exclusive_caps=1` (Chromium/Teams/Zoom ignore a loopback node advertising both
  output+capture caps), neutral `card_label="Virtual Camera"` — both NV Broadcast and OBS's
  "Start Virtual Camera" produce into it, one at a time.
- WirePlumber's **libcamera monitor disabled** (still in desktop-apps.nix) — a UVC cam enumerated
  twice (v4l2 MJPEG vs libcamera raw-only ≈5fps) made captures a coin-flip.
- The C922's **PipeWire v4l2 node disabled** — PipeWire only passes YUY2 through (raw 1080p
  saturates USB2 → ~5fps ceiling); the producer opens `/dev/video0` directly for MJPG 1080p30 and
  apps only ever consume `/dev/video10`.

The old chezmoi-snapshotted OBS "Blurred Cam" scene is app-owned config — delete it from OBS's
UI whenever.

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
