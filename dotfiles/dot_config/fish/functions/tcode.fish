# Attach from VS Code (or any second terminal) WITHOUT mirroring session 0's
# current window. Two clients on one window both answer a TUI's terminal
# probes, and tmux feeds the stray replies back to the app as keystrokes —
# yazi quits instantly on the `q` in a cursor-style report, or opens random
# search boxes ("freaks out"). A grouped session shares all the windows but
# keeps its own current-window pointer, so each client only ever has one
# responder; destroy-unattached reaps it again when the client disconnects.
function tcode --description "attach to tmux as an independent grouped session (for VS Code etc.)"
	if set -q TMUX
		echo "already inside tmux" >&2
		return 1
	end
	tmux new-session -A -s code -t 0 \; set-option destroy-unattached on
end
