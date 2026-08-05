# Package inventory

What's installed, which file owns it, and which hosts get it. The modules are the source of
truth — this is a hand-maintained summary. "Hosts" uses: **D**=desktop, **L**=laptop,
**S**=server.

## CLI / dev — `home/common.nix` (every host: D L S)

| Group | Packages |
|-------|----------|
| Shell | `fish`, `starship`, `fzf`, `fishPlugins.fzf-fish`, `fishPlugins.z`, `tmux` |
| CLI tools | `bat`, `fd`, `ripgrep`, `jq`, `nnn`, `git`, `delta`, `lazygit`, `lazydocker`, `chezmoi`, `btop`, `ncdu`, `yq-go`, `hugo` |
| Editor (neovim + LazyVim deps) | `neovim`, `gcc`, `nodejs`, `lua-language-server`, `stylua`, `tree-sitter` |
| Dev / ops | `python3` (+pip, requests), `k9s`, `kubernetes-helm`, `kustomize`, `krew`, `cilium-cli`, `talhelper`, `sops`, `ansible`, `opentofu`, `tea`, `awscli2`, `claude-code`, `mise` |
| Databases | `postgresql` (→`psql`), `pgcli`, `sqlite-interactive` (→`sqlite3`), `litecli`, `dolt` |
| Media | `ffmpeg`, `imagemagick`, `yt-dlp` |

> `opentofu` is this repo's deliberate FOSS choice over duck's `terraform` (BSL). `mise` is
> a bare package activated by chezmoi, not `programs.mise` (chezmoi boundary).

> Databases are **clients only** — no host runs a server, so the headless server gets them too
> (handy over SSH). `sqlite-interactive`, not `sqlite`: the latter is library-only and ships no
> `bin/` at all, so it would put nothing on PATH. Don't be fooled by `sqlite-3.x` appearing in
> every `manifests/*.txt` — that's a transitive dep of other packages, not a usable CLI. The
> DBeaver GUI is graphical-only (`home/gui.nix`).

## System base — `modules/common.nix` (every host: D L S)

- Packages: `git vim curl wget bash psmisc wireguard-tools zip unzip gzip gnutar cmake file
  nvfetcher sops age ssh-to-age`, plus pinned `kubectl` + `talosctl` (via `mkBin`) and
  `kubectl-krew`.
- Programs/services: `programs.fish`, `programs.nix-ld`, `programs.ssh.enableAskPassword =
  false`, `services.openssh`, `services.envfs`, `virtualisation.docker`. Firewall disabled.
- User `${username}` in `wheel`+`docker`, fish login shell, passwordless sudo. sops wiring
  (inert until a secret is declared).

## GUI apps — `home/gui.nix` (graphical: D L)

- Packages: `kitty`, `google-chrome`, `firefox`, `brave`, `vscode`, `dbeaver-bin`, `nautilus`,
  `evolution`, `copyq`, `handbrake`, `wineWow64Packages.stable`, `winetricks`, `blender`.
- `dbeaver-bin` (not `dbeaver` — renamed upstream with the prebuilt-binary switch) is the GUI
  counterpart to the Databases row above; Apache-2.0, so no unfree gate.
- `blender` is GPU-conditional (gated on `videoDrivers`, since no host has a `facter.json` yet so
  `detected.nvidia` is false everywhere):
  - **desktop** — the **`blender-bin` flake** (edolstra's nix-warez): upstream's official
    binaries with CUDA + OptiX Cycles baked in, zero local compiling. `packages.default` =
    upstream's newest, so Renovate lock bumps track it. Accepted trade-off (user call,
    2026-07-20: GPU Cycles beats version freshness): it trails nixpkgs — 5.0.1 vs 5.1.2 when
    added. See <https://wiki.nixos.org/wiki/Blender>.
  - **laptop** — the cached nixpkgs CPU-Cycles build, NEWER than the desktop's. Its AMD APU
    can't do GPU Cycles either way (HIP wants a supported discrete Radeon), so blender-bin
    would cost it freshness for nothing. EEVEE/viewport still run on the GPU on both hosts.
  - **History (tried and dropped, same day 2026-07-20):**
    `blender.override { cudaSupport = true; }` — CUDA + OptiX Cycles verified working on the
    5090, but the cost recurred forever: **no CUDA build is ever cached, by design** —
    cache.nixos.org carries none (the CUDA EULA makes them unfree, so Hydra won't build them),
    and the community CUDA caches (`cache.nixos-cuda.org`, the `blender-cuda` Cachix) key on
    *their* nixpkgs rev, so an override computed against ours can never hit them (verified
    misses). Every nixpkgs bump therefore meant a local rebuild of blender (~22 min, 3.8 GiB
    closure) PLUS its CUDA-tainted dep chain — `opensubdiv` (the one dep that builds its own
    CUDA kernels) and, above it, the very large `openusd` (Pixar's Universal Scene Description,
    Blender's USD import/export lib — no CUDA of its own, rebuilt only because its opensubdiv
    input changed). The desktop's `nixpkgs.config.cudaCapabilities = [ "12.0" ]` pin left with
    the override (`hosts/desktop/default.nix` keeps a note).
- Theming: dconf `prefer-dark` + `Posy_Cursor`; `gtk` (GTK3/4 dark hint); `qt` (adwaita-dark).
- `home.activation.trustCustomCAs` imports `security.pki.certificateFiles` into `~/.pki/nssdb`
  for Chrome/Brave (inert when no custom CAs).

## Graphical base — `modules/desktop-base.nix` (graphical: D L)

- Audio: `security.rtkit` + `services.pipewire` (alsa, pulse).
- Graphics: `hardware.graphics.enable`.
- Fonts: `nerd-fonts.jetbrains-mono`, `nerd-fonts.fira-code`, `noto-fonts`,
  `noto-fonts-color-emoji` + fontconfig (slight hinting, grayscale AA).
- Networking: `networking.networkmanager`. Dark mode: `programs.dconf`. Power: `services.upower`
  (DMS battery readout).
- Firefox enterprise-roots CA policy (inert without custom CAs).
- Packages: `trilium-desktop`, `posy-cursors`. `trilium-desktop` is **not** nixpkgs' — the
  `modules/chromium-cm-fix.nix` overlay rebinds that attr to the `trilium` flake input's
  `packages.<system>.desktop` (built from source) with the HDR flag wrapped on.
- Adds `networkmanager`, `video`, `audio` groups to `${username}`.

## Wayland + Hyprland — `modules/hyprland.nix` (graphical: D L)

- `programs.hyprland`, `services.greetd` (tuigreet), `security.polkit`, `xdg.portal` (+gtk).
- `NIXOS_OZONE_WL = "1"`.
- DankMaterialShell: `programs.dank-material-shell` (`systemd.enable = false`,
  `plugins.hyprlandSubmapIndicator`, `plugins.linuxWallpaperEngine`). Imports `chromium-cm-fix.nix` + DMS modules.
- Packages: `waybar`, `rofi`, `wl-clipboard`, `grim`, `slurp`, `swappy`, `grimblast`,
  `hyprlock`, `hypridle`, `brightnessctl`, `playerctl`, `pavucontrol`, `hyprsome`,
  `pyprland`, `hyprswitch` (`hyprshell`, from flake input).

## GPU drivers

- `modules/nvidia.nix` (D): `videoDrivers = ["nvidia"]`, modesetting, `open`, power mgmt,
  shader-cache env, `hypr/gpu.conf` fragment.
- `modules/amd.nix` (L): `videoDrivers = ["amdgpu"]`, mesa/RADV, `hypr/gpu.conf` fragment.

## Gaming — `modules/gaming.nix` (graphical: D L)

- `programs.steam` (+ `proton-ge-bin`), `programs.gamemode`, `programs.gamescope`
  (`capSysNice`), `hardware.graphics.enable32Bit`.
- `services.scx` (`scx_bpfland`) + sysctls `kernel.split_lock_mitigate=0`, `vm.swappiness=100`
  (paired with zram), `vm.max_map_count=2147483642`; `zramSwap` (zstd, 50% RAM). See
  [gaming.md](gaming.md).
- Packages: `mangohud`, `heroic`, `protontricks`.
- Desktop additionally runs the CachyOS kernel (`boot.kernelPackages = linuxPackages_cachyos`
  in `hosts/desktop`, via the `chaotic` input).

> Racing-wheel support (`new-lg4ff`, `oversteer`) from duck was **intentionally not ported**.

## Desktop apps — `modules/desktop-apps.nix` (graphical: D L)

- `hardware.logitech.wireless` (+ Solaar GUI).
- `programs.kdeconnect` (opens firewall 1714-1764; `kdeconnectd` runs via exec-once).
- Home packages: `slack`, `discord`, `signal-desktop`, `spotify`, `kdePackages.dolphin`,
  `owncloud-client`, `obs-studio`, `vlc`, `plex-desktop`, `imv`,
  `linux-wallpaperengine` (Steam WE workshop renderer; binary dep of the DMS `linuxWallpaperEngine`
  plugin — launched by the plugin, not an exec-once), `prismlauncher`, `nomachine-client`, `anydesk`,
  `zoom-us`, `playwright`, `playwright-test`, `playwright-mcp`.
- Playwright env vars + `/opt/google/chrome/chrome` tmpfiles symlink.
- Writes the `hypr/autostart.conf` exec-once fragment (see architecture.md).

## SnapX — `modules/snapx.nix` (graphical: D L)

- `snapx-ui`: SnapX (ShareX fork — capture, annotate, upload to anywhere), C#/Avalonia, GPL-3.
  **On trial at 0.4.0-alpha; flameshot remains the default screenshot tool.**
- Built from upstream's **Fedora RPMs** (nvfetcher-pinned, Renovate-bumped), run inside a
  `buildFHSEnv` — NOT patchelf'd. `snapx-ui` is a self-contained .NET single-file bundle whose
  runtime+DLLs sit past the last ELF section, so patchelf/strip overwrite them and the app
  SIGSEGVs on launch; `dontFixup` is load-bearing. See the module header for the full why.
- Captures via the **XDG Screenshot portal** (never raw X11), so on Hyprland it inherits the
  grim wrapper from `modules/hyprland.nix`.

## Camera + microphone effects — `modules/cleanroom.nix` (graphical: D L)

- **Cleanroom** (`cleanroomd`, `cleanroom-ctl`, GUI + tray) — our own webcam/mic effects
  daemon, added as the `cleanroom` flake input. Background blur/replace/green-key on
  wgpu/Vulkan and DeepFilterNet mic denoise, published as `cleanroom_cam` (PipeWire
  `Video/Source`) and `cleanroom_mic`, plus a v4l2loopback node for apps that only speak V4L2.
- `v4l2loopback` kernel module, **2 devices, no `video_nr` pin**: cleanroom selects a free
  node at runtime so it and OBS's "Start Virtual Camera" can produce concurrently.
  `exclusive_caps=1` stays load-bearing (Chromium/Teams/Zoom ignore a node advertising both
  output and capture caps).
- ⚠️ Model weights are **not** declarative and not bundled — DeepFilterNet's weights licence
  is unresolved upstream and this repo is public. Run `cleanroom-ctl fetch-models` once per
  host; until then the mic is a *reported* passthrough.
- Replaced three modules at once: `nvbroadcast.nix` (CUDA-only, desktop-only, pip venv),
  `virtual-camera.nix` (pinned `/dev/video10`) and `noise-suppression.nix` (a mandatory
  PipeWire daemon filter-chain that could take all audio down on a LADSPA load failure).
  The laptop gains a blurred webcam it never had — that is the point of the vendor-neutral
  matting backend.

## Security / pentest — `modules/pentest.nix` (graphical: D L)

- `programs.wireshark` + `wireshark` group on `${username}`.
- Packages: `burpsuite`, `nmap`, `wireshark`, `sqlmap`, `ffuf`, `gobuster`, `feroxbuster`,
  `nikto`, `hashcat`, `john`, `hydra`, `netcat-gnu`.

## Host-only modules

- `modules/laptop.nix` (L): power-profiles-daemon, lid suspend, acpilight, fwupd.
- `modules/server.nix` (S): SSH hardening, sleep targets off, journald cap, `htop tmux rsync
  dnsutils`.

## Out-of-tree pins — `nvfetcher.toml` → `_sources/generated.nix`

`kubectl`, `talosctl` (static Go binaries via `mkBin`), `ksops`, `libratbag` (fork pin).
