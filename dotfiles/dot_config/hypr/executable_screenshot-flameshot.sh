#!/usr/bin/env bash
# PrintScreen → interactive region capture (flameshot), then:
#   1. always keep a LOCAL copy under ~/Pictures/Screenshots (the source of truth),
#   2. put the image on the Wayland clipboard,
#   3. best-effort MIRROR into the Nextcloud VFS, foldered by month.
#
# Why pipe --raw instead of binding `flameshot gui` directly: --raw streams the *accepted*
# PNG to stdout, so this script deterministically owns the bytes (one local file, one
# clipboard copy, one mirror) no matter which toolbar button is clicked. Esc/cancel prints
# nothing → empty file → we bail without writing junk.

pics="${XDG_PICTURES_DIR:-$HOME/Pictures}/Screenshots"
mkdir -p "$pics"

stamp="$(date +%Y-%m-%d_%H-%M-%S)"
local_file="$pics/Screenshot_${stamp}.png"

flameshot gui --raw > "$local_file" 2>/dev/null
if [ ! -s "$local_file" ]; then
    rm -f "$local_file"          # cancelled / empty capture — leave nothing behind
    exit 0
fi

# flameshot --raw does NOT auto-copy; do it ourselves so PrintScreen still fills the clipboard.
wl-copy < "$local_file" 2>/dev/null || true

# Best-effort Nextcloud mirror, organized by month. Fully detached subshell + per-op timeouts:
# the rclone VFS can hang on stat() even while "mounted" if the server is unreachable, so we
# never let it block or fail the capture. Not a live mount → silently skip (the local copy
# already succeeded). See modules/nextcloud-vfs.nix for the mount itself.
nc_base="/mnt/FullerNextcloud/Photos/Screenshots"
(
    mountpoint -q /mnt/FullerNextcloud || exit 0
    month_dir="$nc_base/$(date +%Y)/$(date +%Y-%m)"
    timeout 10 mkdir -p "$month_dir" 2>/dev/null || exit 0
    timeout 30 cp -- "$local_file" "$month_dir/" 2>/dev/null || true
) &
disown
