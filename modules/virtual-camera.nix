{ config, pkgs, lib, ... }:

# Virtual camera device — a v4l2loopback capture node at a stable /dev/video10, consumed by
# whatever produces a processed webcam feed: NV Broadcast (modules/nvbroadcast.nix, desktop)
# or OBS's "Start Virtual Camera" (modules/desktop-apps.nix, both graphical hosts). Split out
# of desktop-apps.nix because the device now has multiple producers — one at a time; the
# node is exclusive while producing.
#
# Build the module against whatever kernel the host runs (CachyOS on desktop/laptop) via
# config.boot.kernelPackages.
#   exclusive_caps=1 is the load-bearing option: Chromium/Teams/Zoom ignore a loopback node
#     that advertises BOTH output+capture caps, so this forces capture-only and they detect it.
#   video_nr=10 pins a stable /dev/video10 so it doesn't fight the real webcam for a number —
#     and NV Broadcast hardcodes exactly this path, so the number is load-bearing for it too.
#   card_label is what Meet/Teams/Zoom display as the camera's name — kept producer-neutral.
#   max_buffers=4 caps the queue at what NV Broadcast's upstream installer sets (low latency,
#     enough slack for consumer frame-rate mismatch).
{
  boot.extraModulePackages = [ config.boot.kernelPackages.v4l2loopback ];
  boot.kernelModules = [ "v4l2loopback" ];
  boot.extraModprobeConfig = ''
    options v4l2loopback devices=1 video_nr=10 card_label="Virtual Camera" exclusive_caps=1 max_buffers=4
  '';
}
