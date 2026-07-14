function claude-cred --description 'Swap the Claude Code login in ~/.claude/.credentials.json; save/restore accounts as age-encrypted profiles'
    # ~/.claude/.credentials.json holds TWO independent things: `claudeAiOauth` (the Claude login)
    # and `mcpOAuth` (per-MCP-server tokens — Datadog, memini). Only the former identifies your
    # account, so every write here PATCHES .claudeAiOauth and leaves mcpOAuth byte-for-byte alone.
    # A jq filter that rebuilds the document instead of patching it is how you silently nuke your
    # MCP logins.
    set --local cmd $argv[1]
    set --erase argv[1] 2>/dev/null

    set --local creds (__claude_cred_file)
    set --local base (dirname $creds)
    set --local profiles $base/cred-profiles
    set --local backups $base/cred-backups

    switch "$cmd"
        case show ''
            __claude_cred_require_creds $creds; or return 1
            __claude_cred_show $creds $profiles

        case set-refresh
            __claude_cred_require_creds $creds; or return 1
            __claude_cred_set_refresh $creds $profiles $backups $argv

        case save
            __claude_cred_require_creds $creds; or return 1
            __claude_cred_save $creds $profiles $argv[1]

        case use
            __claude_cred_require_creds $creds; or return 1
            __claude_cred_use $creds $profiles $backups $argv[1]

        case list ls
            __claude_cred_list $profiles $backups

        case undo
            __claude_cred_undo $creds $backups

        case help --help -h
            __claude_cred_help

        case '*'
            echo "claude-cred: unknown command '$cmd'" >&2
            __claude_cred_help >&2
            return 1
    end
end

function __claude_cred_help
    echo "claude-cred — swap the Claude Code login"
    echo
    echo "  show                 active account, redacted (default)"
    echo "  set-refresh [token]  inject a refresh token; prompts silently if omitted"
    echo "  save [name]          snapshot the live claudeAiOauth as a profile (default: active)"
    echo "  use <name>           re-save the outgoing account, then switch to <name>"
    echo "  list                 profiles and recent backups"
    echo "  undo                 restore the most recent auto-backup, verbatim"
end

# ── paths & preconditions ──────────────────────────────────────────────────────────────────────

function __claude_cred_file
    # CLAUDE_CRED_FILE retargets EVERYTHING (creds + profiles + backups all hang off its dirname),
    # so the test suite can drive this against a fixture without touching the real login.
    if set --query CLAUDE_CRED_FILE
        echo $CLAUDE_CRED_FILE
    else
        echo $HOME/.claude/.credentials.json
    end
end

# Test mode also disables the chezmoi round-trip: chezmoi can only manage paths under $HOME, and a
# fixture in /tmp isn't one.
function __claude_cred_chezmoi
    not set --query CLAUDE_CRED_FILE; and command --query chezmoi
end

function __claude_cred_require_creds --argument-names creds
    if not test -f $creds
        echo "claude-cred: $creds not found — run 'claude' and log in first" >&2
        return 1
    end
    if not jq -e . $creds >/dev/null 2>&1
        echo "claude-cred: $creds is not valid JSON — 'claude-cred undo' may recover it" >&2
        return 1
    end
    if not jq -e '.claudeAiOauth' $creds >/dev/null 2>&1
        echo "claude-cred: $creds has no .claudeAiOauth section — not a Claude Code login" >&2
        return 1
    end
end

# ── atomic, never-world-readable write ─────────────────────────────────────────────────────────

function __claude_cred_write --argument-names dest
    # Content arrives on stdin. The temp file is created and chmod'd 0600 BEFORE any content lands
    # in it — a redirect into an existing file doesn't reset its mode — so the token is never
    # world-readable, not even for an instant. mv(1) within one directory is an atomic rename, so
    # a crash mid-write can't leave a half-written (invalid JSON) credentials file behind.
    set --local tmp $dest.tmp.$fish_pid
    rm -f $tmp
    touch $tmp; or return 1
    chmod 600 $tmp; or begin
        rm -f $tmp
        return 1
    end
    cat >$tmp; or begin
        rm -f $tmp
        return 1
    end
    if not jq -e . $tmp >/dev/null 2>&1
        echo "claude-cred: refusing to write invalid JSON to $dest" >&2
        rm -f $tmp
        return 1
    end
    mv -f $tmp $dest
end

function __claude_cred_backup --argument-names creds backups
    mkdir -p -m 700 $backups; or return 1
    set --local dest $backups/(date -u +%Y%m%dT%H%M%SZ).json
    # install(1) creates the destination with the mode already set — no 0644 window.
    install -m 600 $creds $dest; or return 1

    # Undo buffer, not an archive: keep the last 10.
    set --local stale (ls -1t $backups/*.json 2>/dev/null | tail -n +11)
    test (count $stale) -gt 0; and rm -f $stale
    echo $dest
end

# ── guards ─────────────────────────────────────────────────────────────────────────────────────

function __claude_cred_notice_running
    # NOT a blocking guard. An earlier version refused to run while Claude Code was up, on the
    # assumption that a live session would write its in-memory credentials back over the swap. That
    # assumption is wrong, and reading the shipped CC binary says so:
    #
    #   * every credential write goes through `mutate(u => ({...u, claudeAiOauth: {…}}))` — a
    #     read-modify-write against the CURRENT file, so other keys (mcpOAuth) are preserved;
    #   * the invalid-grant path does a compare-and-swap — `if (y.refreshToken !== c) return g` —
    #     i.e. it explicitly declines to write if the on-disk token is no longer the one it held;
    #   * there's cache invalidation plus a path that notices the on-disk accessToken differs from
    #     its in-memory copy and adopts the newer one;
    #   * writes land via renameSync (atomic).
    #
    # That's a store built for concurrent sessions — which it must be, since people routinely run
    # several `claude` processes against this one file. Blocking on it was pure noise.
    #
    # What IS true, and worth saying: a session already running keeps using the OLD account's
    # in-memory access token until it refreshes or restarts. The swap is on disk; the running
    # process hasn't noticed.
    set --query CLAUDE_CRED_FILE; and return 0
    set --local pids (pgrep -x claude 2>/dev/null)
    test (count $pids) -eq 0; and return 0

    echo "claude-cred: note — "(count $pids)" Claude Code session(s) running." >&2
    echo "  They keep using the OLD account until you restart them. Restart to pick this up." >&2
end

# ── active-profile pointer ─────────────────────────────────────────────────────────────────────

function __claude_cred_active --argument-names profiles
    test -f $profiles/.active; and cat $profiles/.active
end

function __claude_cred_set_active --argument-names profiles name
    mkdir -p -m 700 $profiles; or return 1
    if test -z "$name"
        rm -f $profiles/.active
    else
        echo $name >$profiles/.active
    end
end

# Capture the OUTGOING account before we overwrite it. Refresh tokens rotate: the live file may
# hold a NEWER token than the profile we saved when we switched in, and blowing it away would leave
# a dead token in the profile. Every mutation runs this first, so switching is atomic.
function __claude_cred_capture_active --argument-names creds profiles
    set --local active (__claude_cred_active $profiles)
    test -z "$active"; and return 0
    echo "claude-cred: capturing current token into profile '$active' (refresh tokens rotate)"
    __claude_cred_save $creds $profiles $active
end

# ── commands ───────────────────────────────────────────────────────────────────────────────────

function __claude_cred_set_refresh --argument-names creds profiles backups
    set --local token $argv[4]

    if test -n "$token"
        # An inline token is written verbatim into ~/.local/share/fish/fish_history, in plaintext,
        # forever. Supported for scripting, but say so out loud.
        echo "claude-cred: WARNING — that token is now in your fish history." >&2
        echo "  Next time run 'claude-cred set-refresh' with no argument for a silent prompt." >&2
    else
        # NO --local here. `if`/`else` are block scopes in fish, so `read --local` would create the
        # variable INSIDE this block and it would evaporate at `end` — the token reads fine, then
        # vanishes. Bare `read` assigns to the function-scoped `token` declared above.
        read --silent --prompt-str 'New refresh token: ' token
        echo
    end

    set token (string trim -- "$token")
    if test -z "$token"
        echo "claude-cred: no token given" >&2
        return 1
    end
    if not string match --quiet 'sk-ant-ort01-*' -- $token
        # Warn, don't fail: the prefix is Anthropic's to change.
        echo "claude-cred: note — token doesn't look like 'sk-ant-ort01-…'" >&2
    end

    __claude_cred_notice_running
    __claude_cred_capture_active $creds $profiles; or return 1
    set --local backup (__claude_cred_backup $creds $backups); or return 1

    # The old access token must not survive (it stays VALID until its expiry, so leaving it means
    # Claude Code keeps talking to the API as the OLD account) — but it must NOT be blanked either.
    # CC's credential getter is:
    #
    #     let o = read()?.claudeAiOauth; if (o?.accessToken) return o; ... return null
    #
    # so an EMPTY accessToken reads as "no credentials at all" → "Not logged in · Please run /login",
    # and CC never even looks at the refreshToken. (v1 of this function did exactly that. It's the
    # bug you hit.) The dispatch below it is:
    #
    #     if (accessToken && expiresAt && expiresAt > Date.now())  → use the access token
    #     else if (refreshToken && checkAndRefreshOAuthTokenIfNeeded()) → REFRESH   ← we want this
    #
    # expiresAt = 0 is already falsy, so it alone fails the "use it" test and falls through to the
    # refresh branch. The accessToken therefore just has to be NON-EMPTY and dead: a placeholder is
    # both (never sent — the expiry check rejects it first — and if some path ever did send it, a
    # 401 beats silently authenticating as the wrong account).
    jq --arg t "$token" '
        .claudeAiOauth.refreshToken = $t
        | .claudeAiOauth.accessToken = "sk-ant-oat01-PENDING-REFRESH-claude-cred"
        | .claudeAiOauth.expiresAt = 0
        | del(.claudeAiOauth.refreshTokenExpiresAt)
    ' $creds | __claude_cred_write $creds; or return 1

    # The new token belongs to an account we can't name yet, so no profile is active.
    __claude_cred_set_active $profiles ''

    echo "claude-cred: refresh token injected (backup: $backup)"
    echo "  Start Claude Code to mint a fresh access token, then: claude-cred save <name>"
end

function __claude_cred_save --argument-names creds profiles name
    if test -z "$name"
        set name (__claude_cred_active $profiles)
        if test -z "$name"
            echo "claude-cred: no active profile — give a name: claude-cred save <name>" >&2
            return 1
        end
    end
    if not string match --quiet --regex '^[A-Za-z0-9._-]+$' -- $name
        echo "claude-cred: invalid profile name '$name'" >&2
        return 1
    end

    # 0700 so chezmoi records the directory as private_, matching private_dot_kube.
    mkdir -p -m 700 $profiles; or return 1
    set --local dest $profiles/$name.json

    # Profiles store ONLY the claudeAiOauth object. Snapshotting the whole file would mean a later
    # restore also rolled mcpOAuth back to stale Datadog/memini tokens.
    jq '.claudeAiOauth' $creds | __claude_cred_write $dest; or return 1
    __claude_cred_set_active $profiles $name

    if __claude_cred_chezmoi
        # re-add is chezmoi's own mechanism for updating an already-managed file; it preserves the
        # encrypted_ attribute, so we don't have to re-specify --encrypt.
        if chezmoi managed 2>/dev/null | string match --quiet --entire ".claude/cred-profiles/$name.json"
            chezmoi re-add $dest; or return 1
        else
            chezmoi add --encrypt $dest; or return 1
        end
        echo "claude-cred: saved profile '$name' (age-encrypted into the chezmoi source)"

        # The repo is public and this writes a NEW token blob — the human decides when it lands in
        # history, so print the command instead of running it. A brand-new profile is also untracked,
        # and CLAUDE.md's #1 gotcha is that flakes only see git-tracked files.
        # NB: `chezmoi source-path` is .../dotfiles (the .chezmoiroot redirect), NOT the git root.
        set --local src (chezmoi source-path 2>/dev/null)
        set --local repo (git -C $src rev-parse --show-toplevel 2>/dev/null)
        if test -n "$repo"
            # --porcelain covers both "modified" and "untracked" in one shot.
            set --local dirty (git -C $repo status --porcelain -- dotfiles/dot_claude 2>/dev/null)
            if test (count $dirty) -gt 0
                echo "  Uncommitted (ciphertext — safe for the public repo):"
                echo "    git -C $repo add -A dotfiles/dot_claude"
            end
        end
    else
        echo "claude-cred: saved profile '$name' (plaintext — chezmoi round-trip skipped)"
    end
end

function __claude_cred_use --argument-names creds profiles backups name
    if test -z "$name"
        echo "claude-cred: usage: claude-cred use <name>" >&2
        return 1
    end
    set --local src $profiles/$name.json

    # A profile can exist in the chezmoi source but not yet on this box (fresh machine, or a profile
    # saved elsewhere and pulled in via git). Materialize it on demand rather than erroring.
    if not test -f $src; and __claude_cred_chezmoi
        chezmoi apply $src 2>/dev/null
    end
    if not test -f $src
        echo "claude-cred: no profile '$name' (see: claude-cred list)" >&2
        return 1
    end
    if not jq -e '.refreshToken' $src >/dev/null 2>&1
        echo "claude-cred: profile '$name' has no refreshToken — it may be corrupt" >&2
        return 1
    end

    set --local active (__claude_cred_active $profiles)
    if test "$active" = "$name"
        echo "claude-cred: '$name' is already active"
        return 0
    end

    __claude_cred_notice_running
    __claude_cred_capture_active $creds $profiles; or return 1
    set --local backup (__claude_cred_backup $creds $backups); or return 1

    # Splice the profile into .claudeAiOauth — mcpOAuth is left exactly as found.
    #
    # A saved profile normally carries a real accessToken, and it's near-certainly EXPIRED by the
    # time you switch back (~3h life), which is fine: non-empty + past expiry is exactly the state
    # that sends CC down its refresh branch. But a profile saved while a set-refresh was pending
    # could hold an empty one, and CC reads an empty accessToken as "not logged in" rather than
    # "refresh me" — so normalize it to the same non-empty placeholder set-refresh uses.
    jq --slurpfile p $src '
        .claudeAiOauth = $p[0]
        | if (.claudeAiOauth.accessToken // "") == ""
          then .claudeAiOauth.accessToken = "sk-ant-oat01-PENDING-REFRESH-claude-cred"
             | .claudeAiOauth.expiresAt = 0
          else . end
    ' $creds | __claude_cred_write $creds; or return 1
    __claude_cred_set_active $profiles $name

    echo "claude-cred: switched to '$name' (backup: $backup)"
end

function __claude_cred_list --argument-names profiles backups
    set --local active (__claude_cred_active $profiles)

    echo "profiles:"
    set --local found (ls -1 $profiles/*.json 2>/dev/null)
    if test (count $found) -eq 0
        echo "  (none — 'claude-cred save <name>' to create one)"
    else
        for f in $found
            set --local name (basename $f .json)
            if test "$name" = "$active"
                echo "  * $name (active)"
            else
                echo "    $name"
            end
        end
    end

    echo "backups:"
    set --local baks (ls -1t $backups/*.json 2>/dev/null | head -5)
    if test (count $baks) -eq 0
        echo "  (none)"
    else
        for b in $baks
            echo "    "(basename $b)
        end
    end
end

function __claude_cred_undo --argument-names creds backups
    set --local latest (ls -1t $backups/*.json 2>/dev/null | head -1)
    if test -z "$latest"
        echo "claude-cred: no backups to restore" >&2
        return 1
    end
    __claude_cred_notice_running

    # Backups are verbatim whole-file copies (mcpOAuth included) — this is the "oh no" button, so it
    # restores byte-for-byte rather than patching.
    __claude_cred_write $creds <$latest; or return 1
    echo "claude-cred: restored "(basename $latest)
    echo "  NOTE the active-profile pointer is unchanged; check 'claude-cred show'"
end

# ── display ────────────────────────────────────────────────────────────────────────────────────

function __claude_cred_fingerprint --argument-names s
    if test -z "$s"
        echo '(empty)'
        return
    end
    set --local n (string length -- $s)
    if test $n -le 20
        echo "(len $n)"
        return
    end
    echo (string sub --length 14 -- $s)"…"(string sub --start (math $n - 3) -- $s)" (len $n)"
end

function __claude_cred_when --argument-names ms
    if test -z "$ms" -o "$ms" = null
        echo '(absent)'
        return
    end
    if test "$ms" = 0
        echo '0 — forces a refresh on next launch'
        return
    end
    set --local secs (math --scale=0 "$ms / 1000")
    set --local now (date +%s)
    set --local when (date -d @$secs '+%Y-%m-%d %H:%M' 2>/dev/null)
    if test $secs -lt $now
        echo "$when (EXPIRED)"
    else
        echo "$when"
    end
end

function __claude_cred_field --argument-names creds path
    # One field per call. Joining them into a tab-separated line and splitting is tempting, but fish
    # drops empty elements from a command substitution — and an EMPTY accessToken is exactly the
    # state set-refresh leaves behind, so that shortcut would misalign every field after it.
    jq -r "(.claudeAiOauth.$path // \"\") | tostring" $creds 2>/dev/null
end

function __claude_cred_show --argument-names creds profiles
    set --local active (__claude_cred_active $profiles)
    test -z "$active"; and set active '(unnamed — claude-cred save <name>)'

    echo "profile:        $active"
    echo "accessToken:    "(__claude_cred_fingerprint (__claude_cred_field $creds accessToken))
    echo "refreshToken:   "(__claude_cred_fingerprint (__claude_cred_field $creds refreshToken))
    echo "expiresAt:      "(__claude_cred_when (__claude_cred_field $creds expiresAt))
    echo "refreshExpires: "(__claude_cred_when (__claude_cred_field $creds refreshTokenExpiresAt))
    echo "subscription:   "(__claude_cred_field $creds subscriptionType)" / "(__claude_cred_field $creds rateLimitTier)
    echo "mcpOAuth:       "(jq -r '.mcpOAuth // {} | keys | length' $creds)" server(s) — untouched by this tool"
end
