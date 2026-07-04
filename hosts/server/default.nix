{ config, pkgs, lib, ... }:

# Headless server. Composes (from flake.nix): common + facter + server. Plus this
# host's hardware + identity below. No desktop stack.
{
  imports = [ ./hardware-configuration.nix ];

  networking.hostName = "server";

  # UEFI boot. If this box is older/BIOS, replace with:
  #   boot.loader.grub = { enable = true; device = "/dev/sda"; };
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
}
