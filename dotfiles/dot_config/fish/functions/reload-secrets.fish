function reload-secrets --description 'Reload rotated secret env vars into THIS shell + tmux (after secrets:pull + chezmoi apply)'
    # A child process (mise/chezmoi) can never mutate this already-running shell's env — env is
    # copied at spawn and private. So after rotating a secret, THIS function (which runs IN the
    # shell) is what refreshes the current session; new shells self-heal via config.fish's `set -gx`.
    set --local file $FISHCONFIG/secrets.fish
    if not test -f $file
        echo "reload-secrets: $file not found — run 'chezmoi apply' first" >&2
        return 1
    end

    # Var names are auto-discovered from the file (== the fishenv manifest), so this needs no
    # per-var maintenance. Match the current `set -gx` lines AND any legacy `set -Ux` ones.
    set --local vars (string match -rg '^set -[gU]x +([A-Z0-9_]+)' < $file)
    if test (count $vars) -eq 0
        echo "reload-secrets: no managed vars found in $file" >&2
        return 1
    end

    # Purge stale scopes FIRST. A GLOBAL inherited from tmux (frozen when the server started) shadows
    # any value; a legacy UNIVERSAL copy lingers in fish_variables and resurrects from sibling
    # sessions. Erasing both lets the fresh `set -gx` from `source` below win cleanly. (A universal
    # copy may briefly return from another live session — harmless: the global shadows it, and it
    # dies for good once those sessions close, since nothing writes `set -Ux` anymore.)
    for v in $vars
        set --erase --global $v 2>/dev/null
        set --erase --universal $v 2>/dev/null
    end

    source $file # re-sets every managed var as `set -gx` from the current decrypted file

    # Refresh tmux's server-global env so NEW panes (and any non-fish child tmux spawns directly)
    # inherit the fresh value instead of the one frozen at server start.
    if set --query TMUX
        for v in $vars
            set --query $v; and tmux setenv -g $v $$v
        end
    end

    echo "reload-secrets: reloaded "(count $vars)" secret vars into this shell"(set --query TMUX; and echo " + tmux global env")
    echo "reload-secrets: NOTE apps already running (MCP servers, editors) keep the OLD value until restarted"
end
