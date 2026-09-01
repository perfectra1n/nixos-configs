# What `desktop` composes: the shared `graphical` stack (flake.nix) + the extras only this
# box needs — the NVIDIA card and the VMware Workstation host.
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
    # Desktop-only because it is the only host with virtualisation.vmware.host.enable.
    # Not optional: this LAN hands out a /16, so VMware's randomly-chosen 192.168.x.0/24
    # vmnets land INSIDE the LAN prefix and black-hole real hosts. See the module header.
    ../../modules/vmware-net.nix
    # The CyberPower CP1500PFCLCDa is plugged into this box's USB.
    ../../modules/ups.nix
    # iOS device backups run here because this is the box the phones USB-pair with, and
    # Apple only allows Wi-Fi backups from a trusted machine on the same LAN.
    ../../modules/ios-backup.nix
  ];
  homeModules = [ ../../home/gui.nix ../../home/docker.nix ];
}
