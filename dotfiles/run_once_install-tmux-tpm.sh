#!/usr/bin/env bash
# Bootstrap TPM (tmux plugin manager) + install the plugins declared in ~/.tmux.conf,
# so they work on a fresh box with no manual prefix+I.
set -eu
dir="$HOME/.tmux/plugins/tpm"
[ -d "$dir" ] || git clone --depth 1 https://github.com/tmux-plugins/tpm "$dir"
"$dir/bin/install_plugins" >/dev/null 2>&1 || true
