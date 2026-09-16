# Set up function to backup dotfiles
# This assumes that you have a ~/repos/dotfiles directory
function dotfiles
    git --git-dir="$REPO_DIR/dotfiles/.git/" --work-tree=$HOME $argv
end
