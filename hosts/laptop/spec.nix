# What `laptop` composes: the shared `graphical` stack (flake.nix) + AMD/portable extras.
# A plain spec consumed by mkHost — NOT a NixOS module, so no module imports another module.
#
# No NV Broadcast here — it's CUDA-only, and no blur is wanted on the laptop anyway. So
# `graphical`'s virtual-camera.nix (/dev/video10) serves only OBS's virtual camera on this host.
{ inputs, graphical }:
{
  extraModules = graphical ++ [
    ../../modules/amd.nix
    ../../modules/laptop.nix
    ../../modules/miracast.nix # cast the screen to Miracast TVs — needs Wi-Fi for the P2P leg, so laptop-only
  ];
  homeModules = [ ../../home/gui.nix ../../home/docker.nix ];
}
