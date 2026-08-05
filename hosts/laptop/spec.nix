# What `laptop` composes: the shared `graphical` stack (flake.nix) + AMD/portable extras.
# A plain spec consumed by mkHost — NOT a NixOS module, so no module imports another module.
#
# Webcam effects DO reach this host now: `graphical`'s cleanroom.nix mattes on wgpu/Vulkan, so a
# blurred webcam no longer needs NVIDIA. That is precisely why it replaced NV Broadcast, which was
# CUDA-only and therefore desktop-only — this host previously had no blur available at all.
{ inputs, graphical }:
{
  extraModules = graphical ++ [
    ../../modules/amd.nix
    ../../modules/laptop.nix
    ../../modules/miracast.nix # cast the screen to Miracast TVs — needs Wi-Fi for the P2P leg, so laptop-only
  ];
  homeModules = [ ../../home/gui.nix ../../home/docker.nix ];
}
