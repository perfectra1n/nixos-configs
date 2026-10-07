#!/usr/bin/env fish

# Kept for muscle memory — org-sync is the forge-aware (GitHub + Gitea) successor.
# Same args, same "org = basename of $PWD" default; see `org-sync --help`.
function gh-org-sync --wraps org-sync --description 'Alias for org-sync'
    org-sync $argv
end
