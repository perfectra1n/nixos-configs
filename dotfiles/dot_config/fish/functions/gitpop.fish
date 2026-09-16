function gitpop --description "fast way to pop a git stash by name"
    if test (count $argv) -eq 0
        echo "Usage: gitpop <stash-name>"
        return 1
    end
    git stash pop stash^{/"$argv"}
end
