#!/usr/bin/env bash
# stack-push <l|r|u|d> — make Super+Shift+arrow work in BOTH stacking directions.
#
# Hyprland's movewindoworgroup only ever moves the FOCUSED window INTO a group that
# already sits in <dir>; it can't make a focused STACK swallow the loose window next
# to it (it falls back to a plain move, which is the "I pushed the stack and nothing
# merged" surprise). This wrapper adds that missing direction:
#   - focused window IS a stack  → pull the neighbour in <dir> INTO the stack
#   - focused window is loose     → plain movewindoworgroup (merge into a stack already
#                                   in <dir>, else just move) — unchanged behaviour
dir=$1

cur=$(hyprctl activewindow -j)
addr=$(jq -r '.address' <<<"$cur")
grouped=$(jq -r '.grouped | length' <<<"$cur")

if [ "$grouped" -gt 0 ]; then
    # Focused on a stack: hop focus to the neighbour in <dir>, then merge it back in.
    hyprctl dispatch movefocus "$dir"
    neighbor=$(hyprctl activewindow -j | jq -r '.address')
    if [ -n "$neighbor" ] && [ "$neighbor" != "$addr" ]; then
        # moveintogroup is a no-op unless a group sits in that direction, so fire all
        # four — the stack we just came from is in exactly one of them (same trick as
        # stack-all.sh, so it works whatever the geometry).
        for d in l r u d; do hyprctl dispatch moveintogroup "$d"; done
    fi
    # Re-focus the stack's original front window so the view doesn't jump to the new tab.
    hyprctl dispatch focuswindow "address:$addr"
else
    hyprctl dispatch movewindoworgroup "$dir"
fi
