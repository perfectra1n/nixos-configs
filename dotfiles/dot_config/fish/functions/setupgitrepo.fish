function setupgitrepo
    # Gitea host comes from the encrypted fish env channel (secrets.fish) — guard so a
    # fresh box doesn't silently create a remote named "https://perf3ct/..."
    set -q MAIN_GITEA_HOST; or begin; echo "MAIN_GITEA_HOST unset — run 'mise run secrets:pull'"; return 1; end
    git init .
    touch README.md
    git add .
    git commit -m "Initial commit to setup repo via Fish"
    git remote add origin https://$MAIN_GITEA_HOST/perf3ct/(basename (pwd))
    # HEAD, not a literal branch — follows init.defaultBranch (dot_gitconfig) instead of
    # duplicating the branch name here
    git push --set-upstream origin HEAD
end
