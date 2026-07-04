{ config, pkgs, lib, ... }:

# Gaming stack — shared by the graphical desktop/laptop hosts. NOT on server/wsl.
# GPU drivers are separate (modules/nvidia.nix, modules/amd.nix).
{
  programs.steam = {
    enable = true;                                # FHS runtime + controller udev (not a bare package)

    # Stop Steam leaking a ScreenSaver inhibit that never gets released. Steam's SDL bits —
    # notably `gldriverquery` (run at every launch to probe the GL driver) — register an
    # org.freedesktop.ScreenSaver inhibit (the orphan "My SDL Application") and fail to release it
    # on exit (steam-for-linux #5607 / #11207 / #11354 / #11443). DMS owns that D-Bus service and
    # mirrors any external screensaver inhibit into a compositor-level Wayland idle-inhibitor that
    # freezes its IdleMonitor (and every other ext-idle-notify client — hypridle included), so the
    # monitors get stuck ON until DMS restarts. SDL_VIDEO_ALLOW_SCREENSAVER=1 tells SDL not to
    # block the screensaver, killing the leak at the source (the upstream fix in #11207).
    # Keeping the screen awake DURING a game is then gamemode's job, NOT Steam's (see the gamemode
    # block below). Proton/Win32 games can't do it themselves on Wayland anyway: their
    # SetThreadExecutionState keep-awake dead-ends at the XWayland dummy and never reaches DMS —
    # so before this fix it was only Steam's *leak* keeping the screen on 24/7, masking that games
    # weren't inhibiting at all.
    package = pkgs.steam.override {
      extraEnv.SDL_VIDEO_ALLOW_SCREENSAVER = "1";
    };

    # Extra Steam compat tools (selectable per-game, NOT the default):
    #   - proton-ge-bin: GE-Proton (nixpkgs) — broader Windows-game compat, on every gaming host.
    #   - proton-cachyos: CachyOS-flavored Proton (latest DXVK/VKD3D + perf-built). It only exists
    #     in the chaotic overlay, which only hosts importing chaotic.nixosModules.default carry
    #     (desktop + laptop today). The `pkgs ? …` guard makes chaotic hosts auto-get it — and
    #     substitute it from chaotic's binary cache — while non-chaotic hosts cleanly skip it instead
    #     of failing to eval / compiling Proton from source. _x86_64_v3 = AVX2; bump to _v4 (AVX-512)
    #     on a Zen 4/5 box for max. So a future gaming host just needs the chaotic module to get it.
    extraCompatPackages = [ pkgs.proton-ge-bin ]
      ++ lib.optionals (pkgs ? proton-cachyos_x86_64_v3) [ pkgs.proton-cachyos_x86_64_v3 ];
    # remotePlay.openFirewall = true;             # uncomment for Steam Remote Play
  };

  programs.gamemode.enable = true;      # CPU governor/priority boost while a game runs
  # gamemode is ALSO the clean "keep the screen awake while a game runs" mechanism — the
  # counterpart to killing Steam's leaky inhibit above. It inhibits via D-Bus
  # org.freedesktop.ScreenSaver (which DMS honors) for the game's WHOLE duration (cutscenes +
  # controller-only play, regardless of input) and releases it cleanly on exit — no leak, unlike
  # Steam. It only kicks in for games launched with `gamemoderun %command%` in their Steam launch
  # options; Proton/Win32 titles (e.g. GoW Ragnarök) need that, since on Wayland they can't keep
  # the real screen awake on their own. inhibit_screensaver=1 is gamemode's default, pinned here
  # to make the intent explicit (verified: gamemoderun → DMS inhibit on, exits → off).
  programs.gamemode.settings.general.inhibit_screensaver = 1;
  programs.gamescope.enable = true;     # Valve micro-compositor — great for Wayland/Hyprland
  programs.gamescope.capSysNice = true; # CAP_SYS_NICE → realtime scheduling, better frame pacing

  hardware.graphics.enable32Bit = true; # 32-bit GL/Vulkan for games (pairs with desktop-base's enable)

  # sched_ext gaming scheduler — scx_bpfland cuts in-game frame-time stutter vs the default
  # EEVDF scheduler (CachyOS's gaming pick). It's a stock nixpkgs option and works on any
  # kernel with sched_ext (≥6.12; nixos-unstable qualifies) — both the `desktop` and `laptop`
  # hosts run the CachyOS kernel via chaotic (hosts/{desktop,laptop}).
  # ⚠ On the laptop that performance-pin costs battery/idle power — fine plugged in. A/B live:
  # `sudo systemctl stop scx` → EEVDF / `start scx`; set scheduler = "scx_lavd" to compare.
  services.scx.enable = true;
  services.scx.scheduler = "scx_bpfland";

  # Gaming kernel sysctls:
  #  split_lock_mitigate=0 → stop the kernel throttling games that do split-lock atomics
  #    (a real stutter/slowdown source for some Proton titles; harmless on a personal box).
  #  vm.swappiness=100 → with zram (below) swap is fast compressed RAM, so prefer offloading
  #    cold pages to it over evicting page cache. (A low value like 10 is for SLOW disk swap;
  #    zram flips that calculus — keep this paired with the zramSwap block.)
  #  vm.max_map_count → the 65530 default crashes/stutters modern (UE5, DXVK/Proton) games
  #    that mmap heavily — Hogwarts Legacy, Star Citizen, etc. Valve ships INT_MAX-5 on the
  #    Steam Deck for max Windows-game compat; match it. (Arch/Fedora also raised their default.)
  boot.kernel.sysctl = {
    "kernel.split_lock_mitigate" = 0;
    "vm.swappiness" = 100;
    "vm.max_map_count" = 2147483642;
  };

  # zram — compressed in-RAM swap. With swappiness=10 the kernel rarely swaps, but when
  # memory pressure does hit (big open-world streaming, alt-tabbed browser), paging to a
  # zstd-compressed RAM block avoids the disk-IO latency spike that wrecks frame pacing —
  # far better than swapping to an SSD/NVMe. Sized to half of RAM (zstd ~3-4x, so this
  # backs more than its footprint). See docs/gaming.md for the full tuning rationale.
  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 50;
  };

  environment.systemPackages = with pkgs; [
    mangohud     # in-game perf overlay (FPS, frametimes, temps)
    heroic       # Epic / GOG / Amazon launcher
    protontricks # winetricks for Proton prefixes
  ];
}
