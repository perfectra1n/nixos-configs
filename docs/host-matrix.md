# Host × module matrix

Which modules each host opts into (defined in `flake.nix`'s `mkHost` calls). `common`,
`facter`, `system-diff`, `nix-cache`, `hosts/<name>`, sops-nix, home-manager, and
`home/common.nix` are implicit on **every** host and omitted from the table.

| Module / home import | desktop | laptop | server |
|----------------------|:-------:|:------:|:------:|
| `modules/desktop-base.nix` | ✅ | ✅ | — |
| `modules/hyprland.nix` | ✅ | ✅ | — |
| `modules/gaming.nix` | ✅ | ✅ | — |
| `modules/nvidia.nix` | ✅ | — | — |
| `modules/amd.nix` | — | ✅ | — |
| `modules/laptop.nix` | — | ✅ | — |
| `modules/pentest.nix` | ✅ | ✅ | — |
| `modules/desktop-apps.nix` | ✅ | ✅ | — |
| `modules/cleanroom.nix` | ✅ | ✅ | — |
| `modules/peripherals.nix` | ✅ | ✅ | — |
| `modules/rclone-mounts.nix` | ✅ | ✅ | — |
| `inputs.chaotic.nixosModules.default` | ✅ | — | — |
| `modules/server.nix` | — | — | ✅ |
| `home/gui.nix` (homeModules) | ✅ | ✅ | — |

Transitively, `modules/hyprland.nix` imports `modules/chromium-cm-fix.nix` and the DMS
modules, so those reach desktop + laptop too.

`modules/peripherals.nix` is physical-device management for the graphical hosts: gaming mice
(`ratbagd`/Piper), RGB (OpenRGB), QMK/VIA keyboards (Vial + the `plugdev` udev access), and the
Logitech receiver rules — it replaced Solaar. It also carries a `libratbag` overlay that builds
the package from upstream **git master** instead of nixpkgs' 0.18 release: the **G502 X PLUS**
(onboard-profile format `0x05`, wireless PID `046d:4099`) is only supported by libratbag commits
merged after v0.18 (#1693/#1728/#1799). Drop the overlay once nixpkgs ships libratbag > 0.18.

## Per-host notes

### desktop — bare-metal, NVIDIA
- Wayland + Hyprland + gaming + pentest + apps.
- `boot.kernelPackages = pkgs.linuxPackages_cachyos` (CachyOS kernel, via the `chaotic`
  input) — pairs with the `scx` scheduler.
- systemd-boot (UEFI); Bluetooth + Blueman.
- greetd `initial_session` autologin straight into Hyprland (tuigreet still handles relogin).
- NVIDIA driver pinned to `nvidiaPackages.latest` (see `modules/nvidia.nix`).
- Swap `modules/nvidia.nix` → `modules/amd.nix` if the box is AMD.

### laptop — bare-metal, AMD
- Same desktop stack as `desktop`, with `modules/amd.nix` + `modules/laptop.nix` (power
  management, lid, backlight, fwupd).
- Runs `scx` on the **stock** kernel (no chaotic).
- systemd-boot (UEFI); Bluetooth + Blueman.

### server — headless
- `modules/server.nix` only: SSH key-only, sleep disabled, journald capped, ops CLI.
- No desktop, no `home/gui.nix`. Supports BIOS GRUB too (see the host file).

## Adding a host

`NAME=<name> mise run new-host`, then `mise run verify`.

That is the entire procedure. `flake.nix` derives `nixosConfigurations` from `hosts/` via
`readDir`, and the CI matrix is generated from `ls hosts`, so there is no `mkHost` entry to add
and no matrix to edit. The task scaffolds `hosts/<name>/{default.nix,spec.nix,hardware-configuration.nix}`;
edit `spec.nix` if the box is not a plain server.

One thing it cannot do: a new host still has to be added to the branch-protection
required-checks list by hand.
