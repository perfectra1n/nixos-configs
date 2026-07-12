# What `desktop` composes: the shared `graphical` stack (flake.nix) + NVIDIA-only extras.
# A plain spec consumed by mkHost — NOT a NixOS module, so no module imports another module.
#
# Note on virtual-camera.nix (it comes from `graphical`): on THIS host /dev/video10 has multiple
# producers — NV Broadcast below, or OBS's "Start Virtual Camera" — one at a time. On the laptop
# it serves OBS alone.
{ inputs, graphical }:
{
  extraModules = graphical ++ [
    ../../modules/nvidia.nix
    ../../modules/nvbroadcast.nix # NV Broadcast (blurred webcam etc.) — CUDA, so NVIDIA desktop only
  ];
  homeModules = [ ../../home/gui.nix ../../home/docker.nix ];
}
