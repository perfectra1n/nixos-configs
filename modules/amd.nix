{ config, pkgs, lib, username, ... }:

# AMD GPU — laptop. amdgpu + mesa (RADV Vulkan) work out of the box; 32-bit
# GL/Vulkan comes from gaming.nix. Listed explicitly for clarity.
{
  services.xserver.videoDrivers = [ "amdgpu" ];
  # No proprietary driver needed. GPU compute (ROCm) would go here — not for gaming.

  # Hyprland GPU env (flake-owned fragment the chezmoi hyprland.conf sources).
  # amdgpu does hardware cursors fine, so no override needed.
  home-manager.users.${username}.xdg.configFile."hypr/gpu.conf".text = ''
    # AMD — written by the flake (modules/amd.nix). Do not edit by hand.
    env = LIBVA_DRIVER_NAME,radeonsi
  '';
}
