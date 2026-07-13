{ config, pkgs, lib, username, ... }:

# NVIDIA proprietary driver — desktop. (If facter detects no NVIDIA on this box,
# swap this module for modules/amd.nix in flake.nix; or gate with config.detected.nvidia.)
{
  services.xserver.videoDrivers = [ "nvidia" ];

  hardware.nvidia = {
    modesetting.enable = true; # required; also needed for Wayland/Hyprland
    nvidiaSettings = true;
    # NVIDIA's open kernel module (userspace stays proprietary). Default for Turing+
    # and REQUIRED for Blackwell (RTX 50-series). Set false only for very old GPUs.
    open = true;
    # `latest` (not `stable`) to chase Wayland present-stutter and to cover the newest
    # GPUs (RTX 50-series/Blackwell need it). Drop to `stable` if a `latest` bump regresses.
    package = config.boot.kernelPackages.nvidiaPackages.latest;
    # Saves VRAM → RAM on suspend and restores on resume — needed for reliable
    # suspend/resume on NVIDIA + Wayland.
    powerManagement.enable = true;
  };

  # GPU in containers via CDI: `docker run --device nvidia.com/gpu=all …`. The module
  # generates the device spec (/var/run/cdi) and flips Docker's cdi feature flag itself;
  # the legacy `virtualisation.docker.enableNvidia` runtime wrapper is deprecated.
  hardware.nvidia-container-toolkit.enable = true;

  # Hyprland + NVIDIA env (GBM/GLX/VAAPI). Written as a flake-owned fragment the
  # chezmoi hyprland.conf sources, so GPU truth stays here and prefs stay in chezmoi.
  home-manager.users.${username}.xdg.configFile."hypr/gpu.conf".text = ''
    # NVIDIA — written by the flake (modules/nvidia.nix). Do not edit by hand.
    env = LIBVA_DRIVER_NAME,nvidia
    env = GBM_BACKEND,nvidia-drm
    env = __GLX_VENDOR_LIBRARY_NAME,nvidia
    cursor {
      no_hardware_cursors = false
    }
  '';
}
