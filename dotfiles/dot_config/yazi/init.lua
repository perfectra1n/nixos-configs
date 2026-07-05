-- Plugins in ./plugins are nix-managed store symlinks (programs.yazi.plugins in
-- home/common.nix), version-matched to the installed yazi. This file only activates
-- the ones that need a Lua setup() call; keymap-driven plugins (smart-enter, chmod,
-- mount, lazygit, ouch) are wired in keymap.toml/yazi.toml.
require("full-border"):setup()
require("git"):setup()
require("starship"):setup()
