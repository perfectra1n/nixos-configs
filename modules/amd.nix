{ config, pkgs, lib, username, ... }:

# AMD GPU — laptop. amdgpu + mesa (RADV Vulkan) work out of the box; 32-bit
# GL/Vulkan comes from gaming.nix. Listed explicitly for clarity.
{
  services.xserver.videoDrivers = [ "amdgpu" ];
  # No proprietary driver needed. GPU compute (ROCm) would go here — not for gaming.

  # Hyprland GPU env (flake-owned Lua fragment the chezmoi hyprland.lua requires as nix.gpu).
  # amdgpu does hardware cursors fine, so no override needed.
  home-manager.users.${username}.xdg.configFile."hypr/nix/gpu.lua".text = ''
    -- AMD — written by the flake (modules/amd.nix). Do not edit by hand.
    hl.env("LIBVA_DRIVER_NAME", "radeonsi")
  '';
}
