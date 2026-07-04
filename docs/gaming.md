# Gaming tuning

Latency / frame-pacing optimizations for the graphical hosts, and the reasoning behind
them. Researched against current (2026) Linux-gaming guidance — sources at the bottom.
What's **already in the flake** lives in `modules/gaming.nix`, `modules/nvidia.nix`, and
`hosts/desktop` (CachyOS kernel); this doc focuses on the *why* plus the tweaks that are
opt-in or live outside this repo (chezmoi / Steam launch options).

## Already enabled (baseline)

| Setting | Where | Effect |
|---------|-------|--------|
| `proton-ge-bin` via Steam | `gaming.nix` | Better Windows-game compat than stock Proton. |
| `gamescope` (`capSysNice`) | `gaming.nix` | Valve micro-compositor — clean frame pacing, VRR, scaling. |
| `gamemode` | `gaming.nix` | Per-game governor/priority/GPU boost (but see the note below). |
| 32-bit GL/Vulkan | `gaming.nix` | Required by many games. |
| `scx_bpfland` (sched_ext) | `gaming.nix` | Gaming scheduler — better interactivity vs EEVDF. |
| `split_lock_mitigate=0`, `vm.swappiness=100` | `gaming.nix` | Stop split-lock throttling; prefer fast zram swap over evicting page cache. |
| CachyOS kernel | `hosts/desktop` | LTO/AutoFDO + built-in sched_ext, gaming-tuned defaults. |
| NVIDIA shader cache (12 GB) | `nvidia.nix` | Persist compiled shaders → fewer first-run stutters. |
| `NIXOS_OZONE_WL` | `hyprland.nix` | Crisp Electron/Chromium under fractional scale. |

## Newly added (high-confidence, low-risk)

Both are in `modules/gaming.nix`:

- **`vm.max_map_count = 2147483642`** — the 65530 default crashes or stutters modern games
  that mmap heavily (UE5 titles, DXVK/Proton). Valve ships `INT_MAX-5` on the Steam Deck;
  Arch (1048576) and Fedora raised theirs too. This is the single highest-impact, lowest-risk
  gaming sysctl.
- **`zramSwap` (zstd, 50% RAM)** + **`vm.swappiness=100`** — compressed in-RAM swap, with
  swappiness raised so the kernel actually prefers it (offload cold pages to fast zram instead
  of evicting page cache). Avoids the disk-IO latency spike that ruins frame pacing under
  memory pressure. The two must move together — low swappiness would leave zram underused.

## ⚠ gamemode + scx overlap

`gaming.nix` enables **both** `programs.gamemode` and `services.scx`. They overlap: scx
already pins cpufreq to performance, which is gamemode's main job, and gamemode's renice can
nudge against the scheduler. They coexist fine (gamemode still does GPU perf level, screensaver
inhibit, ioprio), but if you want it clean, either:
- keep gamemode only for its non-CPU bits, or
- drop `programs.gamemode.enable` and rely on scx (duck does exactly this).

Verify what's actually active with `gamemoded -s` while a game runs.

## Worth A/B testing

- **`scx_lavd` instead of `scx_bpfland`** (desktop). LAVD (Latency-criticality Aware Virtual
  Deadline) was built *specifically* for gaming — it tends to win on 1% lows / frame-time
  consistency, where bpfland targets general interactivity + throughput. Try it:
  ```nix
  services.scx.scheduler = "scx_lavd";
  ```
  A/B live without rebuilding: `sudo systemctl stop scx` (→ EEVDF), `start scx`. Keep whichever
  feels smoother on your titles.
- **ntsync** (Proton). The mainline `ntsync` driver (kernel 6.14+) replaces esync/fsync and
  markedly improves heavily-threaded games. Confirm `/dev/ntsync` exists (`ls -l /dev/ntsync`);
  a recent kernel + Proton-GE/Proton 10 use it automatically. Force with `PROTON_USE_NTSYNC=1`
  in a game's launch options if needed.

## Opt-in with trade-offs

- **`mitigations=off`** (kernel param) — measurable FPS/latency gains, but disables CPU
  speculative-execution mitigations. This box already runs passwordless sudo + no firewall
  (personal-machine posture), so it's defensible here, but it *is* a real security trade-off.
  ```nix
  boot.kernelParams = [ "mitigations=off" ];   # hosts/<name>, per-host opt-in
  ```
- **Transparent Hugepages** — CachyOS already tunes THP to `madvise`; forcing `always` can
  *cause* allocation-stall stutter via khugepaged on some titles. Leave it to the kernel
  default unless you're benchmarking a specific game.

## Outside this repo (chezmoi / Steam)

These aren't flake-owned — they live in your chezmoi Hyprland config or Steam launch options:

- **VRR / G-Sync (Hyprland)** — `misc:vrr = 1` (or `2`/fullscreen-only) in `hyprland.conf`.
  On NVIDIA Wayland multi-monitor, VRR can be finicky (only engages reliably with one active
  output) — running the game through **gamescope** is the robust path for VRR + frame pacing.
- **Tearing for competitive titles** — `general:allow_tearing = 1` in `hyprland.conf` plus a
  per-window `windowrulev2 = immediate, class:^(game)$`, and `mangohud gamemoderun %command%`
  / `gamescope -f -- %command%` in Steam.
- **Per-game launch options** — `gamemoderun mangohud %command%`; `gamescope --hdr-enabled -f --`
  for HDR on the QD-OLED; `RADV_PERFTEST=...` (AMD) / DLSS env (NVIDIA) as needed.

## Sources

- [Arch Linux news — increasing default vm.max_map_count](https://archlinux.org/news/increasing-the-default-vmmax_map_count-value/)
- [LKML — increase default vm_max_map_count for modern games](https://lkml.iu.edu/hypermail/linux/kernel/2403.2/04356.html)
- [Phoronix — split-lock detector hurting Steam Play games](https://www.phoronix.com/news/Linux-Splitlock-Hurts-Gaming)
- [CachyOS sched-ext tutorial](https://wiki.cachyos.org/configuration/sched-ext/)
- [scx_lavd (sched-ext docs)](https://sched-ext.com/docs/scheds/rust/scx_lavd) · [scx_lavd README](https://github.com/sched-ext/scx/blob/main/scheds/rust/scx_lavd/README.md)
- [NixOS Wiki — GameMode](https://wiki.nixos.org/wiki/GameMode)
- [NixOS Discourse — zram/zswap tuning](https://discourse.nixos.org/t/configuring-zram-and-zswap-parameters-for-optimal-performance/47852)
- [ArchWiki — Variable refresh rate](https://wiki.archlinux.org/title/Variable_refresh_rate) · [ArchWiki — Gaming](https://wiki.archlinux.org/title/Gaming)
- [Linux Gaming wiki — Improving performance](https://linux-gaming.kwindu.eu/index.php?title=Improving_performance)
