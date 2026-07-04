-- Plugins live in ./plugins, installed by `ya pkg install` from the package.toml
-- lockfile (bootstrapped by run_onchange_after_install-yazi-plugins.sh). This file
-- only activates the ones that need a Lua setup() call; keymap-driven plugins
-- (smart-enter, chmod, mount, lazygit, ouch) are wired in keymap.toml/yazi.toml.
require("full-border"):setup()
require("git"):setup()
require("starship"):setup()
