# Miracast (screen casting) — design

**Date:** 2026-07-08
**Scope:** laptop host only

## Goal

Cast the laptop's screen out to a Miracast-capable TV/dongle.

## Design

- New single-concern module `modules/miracast.nix` that installs
  `pkgs.gnome-network-displays` via `environment.systemPackages`.
  Despite the GNOME name it works on Hyprland: screen capture goes through the
  PipeWire / xdg-desktop-portal screencast interface already configured by
  `modules/hyprland.nix`.
- Laptop opts in with one `./modules/miracast.nix` line in its `extraModules`
  list in `flake.nix` (repo convention: modules composed via mkHost, never
  cross-imported).
- No networking changes: Wi-Fi Direct (P2P) is negotiated by NetworkManager
  (already on via `modules/desktop-base.nix`) through wpa_supplicant, which
  nixpkgs builds with P2P support by default; the firewall is globally
  disabled (`modules/common.nix`), so Miracast's dynamic RTSP/RTP ports need
  no opening.
- Out of scope: acting as a Miracast *receiver*, Chromecast/avahi discovery,
  desktop host (can opt in later with one line).

## Verification

`git add -A`, `nix flake check --no-build`, dry-run build of the laptop
toplevel. End-to-end casting to a real TV must be tested on the laptop after
`sudo nixos-rebuild switch`.
