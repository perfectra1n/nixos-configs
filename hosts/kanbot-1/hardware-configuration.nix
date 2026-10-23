# PLACEHOLDER — replace on the real machine:
#   mise run hardware     (run ON the box, then commit)
# This stub only exists so the flake evaluates in CI before the box is installed.
{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  # nvme: the root IS the PM9A3 — without it a placeholder-built initrd can't find /.
  boot.initrd.availableKernelModules = [ "nvme" "ahci" "xhci_pci" "virtio_pci" "sd_mod" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ ];
  boot.extraModulePackages = [ ];

  fileSystems."/" = {
    device = "/dev/disk/by-uuid/00000000-0000-0000-0000-000000000000";
    fsType = "ext4";
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/0000-0000";
    fsType = "vfat";
    options = [ "fmask=0077" "dmask=0077" ];
  };

  swapDevices = [ ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
