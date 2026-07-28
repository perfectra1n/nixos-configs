{
  description = "NixOS + Home Manager — multi-host (desktop / laptop / server)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager";
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

    # blender-bin — upstream's OFFICIAL Blender binaries (edolstra's nix-warez), CUDA/OptiX/HIP
    # Cycles backends baked in. The NVIDIA desktop's blender (home/gui.nix): the only zero-compile
    # route to GPU Cycles, since a nixpkgs cudaSupport build can never be cached (CUDA EULA keeps
    # it off Hydra, community caches key on their own nixpkgs rev) and rebuilding blender +
    # opensubdiv + openusd locally on every bump was rejected. Trade-off, accepted deliberately:
    # it trails nixpkgs (5.0.1 vs 5.1.2 when added). Follows our nixpkgs safely — it uses nixpkgs
    # only for the unpack/patchelf wrapper (no compilation, no binary cache to miss).
    blender-bin = {
      url = "github:edolstra/nix-warez?dir=blender";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Trilium Notes — upstream's OWN flake instead of nixpkgs' `trilium-desktop`, which merely
    # repacks the prebuilt release zip and trails main (0.104.0 vs 0.104.1). Price of the swap:
    # this builds the whole pnpm monorepo + Electron locally — one FOD per npm tarball, cached
    # nowhere upstream — and pnpm2nix reads the lockfile through IFD, so `nix flake check` and
    # CI's --dry-run now hit the network at EVAL time. Follows nixpkgs because nothing caches
    # this build either way: a second nixpkgs would buy only a duplicate eval, and our pin
    # already has the nodejs_24 / pnpm_11 / electron_43 it wants. Consumed by
    # modules/chromium-cm-fix.nix (the overlay that also adds the HDR flag) — NOT by
    # systemPackages directly, so that `pkgs.trilium-desktop` stays the one name to refer to.
    # ⚠️ Tracks main, so a bump is not routine: launching a newer build migrates
    # ~/.local/share/trilium-data one-way (dbVersion 238 → 239 as of this commit) and a NixOS
    # generation rollback does NOT un-migrate it. Sync version must also stay in step with the
    # Trilium server. Back up document.db before switching onto a bump.
    trilium = {
      url = "github:TriliumNext/Trilium";
      inputs.nixpkgs.follows = "nixpkgs";
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

      # Which secrets actually exist in secrets/secrets.yaml, read ONCE here instead of five
      # modules each re-reading and substring-searching the raw file. sops keeps YAML keys in
      # plaintext, so this needs no age identity — a fresh checkout still evaluates. Modules use
      # `secrets.has "group/key"`; see lib/secrets.nix for why the group qualifier is load-bearing.
      secrets = import ./lib/secrets.nix { inherit (nixpkgs) lib; }
        (builtins.readFile ./secrets/secrets.yaml);

      # Factory: every host gets common.nix + its own hosts/<name> dir +
      # home-manager + sops + facter, then opts into whatever extra modules it
      # needs (desktop stack, gaming, gpu, …). `homeModules` are extra
      # home-manager imports for graphical hosts (home/gui.nix).
      mkHost = hostName: { extraModules ? [ ], homeModules ? [ ] }:
        nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs = { inherit inputs hostName username secrets; };
          modules = [
            ./modules/common.nix
            ./modules/facter.nix
            ./modules/system-diff.nix
            ./modules/nix-cache.nix # LAN attic binary cache: sops-rendered substituter + watch-store push (inert until secrets land)
            ./modules/snowflake-py314-fix.nix # snowflake-connector-python 4.4.0 bump until nixpkgs#511615 lands (snow is on every host via home/common.nix)
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

      # The stack BOTH graphical hosts share. This was duplicated verbatim — trailing comments and
      # all — in each host's list, and the two copies had already drifted apart. Per-host GPU and
      # portable extras live in hosts/<name>/spec.nix.
      graphical = [
        ./modules/desktop-base.nix
        ./modules/hyprland.nix
        ./modules/gaming.nix
        ./modules/pentest.nix
        ./modules/sigma-crowdstrike-fix.nix # stale nixpkgs pname breaks sigma-cli's build (pentest.nix); drop when nixpkgs renames it
        ./modules/desktop-apps.nix
        ./modules/snapx.nix # SnapX (ShareX fork) — on trial next to flameshot; FHS-sandboxed .NET app
        ./modules/virtual-camera.nix # v4l2loopback /dev/video10 — the node the virtual camera(s) produce into
        ./modules/peripherals.nix # gaming mice (Piper/ratbagd), RGB (OpenRGB), QMK/VIA keyboards (Vial)
        ./modules/noise-suppression.nix # DeepFilterNet mic denoise (Broadcast-like virtual source)
        ./modules/rclone-mounts.nix # rclone files-on-demand mounts: Nextcloud + Google Drive (activate once chezmoi deploys ~/.config/rclone/rclone.conf)
        ./modules/smb-mounts.nix # CIFS mount of //192.168.2.155/main_smb (on-demand automount; activates once the sops creds land)
        ./modules/dotfiles.nix # chezmoi bootstrap: sops token + chezmoi.toml (orchestration in mise.toml — `mise run apply`)
        ./modules/git-credentials.nix # sops-rendered ~/.git-credentials for GitHub + both Gitea (helper line lives in chezmoi gitconfig)
        ./modules/docker-credentials.nix # sops-rendered ~/.docker/config.json for both Gitea + ghcr.io (symlink lives in home/docker.nix)
        inputs.chaotic.nixosModules.default # CachyOS kernel + chaotic cache (see boot.kernelPackages in hosts/<name>)
      ];

      # hosts/ is the single source of truth. It already was for gen-manifests.sh, host.sh and mise's
      # verify — all three glob it — and flake.nix was the last place still hand-listing the hosts.
      # Adding a host is now `mise run new-host`, with no edit here and none to the CI matrix.
      # CAVEAT: readDir sees only GIT-TRACKED content, so an unstaged hosts/<x>/ silently does not
      # exist (it used to be a loud error). `mise run verify` does `git add -A` first, which covers it.
      hostNames = nixpkgs.lib.attrNames
        (nixpkgs.lib.filterAttrs (_: t: t == "directory") (builtins.readDir ./hosts));
    in
    {
      # Each hosts/<name>/spec.nix returns { extraModules, homeModules } — a plain function consumed
      # by mkHost, NOT a NixOS module, so this is still composition rather than cross-import.
      nixosConfigurations = nixpkgs.lib.genAttrs hostNames
        (name: mkHost name (import (./hosts + "/${name}/spec.nix") { inherit inputs graphical; }));

      # Unit tests for lib/. These `throw` at EVAL time rather than failing in a builder, because
      # `nix flake check --no-build` — what mise's verify and CI actually run — only EVALUATES
      # checks. A runCommand full of assertions would be silently skipped by the very command meant
      # to run it. Keep this derivation trivial: a BARE `nix flake check` (no --no-build) realizes
      # checks, and CLAUDE.md tells people to run exactly that.
      checks.x86_64-linux.lib-secrets =
        let
          pkgs = nixpkgs.legacyPackages.x86_64-linux;
          inherit (nixpkgs) lib;
          cases = import ./lib/secrets-test.nix { inherit lib; };
          failures = builtins.filter (c: c.actual != c.expected) cases;
        in
        if failures == [ ] then pkgs.runCommand "lib-secrets-ok" { } "touch $out"
        else throw "lib/secrets.nix FAILED: ${lib.generators.toPretty { } failures}";

      # mise's [tools] pins vs nixpkgs. mise.toml pins the leak-gate tools (lefthook/gitleaks/
      # trufflehog) that home/common.nix ALSO installs, and mise's install dir SHADOWS
      # ~/.nix-profile/bin on PATH — so mise's copy is what the git hooks actually execute. If the
      # two ever disagreed, manifests/ would advertise one gitleaks while a different one gated
      # every commit, and Renovate WILL try: its built-in mise manager bumps mise.toml on its own
      # schedule, while nixpkgs moves via flake-inputs.txt. This turns that silent divergence into
      # a red CI run. Same eval-time `throw` as lib-secrets above, and for the same reason:
      # `nix flake check --no-build` only EVALUATES checks, so a runCommand of assertions would be
      # skipped by the very command meant to run it.
      checks.x86_64-linux.mise-nixpkgs-versions =
        let
          pkgs = nixpkgs.legacyPackages.x86_64-linux;
          inherit (nixpkgs) lib;
          pinned = (builtins.fromTOML (builtins.readFile ./mise.toml)).tools or { };
          drift = lib.filterAttrs (name: want: (pkgs.${name}.version or "<no such package>") != want) pinned;
          fmt = name: want: "  ${name}: mise.toml pins ${want}, nixpkgs has ${pkgs.${name}.version or "<no such package>"}";
        in
        if drift == { } then pkgs.runCommand "mise-nixpkgs-versions-ok" { } "touch $out"
        else throw ''
          mise.toml [tools] has drifted from nixpkgs:
          ${lib.concatStringsSep "\n" (lib.mapAttrsToList fmt drift)}
          mise SHADOWS the Nix profile on PATH, so the pinned version is the one the leak gate runs.
          Fix: align mise.toml with nixpkgs (or bump the flake so nixpkgs catches up), then re-run.
        '';

      # Ops tooling as flake apps: shellcheck-gated at build time, runtime deps pinned,
      # runnable from anywhere via `nix run github:perfectra1n/nixos-configs#<name>`.
      # Scripts are BODIES only — writeShellApplication injects the shebang + set -euo pipefail.
      packages.x86_64-linux =
        let pkgs = nixpkgs.legacyPackages.x86_64-linux; in
        {
          gen-manifests = pkgs.writeShellApplication {
            name = "gen-manifests";
            runtimeInputs = with pkgs; [ nix gnused gnugrep coreutils findutils ];
            text = builtins.readFile ./scripts/gen-manifests.sh;
          };
          whatchanged = pkgs.writeShellApplication {
            name = "whatchanged";
            runtimeInputs = with pkgs; [ nix gnused gnugrep coreutils ];
            text = builtins.readFile ./scripts/whatchanged.sh;
          };
          suspects = pkgs.writeShellApplication {
            name = "suspects";
            runtimeInputs = with pkgs; [ nix gnused gnugrep coreutils ];
            text = builtins.readFile ./scripts/suspects.sh;
          };
          # The commit/push tail four mise tasks used to repeat verbatim. Here rather than as a
          # loose script so it gets the same shellcheck gate as the others.
          commit-push = pkgs.writeShellApplication {
            name = "commit-push";
            runtimeInputs = with pkgs; [ git ];
            text = builtins.readFile ./scripts/commit-push.sh;
          };
        };
    };
}
