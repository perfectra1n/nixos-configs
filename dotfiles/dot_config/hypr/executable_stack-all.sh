#!/usr/bin/env bash
# komorebi-style stack-all (toggle):
#   - if the focused window is already in a group → dissolve it (unstack all)
#   - otherwise → group every tiled window in the current workspace into one stack
# Hyprland has no native "stack everything" dispatcher, so we drive it via hyprctl.

# Already stacked? Dissolve the whole group.
if [ "$(hyprctl activewindow -j | jq -r '.grouped | length')" -gt 0 ]; then
    hyprctl dispatch togglegroup
    exit 0
fi

ws=$(hyprctl activeworkspace -j | jq -r '.id')
mapfile -t addrs < <(hyprctl clients -j \
    | jq -r --argjson ws "$ws" \
        '.[] | select(.workspace.id == $ws and .floating == false and .mapped == true) | .address')

# Need at least two tiled windows to stack.
[ "${#addrs[@]}" -lt 2 ] && exit 0

# Make a group from the first window, then pull the rest in. moveintogroup is a
# no-op when there's no group in the given direction, so trying all four directions
# lands each window in the group regardless of where it sits.
hyprctl dispatch focuswindow "address:${addrs[0]}"
hyprctl dispatch togglegroup
for addr in "${addrs[@]:1}"; do
    hyprctl dispatch focuswindow "address:$addr"
    for dir in l r u d; do hyprctl dispatch moveintogroup "$dir"; done
done
hyprctl dispatch focuswindow "address:${addrs[0]}"
