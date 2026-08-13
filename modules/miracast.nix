{ config, pkgs, lib, ... }:

# Miracast screen casting (cast OUT to a TV/dongle) — gnome-network-displays.
#
# Despite the GNOME name it works on Hyprland: capture goes through the PipeWire /
# xdg-desktop-portal screencast interface (modules/hyprland.nix), not GNOME Shell.
# The Wi-Fi Direct (P2P) leg is negotiated by NetworkManager (modules/desktop-base.nix)
# via wpa_supplicant, which nixpkgs builds with P2P support — so no networking config
# here. Miracast's dynamic RTSP/RTP ports would normally need firewall rules, but the
# firewall is globally off (modules/common.nix), so that leg needs nothing from us.
#
# Casting requires a Wi-Fi adapter (P2P rides the wireless NIC) — hence opted into by
# the laptop only; the desktop can add this module once it has usable Wi-Fi.
{
  environment.systemPackages = [ pkgs.gnome-network-displays ];

  # The app has a SECOND, unrelated discovery path: Chromecast sinks found by browsing
  # _googlecast._tcp through an Avahi client. Without a running daemon it aborts that
  # path at startup ("Failed to create avahi client: Daemon not running") and silently
  # lists Wi-Fi Direct sinks only — the failure never surfaces in the UI. openFirewall
  # is a no-op while the global firewall is off, but keeps this honest if that flips.
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    openFirewall = true;
  };
}
