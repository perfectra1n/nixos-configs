# Only source if rustup's installer actually placed it — on NixOS/mise boxes there is no
# ~/.cargo/env.fish, and an unconditional source errors on every shell start.
test -f "$HOME/.cargo/env.fish"; and source "$HOME/.cargo/env.fish"
