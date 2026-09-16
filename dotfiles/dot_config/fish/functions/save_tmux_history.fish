function save_tmux_history
    set -l file $argv[1]
    if test -z "$file"
        echo "Please provide a filename."
        return 1
    end
    if not type tmux > /dev/null
        echo "Tmux is not installed."
        return 1
    end
    if not tmux list-panes > /dev/null
        echo "No active tmux sessions."
        return 1
    end

    tmux capture-pane -pS - > $file
    echo "Tmux history saved to $file."
end
