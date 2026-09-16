function claude
    # MCP servers live in a chezmoi-managed, ${VAR}-templated file (secrets stay out of the
    # publishable repo and out of ~/.claude.json); `claude` expands the ${VAR}s from the env
    # at launch — they come from secrets.fish. `=` form so the variadic flag takes only the
    # path and doesn't swallow $argv; guarded so a box without the file (fresh chezmoi) still runs.
    set -l mcp_args
    test -f "$HOME/.config/claude/mcp.json"
    and set mcp_args --mcp-config="$HOME/.config/claude/mcp.json"

    # `claude --cpa <name>` routes through a CLIProxyAPI gateway instead of the claude.ai OAuth
    # login (ANTHROPIC_AUTH_TOKEN overrides it entirely, so the two can't be combined — plain
    # `claude` still uses whatever account `claude-cred` last selected). Credentials come from
    # secrets.fish as <NAME>_CPA_BASE_URL/_CPA_TOKEN. Model ids are NOT secret, so they live here
    # in the open where they're greppable and fixable in one place.
    set -l cpa_env
    set -l i (contains -i -- --cpa $argv)
    if test -n "$i"
        set -l name $argv[(math $i + 1)]
        set -l base_var (string upper -- "$name")_CPA_BASE_URL
        set -l token_var (string upper -- "$name")_CPA_TOKEN
        # Fail loudly on a bad/missing name. Falling through to the OAuth login would hand you a
        # perfectly working session billed to the WRONG account, and Claude Code surfaces no hint
        # of which auth source won — so the mistake would be invisible until the bill arrives.
        if test -z "$name"; or not set -q $base_var; or not set -q $token_var
            echo "claude: unknown --cpa profile '$name'" >&2
            echo "claude: available profiles: "(__claude_cpa_profiles | string join ', ') >&2
            return 1
        end
        # `env` rather than `set -gx`: the token reaches only this process tree, not every
        # command you run afterwards in this shell.
        set cpa_env ANTHROPIC_BASE_URL=$$base_var ANTHROPIC_AUTH_TOKEN=$$token_var \
            ANTHROPIC_DEFAULT_OPUS_MODEL=claude-opus-5 \
            ANTHROPIC_DEFAULT_SONNET_MODEL=claude-sonnet-5 \
            ANTHROPIC_DEFAULT_HAIKU_MODEL=claude-haiku-4-5-20251001
        # Drop the flag and its value so they never reach the binary. Higher index first —
        # removing $i would shift the value down into its slot.
        set -e argv[(math $i + 1)]
        set -e argv[$i]
    end

    if set -q cpa_env[1]
        # `env` resolves `claude` from PATH to the real binary, so this can't recurse into
        # this function the way a bare `claude` would.
        IS_SANDBOX=1 env $cpa_env claude $mcp_args $argv
    else
        IS_SANDBOX=1 command claude $mcp_args $argv
    end
end
