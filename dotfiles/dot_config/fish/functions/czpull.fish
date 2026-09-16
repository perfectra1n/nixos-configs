# Pull the latest dotfiles from the remote and apply them to THIS machine — the mirror of
# czpush. In git terms: `git pull` (refresh the source repo) + materialize it into your
# home (`chezmoi apply`), in one step. (Same as czupdate; named to match push/pull.)
function czpull
    chezmoi update $argv
end
