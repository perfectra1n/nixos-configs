# Package inventory

What's installed, which file owns it, and which hosts get it. The modules are the source of
truth — this is a hand-maintained summary. "Hosts" uses: **D**=desktop, **L**=laptop,
**S**=server, **W**=wsl.

## CLI / dev — `home/common.nix` (every host: D L S W)

| Group | Packages |
|-------|----------|
| Shell | `fish`, `starship`, `fzf`, `fishPlugins.fzf-fish`, `fishPlugins.z`, `tmux` |
| CLI tools | `bat`, `fd`, `ripgrep`, `jq`, `nnn`, `git`, `delta`, `lazygit`, `lazydocker`, `chezmoi`, `btop`, `ncdu`, `yq-go`, `hugo` |
| Editor (neovim + LazyVim deps) | `neovim`, `gcc`, `nodejs`, `lua-language-server`, `stylua`, `tree-sitter` |
| Dev / ops | `python3` (+pip, requests), `k9s`, `kubernetes-helm`, `kustomize`, `krew`, `cilium-cli`, `talhelper`, `sops`, `ansible`, `opentofu`, `tea`, `awscli2`, `claude-code`, `mise` |
| Media | `ffmpeg`, `imagemagick`, `yt-dlp` |

> `opentofu` is this repo's deliberate FOSS choice over duck's `terraform` (BSL). `mise` is
> a bare package activated by chezmoi, not `programs.mise` (chezmoi boundary).

## System base — `modules/common.nix` (every host: D L S W)

- Packages: `git vim curl wget bash psmisc wireguard-tools zip unzip gzip gnutar cmake file
  nvfetcher sops age ssh-to-age`, plus pinned `kubectl` + `talosctl` (via `mkBin`) and
  `kubectl-krew`.
- Programs/services: `programs.fish`, `programs.nix-ld`, `programs.ssh.enableAskPassword =
  false`, `services.openssh`, `services.envfs`, `virtualisation.docker`. Firewall disabled.
- User `${username}` in `wheel`+`docker`, fish login shell, passwordless sudo. sops wiring
  (inert until a secret is declared).

## GUI apps — `home/gui.nix` (graphical: D L)

- Packages: `kitty`, `google-chrome`, `firefox`, `brave`, `vscode`, `nautilus`, `evolution`,
  `copyq`, `handbrake`, `wineWow64Packages.stable`, `winetricks`.
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
- Packages: `trilium-desktop`, `posy-cursors`.
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

## Virtual camera — `modules/virtual-camera.nix` (graphical: D L)

- `v4l2loopback` kernel module: one capture node at `/dev/video10`
  (`card_label="Virtual Camera"`, `exclusive_caps=1`, `max_buffers=4`) — produced into by
  NV Broadcast (desktop) or OBS's "Start Virtual Camera", consumed by Meet/Teams/Zoom.

## NV Broadcast — `modules/nvbroadcast.nix` (desktop only)

- `nvbroadcast` + `nvbroadcast-vcam` (+ launcher entry): unofficial NVIDIA Broadcast
  (AI blurred/virtual-background webcam, noise removal, meeting transcription). A
  `buildFHSEnv` that pip-installs the nvfetcher-pinned source (`[cuda,meeting]` extras)
  into a first-run venv at `~/.local/share/nvbroadcast-nix` — see the module header for
  why it can't be a normal Nix package. Replaced the OBS blurcam + obs-backgroundremoval
  stack (see desktop-scripts.md).

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
