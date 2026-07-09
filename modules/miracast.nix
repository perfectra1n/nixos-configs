{ config, pkgs, lib, ... }:

# Miracast screen casting (cast OUT to a TV/dongle) — gnome-network-displays.
#
# Despite the GNOME name it works on Hyprland: capture goes through the PipeWire /
# xdg-desktop-portal screencast interface (modules/hyprland.nix), not GNOME Shell.
# The Wi-Fi Direct (P2P) leg is negotiated by NetworkManager (modules/desktop-base.nix)
# via wpa_supplicant, which nixpkgs builds with P2P support — so no networking config
# here. Miracast's dynamic RTSP/RTP ports would normally need firewall rules, but the
# firewall is globally off (modules/common.nix), so a bare package is genuinely enough.
#
# Casting requires a Wi-Fi adapter (P2P rides the wireless NIC) — hence opted into by
# the laptop only; the desktop can add this module once it has usable Wi-Fi.
{
  environment.systemPackages = [ pkgs.gnome-network-displays ];
}
