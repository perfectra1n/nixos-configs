# Stage a file/dir into the chezmoi source (e.g. czadd ~/.config/fish)
function czadd
    chezmoi add $argv
end
