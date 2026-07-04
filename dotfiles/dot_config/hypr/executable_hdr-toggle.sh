#!/usr/bin/env bash
# Manually toggle HDR/10-bit on the HDR monitor(s). Bound to Super+Shift+B.
#
# Why: the PipeWire screencast portal (Discord/OBS full-screen share) can't read the 10-bit
# HDR framebuffer — shares come out a black box. Flip HDR OFF to share, then back ON.
# (Everyday screenshots no longer need this — render:keep_unmodified_copy=0 in hyprland.conf fixes
# wedged HDR screencopy; this is for screen-sharing and fullscreen-HDR-game captures.)
#
# The HDR line(s) come from the flake-written monitors.conf (single source of truth), matched
# by the "cm, hdr" field rather than a hardcoded port name — so a DP-x rename can't silently
# break this again (it did: this used to hardcode DP-6 after the panel moved to DP-1).
conf="$HOME/.config/hypr/monitors.conf"

# Full HDR monitor line(s) as written by the flake (strip the "monitor = " prefix).
mapfile -t hdr_lines < <(grep -E '^[[:space:]]*monitor[[:space:]]*=' "$conf" 2>/dev/null \
  | grep -iE 'cm[[:space:]]*,[[:space:]]*hdr' \
  | sed -E 's/^[[:space:]]*monitor[[:space:]]*=[[:space:]]*//')

if [ "${#hdr_lines[@]}" -eq 0 ]; then
  notify-send -t 2000 "HDR toggle" "no HDR monitor line in monitors.conf" 2>/dev/null
  exit 0
fi

if hyprctl monitors | grep -q 'colorManagementPreset: hdr'; then
  for line in "${hdr_lines[@]}"; do
    # SDR line = name,mode,position,scale only (drop bitdepth/cm/hdr/sdr* fields).
    hyprctl keyword monitor "$(printf '%s' "$line" | cut -d, -f1-4)"
  done
  notify-send -t 2000 "HDR → SDR" "screenshots / screen-share work now" 2>/dev/null
else
  for line in "${hdr_lines[@]}"; do hyprctl keyword monitor "$line"; done
  notify-send -t 2000 "SDR → HDR" "bright; capture disabled" 2>/dev/null
fi
