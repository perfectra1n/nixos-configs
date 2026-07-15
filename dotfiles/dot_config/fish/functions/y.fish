# Official yazi shell wrapper: quitting yazi cd's the shell to wherever you
# navigated (`q` keeps the cwd, `Q` quits without changing it).
function y
	set tmp (mktemp -t "yazi-cwd.XXXXXX")
	# tmux mirrors a pane to every attached client, but yazi picks ONE image
	# protocol — kitty graphics render only in kitty, so a mixed attach (kitty +
	# VS Code's xterm.js terminal) shows previews as U+10EEEE placeholder salad
	# in the non-kitty view, and both clients answering yazi's terminal probes
	# spills stray escapes at the prompt. When any non-kitty client is watching,
	# hide the emulator identity (yazi has no adapter knob; env-spoofing is its
	# documented escape hatch) so it falls back to chafa text mosaics — plain SGR
	# text every client renders identically. Kitty-only attaches keep real kitty
	# graphics. Gated on chafa so a host that hasn't rebuilt yet degrades to the
	# old behavior instead of losing previews entirely.
	set -l clients (tmux list-clients -F '#{client_termname}' 2>/dev/null)
	if set -q TMUX; and command -q chafa; and string match -qv 'xterm-kitty' -- $clients
		env -u TMUX -u TMUX_PANE -u KITTY_WINDOW_ID -u KITTY_PID -u KITTY_PUBLIC_KEY \
			-u KITTY_INSTALLATION_DIR -u KITTY_SHELL_INTEGRATION \
			-u WAYLAND_DISPLAY -u DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE \
			TERM_PROGRAM= XDG_SESSION_TYPE=tty yazi $argv --cwd-file="$tmp"
	else
		command yazi $argv --cwd-file="$tmp"
	end
	if read -z cwd < "$tmp"; and [ -n "$cwd" ]; and [ "$cwd" != "$PWD" ]
		builtin cd -- "$cwd"
	end
	rm -f -- "$tmp"
end
