function gityeet --description "Reset and clean a git repo."
    git clean -fd
    git reset --hard
end
