# This is the config.fish
set -Ux FISHCONFIG $HOME/.config/fish/fishconfig.d

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
        if not set -q VSCODE_IPC_HOOK_CLI
            tmux attach; or tmux new-session
        end
    end
end


# Stop the Fish greeting
set -Ux fish_greeting

# Set command color to blue for valid commands
set -U fish_color_command blue

#My PATH variable
fish_add_path -a $HOME/.local/bin
fish_add_path -a /usr/local/sbin
fish_add_path -a /usr/local/bin
fish_add_path -a /usr/sbin
fish_add_path -a /usr/bin
fish_add_path -a /sbin
fish_add_path -a /bin
fish_add_path -a /usr/games
fish_add_path -a /usr/local/games
fish_add_path -a /snap/bin
fish_add_path -a $HOME/.dotnet/tools
fish_add_path -a $HOME/programs/go/bin
fish_add_path -a $HOME/.pyenv/bin
fish_add_path -a $HOME/bin
fish_add_path -a $HOME/.cargo/bin
fish_add_path -a $HOME/.krew/bin


source $FISHCONFIG/fish_functions.fish
source $FISHCONFIG/fish_aliases.fish
source $FISHCONFIG/claude-edge.fish
source $FISHCONFIG/mise.fish

# Secret env vars — decrypted from chezmoi-managed encrypted_private_secrets.fish.age
test -f $FISHCONFIG/secrets.fish; and source $FISHCONFIG/secrets.fish

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

# First, let's check if it's WSL
if test -n "$IS_WSL" 
    or test -n "$WSL_DISTRO_NAME"
    source $FISHCONFIG/os_confs.d/linux-wsl.fish
else
    # Based on the operating system
    # source the specific configuration file
    # force it to be lowercase
    switch (uname | tr '[:upper:]' '[:lower:]')
        case darwin
            # BECAUSE WHY
            alias sed gsed
            source $FISHCONFIG/os_confs.d/osx.fish
        case linux
            # Check if the OS is CentOS or Amazon Linux. amazon_linux.fish is NOT in
            # this (public) repo — work boxes keep a local unmanaged copy, so only
            # source it if it exists.
            if grep -q 'ID="amzn"' /etc/os-release
                test -f $FISHCONFIG/os_confs.d/amazon_linux.fish
                and source $FISHCONFIG/os_confs.d/amazon_linux.fish
            else if grep -q 'ID="centos"' /etc/os-release
                source $FISHCONFIG/os_confs.d/centos.fish
            else
                source $FISHCONFIG/os_confs.d/linux.fish
            end
        case dragonfly freebsd netbsd openbsd 
            source $FISHCONFIG/os_confs.d/bsd.fish
    end
    
end

# Initialize nvm if it exists (must come after Linuxbrew to take precedence)
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

