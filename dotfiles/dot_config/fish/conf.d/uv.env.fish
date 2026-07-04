# Only source if uv's installer actually placed it — absent on NixOS/mise boxes, where an
# unconditional source errors on every shell start. (Path normalized to ~/.local/bin.)
test -f "$HOME/.local/bin/env.fish"; and source "$HOME/.local/bin/env.fish"
