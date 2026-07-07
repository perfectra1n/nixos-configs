{
  description = "NixOS + Home Manager — multi-host (desktop / laptop / server / wsl)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixos-wsl = {
      url = "github:nix-community/NixOS-WSL/main";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Secrets: age/PGP-encrypted secrets decrypted at activation time.
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # hyprswitch — GUI Alt+Tab window switcher for Hyprland (not in nixpkgs). Passed to
    # modules via specialArgs `inputs`; used in modules/hyprland.nix.
    hyprswitch = {
      url = "github:h3rmt/hyprswitch";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # chaotic-nyx — CachyOS kernel + bleeding-edge gaming pkgs (not in nixpkgs). Do NOT add
    # inputs.nixpkgs.follows: chaotic builds against its own nixpkgs pin so its binary cache
    # (auto-added by chaotic.nixosModules.default) actually hits; following nixpkgs would
    # force a local kernel compile. Used on the `desktop` and `laptop` hosts (CachyOS kernel).
    chaotic.url = "github:chaotic-cx/nyx/nyxpkgs-unstable";

    # DankMaterialShell (DMS) — Quickshell-based Wayland desktop shell (bar + dock +
    # notifications + launcher). Pin the `stable` branch; follow our nixpkgs per upstream
    # docs so its bundled (pinned) quickshell builds against the same nixpkgs. Imported by
    # modules/hyprland.nix → both Hyprland hosts only. See programs.dank-material-shell there.
    dms = {
      url = "github:AvengeMedia/DankMaterialShell/stable";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # DMS plugin registry — declarative install of DankMaterialShell plugins (prefetched
    # hashes, updated daily upstream). `modules.default` exposes every plugin under
    # programs.dank-material-shell.plugins.<id> (disabled by default); we enable the Hyprland
    # submap indicator in modules/hyprland.nix.
    dms-plugin-registry = {
      url = "github:AvengeMedia/dms-plugin-registry";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Network Indicator DMS plugin — OUR FORK's branch, not the registry's gemb0-0 pin.
    # `flake = false` because the plugin is plain QML (plugin.json at repo root — exactly
    # the layout `plugins.<id>.src` expects); modules/hyprland.nix mkForce-overrides the
    # registry's src with this input. Tracked like every other input: Renovate bumps the
    # branch HEAD via flake-inputs.txt, so pushed commits land on the next Renovate PR.
    network-indicator = {
      url = "github:perfectra1n/Network-Indicator/reliability-hardening";
      flake = false;
    };

    # NOTE: hardware detection uses nixpkgs' built-in `hardware.facter` module
    # (the standalone nixos-facter-modules flake was upstreamed into nixpkgs and
    # is deprecated). A per-host facter.json replaces the fragile
    # `nixos-generate-config` scan — see modules/facter.nix.
  };

  outputs = { self, nixpkgs, home-manager, ... }@inputs:
    let
      # ── EDIT ME ───────────────────────────────────────────────────────────
      # Your login name. Used for the system user (modules/common.nix) and the
      # home-manager user (home/common.nix). Create the SAME name at install
      # time so the install-seeded password survives the first flake switch.
      username = "perf3ct";
      # ──────────────────────────────────────────────────────────────────────

      # Factory: every host gets common.nix + its own hosts/<name> dir +
      # home-manager + sops + facter, then opts into whatever extra modules it
      # needs (desktop stack, gaming, gpu, …). `homeModules` are extra
      # home-manager imports for graphical hosts (home/gui.nix).
      mkHost = hostName: { extraModules ? [ ], homeModules ? [ ] }:
        nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs = { inherit inputs hostName username; };
          modules = [
            ./modules/common.nix
            ./modules/facter.nix
            ./hosts/${hostName}
            inputs.sops-nix.nixosModules.sops
            home-manager.nixosModules.home-manager
            {
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              home-manager.extraSpecialArgs = { inherit inputs username; };
              # Base home for every host (CLI/dev). Graphical hosts add
              # home/gui.nix via `homeModules` below.
              home-manager.users.${username}.imports = [ ./home/common.nix ] ++ homeModules;
            }
          ] ++ extraModules;
        };
    in
    {
      nixosConfigurations = {
        # Bare-metal desktop (NVIDIA) — Wayland + Hyprland + gaming + apps.
        # Swap modules/nvidia.nix → modules/amd.nix if this box is AMD.
        desktop = mkHost "desktop" {
          extraModules = [
            ./modules/desktop-base.nix
            ./modules/hyprland.nix
            ./modules/gaming.nix
            ./modules/nvidia.nix
            ./modules/pentest.nix
            ./modules/desktop-apps.nix
            ./modules/virtual-camera.nix # v4l2loopback /dev/video10 — the node NV Broadcast + OBS's virtual camera produce into
            ./modules/nvbroadcast.nix # NV Broadcast (blurred webcam etc.) — CUDA, so NVIDIA desktop only; replaced the OBS blurcam
            ./modules/peripherals.nix # gaming mice (Piper/ratbagd), RGB (OpenRGB), QMK/VIA keyboards (Vial)
            ./modules/noise-suppression.nix # DeepFilterNet mic denoise (Broadcast-like virtual source)
            ./modules/nextcloud-vfs.nix # rclone WebDAV files-on-demand mount (activates once the sops secret lands)
            ./modules/smb-mounts.nix # CIFS mount of //192.168.2.155/main_smb at /mnt (on-demand automount; activates once the sops creds land)
            ./modules/dotfiles.nix # chezmoi bootstrap: sops token + chezmoi.toml (orchestration in mise.toml — `mise run apply`)
            ./modules/git-credentials.nix # sops-rendered ~/.git-credentials for GitHub + both Gitea (helper line lives in chezmoi gitconfig)
            ./modules/docker-credentials.nix # sops-rendered ~/.docker/config.json for both Gitea + ghcr.io (symlink lives in home/docker.nix)
            inputs.chaotic.nixosModules.default # CachyOS kernel + chaotic cache (see boot.kernelPackages in hosts/desktop)
          ];
          homeModules = [ ./home/gui.nix ./home/docker.nix ];
        };

        # Laptop (AMD) — same desktop stack, AMD GPU + power management.
        laptop = mkHost "laptop" {
          extraModules = [
            ./modules/desktop-base.nix
            ./modules/hyprland.nix
            ./modules/gaming.nix
            ./modules/amd.nix
            ./modules/laptop.nix
            ./modules/pentest.nix
            ./modules/desktop-apps.nix
            ./modules/virtual-camera.nix # v4l2loopback /dev/video10 for OBS's virtual camera (no NV Broadcast here — CUDA-only, and no blur wanted on the laptop)
            ./modules/peripherals.nix # gaming mice (Piper/ratbagd), RGB (OpenRGB), QMK/VIA keyboards (Vial)
            ./modules/noise-suppression.nix # DeepFilterNet mic denoise (Broadcast-like virtual source)
            ./modules/nextcloud-vfs.nix # rclone WebDAV files-on-demand mount (activates once the sops secret lands)
            ./modules/smb-mounts.nix # CIFS mount of //192.168.2.155/main_smb at /mnt (on-demand automount; won't choke when the server is unreachable)
            ./modules/dotfiles.nix # chezmoi bootstrap: sops token + chezmoi.toml (orchestration in mise.toml — `mise run apply`)
            ./modules/git-credentials.nix # sops-rendered ~/.git-credentials for GitHub + both Gitea (helper line lives in chezmoi gitconfig)
            ./modules/docker-credentials.nix # sops-rendered ~/.docker/config.json for both Gitea + ghcr.io (symlink lives in home/docker.nix)
            inputs.chaotic.nixosModules.default # CachyOS kernel + chaotic cache (see boot.kernelPackages in hosts/laptop)
          ];
          homeModules = [ ./home/gui.nix ./home/docker.nix ];
        };

        # Headless server — SSH + docker/services, no desktop.
        server = mkHost "server" {
          extraModules = [ ./modules/server.nix ];
        };

        # WSL2 — headless, NO window manager, CLI/dev tools only.
        wsl = mkHost "wsl" { };
      };
    };
}
