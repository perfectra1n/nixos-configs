{ inputs, config, pkgs, lib, username, ... }:

# WSL2 host — NO window manager. CLI/dev only (home/common.nix).
# NixOS-WSL replaces hardware-configuration.nix and the bootloader entirely, so there
# is no hardware-configuration.nix / facter.json here.
{
  imports = [ inputs.nixos-wsl.nixosModules.default ];

  networking.hostName = "wsl";

  wsl = {
    enable = true;
    defaultUser = username;
    # startMenuLaunchers = true;   # add Windows start-menu entries if you want them
  };

  # Windows already runs an sshd on port 22; if you enable WSL port forwarding, move
  # this host's sshd off 22 to avoid the clash:
  # services.openssh.ports = [ 2222 ];
}
