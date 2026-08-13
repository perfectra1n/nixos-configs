{ config, pkgs, lib, ... }:

# AirPlay 2 screen casting (cast OUT to an Apple TV or an AirPlay-capable TV) — doubletake.
#
# Deliberately NOT folded into modules/miracast.nix: the two share the intent and nothing else.
# Miracast is Wi-Fi Direct + RTSP negotiated through NetworkManager on the wireless NIC; AirPlay
# is ordinary TCP/UDP to a routable host. Sinks in practice speak exactly one of the two, so
# having both installed is what actually covers a mixed living room — a Samsung QN55S95B and an
# Apple TV each advertise only _airplay._tcp, answering neither Miracast nor Google Cast, which
# is precisely why gnome-network-displays can never list them.
#
# No Avahi dependency, unlike the Chromecast path in miracast.nix: doubletake discovers sinks with
# a pure-Go mDNS stack (grandcat/zeroconf) inside its own process, and `-target <ip>` skips
# discovery entirely.
#
# Capture rides the PipeWire / xdg-desktop-portal screencast interface (modules/hyprland.nix), so
# it works on Hyprland — the portal prompts for which output to share. H.264 encoding wants VA-API
# (`-hwaccel vaapi`), which comes from the mesa drivers in modules/amd.nix; it falls back to x264
# on the CPU, so a host without a usable VA-API stack still casts, just hotter.
{
  environment.systemPackages = [
    (import ../pkgs/doubletake.nix { inherit pkgs; })
  ];
}
