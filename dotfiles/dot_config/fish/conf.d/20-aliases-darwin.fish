# macOS-only aliases. BSD userland: `ls` colours with -G (`--color` only exists on newer releases),
# and the sed in functions/ssh.fish uses GNU-only escapes (\+ \?), so `sed` is Homebrew's gsed.
test "$__platform" = darwin; or return

alias ls 'ls -G'
alias sed gsed
