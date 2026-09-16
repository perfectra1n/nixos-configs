function ssh

    if set -q TMUX
        #                   s/[[:space:]]*\(\( | spaces before options
        #     \(-[46AaCfGgKkMNnqsTtVvXxYy]\)\| | option without parameter
        #                     \(-[^[:space:]]* | option
        # \([[:space:]]\+[^[:space:]]*\)\?\)\) | parameter
        #                      [[:space:]]*\)* | spaces between options
        #                        [[:space:]]\+ | spaces before destination
        #                \([^-][^[:space:]]*\) | destination
        #                                   .* | command
        #                                 /\6/ | replace with destination
        tmux rename-window (echo $argv | sed 's/[[:space:]]*\(\(\(-[46AaCfGgKkMNnqsTtVvXxYy]\)\|\(-[^[:space:]]*\([[:space:]]\+[^[:space:]]*\)\?\)\)[[:space:]]*\)*[[:space:]]\+\([^-][^[:space:]]*\).*/\6/')
        command ssh $argv
        tmux set-window-option automatic-rename on 1>/dev/null
    else
        command ssh $argv
    end
end
