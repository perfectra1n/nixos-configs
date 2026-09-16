# tmux window title = the running command (the cwd for claude), reset to the cwd at the prompt.
# These are `--on-event` handlers, which is why they're eager here rather than autoloaded from
# functions/: fish only fires handlers that are already registered, it never autoloads one.
# dot_tmux.conf's `automatic-rename` is the fallback for non-fish shells.

# Set tmux window title to the command being executed
function __tmux_preexec --on-event fish_preexec
    if set -q TMUX
        # Extract the command name, skipping any leading VAR=value assignments
        set -l cmd
        for word in (string split ' ' -- $argv[1])
            if not string match -qr '^[A-Za-z_][A-Za-z0-9_]*=' -- $word
                set cmd $word
                break
            end
        end
        test -z "$cmd"; and return
        # For claude code, show the directory name instead of the binary
        set -l cmd_base (basename "$cmd")
        if test "$cmd_base" = claude -o "$cmd_base" = claude-edge
            printf '\ek%s\e\\' (basename $PWD)
        else
            # Send escape sequence to set tmux window name
            printf '\ek%s\e\\' $cmd
        end
    end
end

# Reset window title to directory after command completes
function __tmux_postexec --on-event fish_postexec
    if set -q TMUX
        # Show directory name when back at prompt
        printf '\ek%s\e\\' (basename $PWD)
    end
end
