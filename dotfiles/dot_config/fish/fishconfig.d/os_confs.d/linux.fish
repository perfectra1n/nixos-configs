#!/usr/bin/fish

# Add the path for Golang
fish_add_path /usr/local/go/bin

# Test to see if Linuxbrew exists
if test -d "/home/linuxbrew/.linuxbrew/bin"
    # This is for Homebrew / Linuxbrew
    fish_add_path /home/linuxbrew/.linuxbrew/bin
    fish_add_path /home/linuxbrew/.linuxbrew/sbin

    # We can also add Fish shell completions from brew
    set -g fish_complete_path /opt/homebrew/share/fish/vendor_completions.d/ $fish_complete_path

    # Since brew can't run as root, we need to have this scuffed alias here
    function brew
        if test (whoami) = "root"
            su - perf3ct -s "/bin/bash" -c "/home/linuxbrew/.linuxbrew/bin/brew $argv"
        else
            /home/linuxbrew/.linuxbrew/bin/brew $argv
        end
    end 

end



#Adding GO to my path
set -Ux GOROOT /usr/local/go
set -Ux GOPATH ~/.local/bin
fish_add_path $GOROOT/bin
fish_add_path $GOPATH/bin

set -Ux EDITOR vim

# NO GDK_SCALE / QT_SCALE_FACTOR here: they MULTIPLY with Hyprland's per-monitor
# fractional scale, so anything relaunched from a terminal (e.g. `dms run`) renders
# double-sized vs the login exec-once path. Set per-invocation if one app needs it.
# Actively erase them: -U scrubs the stale fish_variables copy this config used to
# persist (set -Ux), -g strips a copy inherited from a pre-cleanup parent process.
set -eU GDK_SCALE QT_SCALE_FACTOR 2>/dev/null
set -eg GDK_SCALE QT_SCALE_FACTOR 2>/dev/null
