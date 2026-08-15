# What `desktop` composes: the shared `graphical` stack (flake.nix) + NVIDIA-only extras.
# A plain spec consumed by mkHost — NOT a NixOS module, so no module imports another module.
#
# Note on cleanroom.nix (it comes from `graphical`): NV Broadcast used to be opted into HERE,
# because it was CUDA-only. Cleanroom replaced it and mattes on wgpu/Vulkan, so there is nothing
# camera-related left to select per-host — it moved up into the shared list. Cleanroom and OBS now
# each hold their own v4l2loopback node concurrently, rather than taking turns on one pinned
# /dev/video10.
{ inputs, graphical }:
{
  extraModules = graphical ++ [
    ../../modules/nvidia.nix
    # Only this host runs VMware Workstation (virtualisation.vmware.host in default.nix),
    # so it is the only one whose vmnet subnets can collide with the LAN.
    ../../modules/vmware-net.nix
  ];
  homeModules = [ ../../home/gui.nix ../../home/docker.nix ];
}
