function cpush
    # Scoped: `cpush ~/.config/foo` re-adds just that path. Bare `cpush` pushes only what you
    # already staged with czadd. Deliberately NO blanket `chezmoi re-add` — it recaptures
    # EVERY managed file from $HOME (incl. runtime/stale copies) and silently reverts other
    # machines' changes (that's what produced the bad "Update of dotfiles" commit 56e63d5).
    test (count $argv) -gt 0; and chezmoi re-add $argv
    # Source is now the nixos-configs MONOREPO, so scope add/commit to dotfiles/ — a bare
    # `git add -- .` here would sweep uncommitted Nix changes into a "dotfiles" commit + push them.
    chezmoi git add -- dotfiles/
    chezmoi git commit -- -m "Update of dotfiles through Chezmoi" -- dotfiles/
    chezmoi git push
end
