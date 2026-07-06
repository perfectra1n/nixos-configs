-- Plugins in ./plugins are nix-managed store symlinks (programs.yazi.plugins in
-- home/common.nix), version-matched to the installed yazi. This file only activates
-- the ones that need a Lua setup() call; keymap-driven plugins (smart-enter, chmod,
-- mount, lazygit, ouch) are wired in keymap.toml/yazi.toml.
require("full-border"):setup()
require("git"):setup()
require("starship"):setup()

-- Custom linemode selected by `linemode = "size_and_mtime"` in yazi.toml: the
-- builtin linemode shows only one field, so pairing size + mtime needs code.
-- Nil-guard both (dir size isn't computed until asked; mtime is optional) so
-- sorting can't raise a Lua runtime error (yazi#3612 / #1918).
function Linemode:size_and_mtime()
	local time = math.floor(self._file.cha.mtime or 0)
	if time == 0 then
		time = ""
	elseif os.date("%Y", time) == os.date("%Y") then
		time = os.date("%b %d %H:%M", time)   -- this year: month day + clock
	else
		time = os.date("%b %d  %Y", time)     -- older: month day + year
	end
	local size = self._file:size()
	return string.format("%s %s", size and ya.readable_size(size) or "-", time)
end
