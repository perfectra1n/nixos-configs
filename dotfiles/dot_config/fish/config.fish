# This is the config.fish
# Aliases, per-OS PATH/env, secrets and tool hooks live in conf.d/ (fish sources that BEFORE this
# file, alphabetically — conf.d/00-platform.fish sets the per-OS guard); reusable commands are
# autoloaded from functions/. This file is what's left: PATH, tmux attach, prompt, keybinds, nvm.

# Multi-dot directory navigation (... -> cd ../.., .... -> cd ../../.., etc.)
function multicd
    echo cd (string repeat -n (math (string length -- $argv[1]) - 1) ../)
end
abbr --add dotdot --regex '^\.\.+$' --function multicd

# Set the REPO_DIR?
set -x REPO_DIR $HOME/repos

# Needed to add this since this variable wasn't set 
# when Tmux was being called, and tmux-mem-cpu-load
# wasn't being executed as a result of the $PATH
# expansion being done in ~/.tmux.conf.
set -Ux TMUX_PLUGIN_MANAGER_PATH $HOME/.tmux/plugins/

# Check if the shell is interactive
if status is-interactive
    if not set -q TMUX
        # The secret env (conf.d/00-secrets.fish, decrypted from the chezmoi .age) has already run —
        # fish sources conf.d/ before this file — so the tmux server spawned here inherits it. That
        # ordering is load-bearing: a fresh top-level shell blocks in `tmux attach` for the life of
        # the session and never reaches anything below, so secrets sourced from THIS file later would
        # leave every tmux pane without them. Vars are `set -gx` (per-session), so each new shell
        # re-reads the current file after a rotation — no sticky universal store to fight.
        # VS Code terminals must NOT auto-attach: its restored/hidden terminals were
        # silently mounting session 0 as a second client, and a second client's
        # terminal-probe replies land in TUIs as keystrokes (the yazi insta-quit
        # saga). The old VSCODE_IPC_HOOK_CLI guard rotted — VS Code stopped setting
        # it — so key on TERM_PROGRAM, the stable identity signal. Deliberate
        # tmux-in-VS-Code goes through `tcode` (grouped session) instead.
        if not test "$TERM_PROGRAM" = vscode
            tmux attach; or tmux new-session
        end
    end
end


# Stop the Fish greeting
set -Ux fish_greeting

# Set command color to blue for valid commands
set -U fish_color_command blue

#My PATH variable
# NOTE: /usr/bin and /bin are deliberately ABSENT. On NixOS they are envfs FUSE mounts that
# resolve from PATH anyway (listing them adds nothing), and having them in PATH makes the envfs
# daemon re-enter its own mount while servicing lookups — an ABBA deadlock that hard-froze the
# desktop under heavy exec load (2026-07-07). If ever re-added, also purge them from the
# persisted universal var fish_user_paths (fish_add_path writes there).
fish_add_path -a $HOME/.local/bin
fish_add_path -a /usr/local/sbin
fish_add_path -a /usr/local/bin
fish_add_path -a /usr/sbin
fish_add_path -a /sbin
fish_add_path -a /usr/games
fish_add_path -a /usr/local/games
fish_add_path -a /snap/bin
fish_add_path -a $HOME/.dotnet/tools
fish_add_path -a $HOME/programs/go/bin
fish_add_path -a $HOME/.pyenv/bin
fish_add_path -a $HOME/bin
fish_add_path -a $HOME/.cargo/bin
fish_add_path -a $HOME/.krew/bin

set -Ux SPACESHIP_HOST_SHOW_FULL "true"
set -Ux SPACESHIP_HOST_SHOW always
starship init fish | source

# This is for https://github.com/PatrickF1/fzf.fish#configuration
# Default bindings but bind Search Directory to Ctrl+F, and Variables to Ctrl+Alt+V
# fish_key_reader
#fzf_configure_bindings --directory=\cf --variables=\e\cV --history=\cr

# Custom ZSH Binds
#Bind the ctrl and arrow key back to how they used to work
#bind -v
bind "\cr" history-incremental-search-backward
bind \c\x00 accept-autosuggestion
#bind "^[[1;5C" forward-word
#bind "^[[1;5D" backward-word
bind \ch backward-kill-word

# Not sure what I did this for to be honest lol
set -Ux XDG_DATA_HOME "$HOME/.local/share"

#set -e DISPLAY

if [ -z $DISPLAY ]
and [ (tty) = /dev/tty1 ]
  startx
end

#OpenVPN tab-autocomplete
#_filedir_xspec openvpn

#Fuck Microsoft
set -Ux DOTNET_CLI_TELEMETRY_OPTOUT 1

#Make the EOL mark NOT a percent symbol
set -Ux PROMPT_EOL_MARK ''

set -U Z_CMD "z"


# For Pyenv
set -Ux PYENV_ROOT $HOME/.pyenv
fish_add_path -a $PYENV_ROOT/bin
#pyenv init - | source

# Generated for envman. Do not edit.
test -s "$HOME/.config/envman/load.fish"; and source "$HOME/.config/envman/load.fish"

# pnpm
set -gx PNPM_HOME "$HOME/.local/share/pnpm"
if not string match -q -- $PNPM_HOME $PATH
  set -gx PATH "$PNPM_HOME" $PATH
end
# pnpm end

# bun
set --export BUN_INSTALL "$HOME/.bun"
set --export PATH $BUN_INSTALL/bin $PATH

# Initialize nvm if it exists (must come after Linuxbrew — conf.d/30-os-linux.fish — to take precedence)
# Check for fisher-installed nvm.fish first
if type -q nvm
    # nvm.fish is installed via fisher
    # Use the default/lts version or whatever is installed (suppress output)
    nvm use --lts >/dev/null 2>/dev/null; or nvm use default >/dev/null 2>/dev/null
else if test -d "$HOME/.nvm"
    # Fall back to standard nvm using bass
    if type -q bass
        bass source "$HOME/.nvm/nvm.sh" --no-use
        nvm use --lts >/dev/null 2>/dev/null; or nvm use default >/dev/null 2>/dev/null
    else
        # If bass isn't available, warn the user
        echo "Warning: nvm found but bass is not installed. Install with: fisher install edc/bass"
    end
end

