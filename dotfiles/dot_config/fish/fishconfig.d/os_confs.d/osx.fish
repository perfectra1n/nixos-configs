fish_add_path $HOME/Library/Python/3.8/bin
fish_add_path /opt/homebrew/bin
fish_add_path /opt/homebrew/sbin
fish_add_path /opt/homebrew/share/python
fish_add_path /opt/homebrew/share/python3
fish_add_path $HOME/Library/Python/3.9/bin

function backuphomebrew
    echo "Backing up Homebrew to $HOME/.config/brew/Brewfile now..."
    brew tap Homebrew/bundle
    brew bundle dump --force --file=$HOME/.config/brew/Brewfile
end


#Adding GO to my path
set -Ux GOROOT /opt/homebrew/opt/go/libexec
set -Ux GOPATH ~/.local
fish_add_path $GOROOT/bin
fish_add_path $GOPATH/bin

# Adding the Amazon fun stuff for OSX installs
fish_add_path $HOME/.toolbox/bin
