# Show what `chezmoi apply` would change in your home dir
function czdiff
    chezmoi diff $argv
end
