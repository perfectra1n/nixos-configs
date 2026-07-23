function claude-cred --description 'Swap the Claude Code login in ~/.claude/.credentials.json; email-verified age-encrypted profiles'
    # ~/.claude/.credentials.json holds TWO independent things: `claudeAiOauth` (the Claude login)
    # and `mcpOAuth` (per-MCP-server tokens — Datadog, memini). Only the former identifies your
    # account, so every write here PATCHES .claudeAiOauth and leaves mcpOAuth byte-for-byte alone.
    # A jq filter that rebuilds the document instead of patching it is how you silently nuke your
    # MCP logins.
    #
    # Identity model (since 2026-07-23): the account EMAIL, verified against Anthropic's own
    # oauth/profile endpoint, is the source of truth for which profile a token belongs to. The
    # `.active` pointer file survives only as an offline hint / prompt default — trusting it
    # blindly is how the 2026-07-22 incident cross-pollinated the profiles.
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

        case whoami
            __claude_cred_require_creds $creds; or return 1
            __claude_cred_whoami $creds

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

        case doctor
            __claude_cred_require_creds $creds; or return 1
            __claude_cred_doctor $creds $profiles

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
    echo "  show                 active account + verified identity, redacted (default)"
    echo "  whoami               live account email via the Anthropic profile endpoint"
    echo "  set-refresh [token]  log in from a refresh token; exchanges + names the profile when online"
    echo "  save [name]          snapshot the live login as a profile (name auto-resolved by email)"
    echo "  use <name>           capture the outgoing account (verified), then switch to <name>"
    echo "  list                 profiles with their emails, and recent backups"
    echo "  doctor               audit profiles vs the live login — read-only"
    echo "  undo                 restore the most recent auto-backup, verbatim"
    echo
    echo "  env: CLAUDE_CRED_OFFLINE=1 skips all network use (prompts instead of verifying)"
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

# ── network: identity + token exchange ─────────────────────────────────────────────────────────

function __claude_cred_placeholder
    # Non-empty but dead: CC treats an EMPTY accessToken as "not logged in" and never reaches its
    # refresh branch, so every path that can't supply a real token writes THIS instead. One source
    # of truth — show/doctor/capture all key off it to recognize a pending-refresh state.
    echo sk-ant-oat01-PENDING-REFRESH-claude-cred
end

function __claude_cred_offline
    # CLAUDE_CRED_FILE (fixture mode) forces offline so tests are deterministic and exercise every
    # prompt/fallback path; CLAUDE_CRED_OFFLINE is the airplane-mode switch for live use.
    set --query CLAUDE_CRED_FILE; or set --query CLAUDE_CRED_OFFLINE
end

function __claude_cred_identity --argument-names token
    # Resolve a token to its account via Anthropic's oauth/profile endpoint (the same one the CC
    # binary talks to). rc: 0 = one-line identity JSON on stdout · 1 = token rejected (expired or
    # revoked, or a placeholder we never send) · 2 = network trouble · 3 = offline mode.
    __claude_cred_offline; and return 3
    if test -z "$token"; or test "$token" = (__claude_cred_placeholder)
        return 1
    end

    # The token travels via `curl --config -` on stdin, never argv: printf is a fish builtin, so
    # no /proc/*/cmdline ever holds the Authorization header.
    set --local raw (printf 'url = "https://api.anthropic.com/api/oauth/profile"\nheader = "Authorization: Bearer %s"\nheader = "anthropic-beta: oauth-2025-04-20"\n' $token \
        | curl --silent --fail --max-time 10 --config - 2>/dev/null)
    # $status after a `set` with a command substitution is the substitution's status — here the
    # pipeline's last command, curl. --fail maps HTTP >= 400 to exit 22.
    set --local rc $status
    test $rc -eq 22; and return 1
    test $rc -ne 0; and return 2

    # Compact to ONE line: fish command substitutions drop empty lines, so a pretty-printed JSON
    # answer would shear apart in callers (same lore as __claude_cred_field).
    printf '%s' "$raw" | jq -ce '{
        email: (.account.email // ""),
        uuid: (.account.uuid // ""),
        org: (.organization.name // ""),
        plan: (if .account.has_claude_max then "max" elif .account.has_claude_pro then "pro" else "" end)
    }' 2>/dev/null
    or return 2
end

function __claude_cred_oauth_refresh --argument-names token
    # Mint fresh credentials from a refresh token — the same exchange, against the same public
    # client_id, that the CC binary performs on launch. Unofficial endpoint: callers MUST tolerate
    # failure and fall back to the placeholder mechanism. The body goes via --json @- (stdin), so
    # the token never appears on curl's argv.
    #
    # On failure this sets $__claude_cred_exchange_reason to a human-actionable string. That
    # distinction is load-bearing: a 429 means "retry in a few minutes" while a 400/invalid_grant
    # means "this token is dead, reseed it" — opposite user actions. So NO --fail here (it would
    # discard the error body); instead we read the body AND the HTTP code and classify.
    set --global __claude_cred_exchange_reason 'token exchange failed'
    if __claude_cred_offline
        set --global __claude_cred_exchange_reason 'offline mode — exchange skipped'
        return 1
    end

    # -w appends the HTTP status on its own line after the body. Command substitution splits on
    # newlines and drops empties, so the (compact) JSON body is $out[1] and the code is $out[-1].
    set --local out (jq -cn --arg rt "$token" '{grant_type: "refresh_token", refresh_token: $rt, client_id: "9d1c250a-e61b-44d9-88ed-5944d1962f5e"}' \
        | curl --silent --max-time 30 -w '\n%{http_code}' --json @- https://console.anthropic.com/v1/oauth/token 2>/dev/null)
    if test $status -ne 0; or test (count $out) -eq 0
        set --global __claude_cred_exchange_reason 'endpoint unreachable (network)'
        return 1
    end
    set --local code $out[-1]
    set --local body (string join '' -- $out[1..-2])
    set --local etype (printf '%s' "$body" | jq -r '.error.type // ""' 2>/dev/null)

    if test "$code" = 200
        # A 200 without the fields we need is still a failure — never write partial creds from it.
        if printf '%s' "$body" | jq -ce 'select((.access_token // "") != "" and (.expires_in // 0) > 0)' 2>/dev/null
            return 0
        end
        set --global __claude_cred_exchange_reason 'endpoint returned 200 but no usable tokens (response shape changed?)'
        return 1
    end
    switch $code
        case 429
            set --global __claude_cred_exchange_reason 'rate limited (HTTP 429) — wait a few minutes and retry'
        case 400 401 403
            set --local extra ''
            test -n "$etype"; and set extra " $etype"
            set --global __claude_cred_exchange_reason "refresh token rejected (HTTP $code$extra) — it's dead; reseed from the source machine"
        case '*'
            set --local extra ''
            test -n "$etype"; and set extra " ($etype)"
            set --global __claude_cred_exchange_reason "exchange failed (HTTP $code$extra)"
    end
    return 1
end

function __claude_cred_prompt --argument-names prompt_str prefill
    # Every interactive question funnels through here so non-interactive callers can never hang:
    # no TTY → rc 1 immediately, and the caller decides between skip-with-warning and hard error.
    # CLAUDE_CRED_ASSUME_TTY lets the offline test suite pipe answers in.
    if not isatty stdin; and not set --query CLAUDE_CRED_ASSUME_TTY
        return 1
    end
    # --command prefills the EDITABLE buffer: Enter accepts the suggestion, wiping it declines.
    # That's what lets "default offered" and "empty = skip" coexist without ambiguity.
    #
    # Declared BEFORE read: `read --local` inside a block would evaporate at `end` (fish blocks
    # are scopes) — same gotcha as set-refresh's token read.
    set --local answer
    read --prompt-str "$prompt_str" --command "$prefill" answer; or return 1
    string trim -- "$answer"
    # string trim exits 1 when it had nothing to trim — that's "no transformation", not failure.
    return 0
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

# ── profile files: v1/v2 bridge ────────────────────────────────────────────────────────────────
# v2 wraps the oauth object in {version, email, accountUuid, organization, savedAt, claudeAiOauth};
# v1 IS the bare oauth object. Detection is structural (has("claudeAiOauth")) — never trust a
# version field to describe a shape it sits inside.

function __claude_cred_profile_oauth --argument-names file
    jq 'if has("claudeAiOauth") then .claudeAiOauth else . end' $file 2>/dev/null
end

function __claude_cred_profile_email --argument-names file
    jq -r 'if has("claudeAiOauth") then (.email // "") else "" end' $file 2>/dev/null
end

function __claude_cred_find_profile_by_email --argument-names profiles email
    test -z "$email"; and return 1
    for f in $profiles/*.json
        set --local e (__claude_cred_profile_email $f)
        test "$e" = "$email"; and basename $f .json
    end
end

# ── outgoing capture ───────────────────────────────────────────────────────────────────────────

function __claude_cred_capture_outgoing --argument-names creds profiles
    # Capture the OUTGOING account before a swap overwrites it — refresh tokens rotate, so the live
    # file may hold a NEWER token than the profile does, and losing it leaves a dead profile.
    #
    # This replaces capture_active, which trusted the LOCAL .active pointer to know WHICH account
    # is live. That's the 2026-07-22 incident: a stale pointer routed one account's token into
    # another account's profile. Identity now comes from the token itself (oauth/profile endpoint);
    # .active is only ever offered as a prompt DEFAULT, never silently written to.
    #
    # The resolved profile name comes back in a global rather than stdout: __claude_cred_save
    # prints multi-line guidance (the git-add hint) that a command-substitution capture would
    # swallow. Callers read $__claude_cred_outgoing and erase it.
    set --global __claude_cred_outgoing ''

    set --local at (__claude_cred_field $creds accessToken)
    # Empty or placeholder = a set-refresh is pending; nothing identifiable is live to capture.
    if test -z "$at"; or test "$at" = (__claude_cred_placeholder)
        return 0
    end

    set --local identity (__claude_cred_identity $at)
    set --local rc $status
    set --local name ''

    if test $rc -eq 0
        set --local email (printf '%s' $identity | jq -r '.email // ""')
        set --local matches (__claude_cred_find_profile_by_email $profiles $email)
        if test (count $matches) -eq 1
            # Verified: the token says whose it is, the profile agrees — safe to save silently.
            echo "claude-cred: capturing outgoing login ($email) into profile '$matches[1]' (refresh tokens rotate)"
            set name $matches[1]
        else if test (count $matches) -gt 1
            # Two profiles claiming one email is user-made ambiguity; make them choose.
            set --local default (__claude_cred_active $profiles)
            contains -- "$default" $matches; or set default $matches[1]
            set name (__claude_cred_prompt "save outgoing login ($email) to which of [$matches]? (empty = skip) " "$default")
            or begin
                echo "claude-cred: warning — outgoing login ($email) NOT saved (several profiles match, not a TTY)" >&2
                return 0
            end
        else
            set --local suggestion (string replace --regex '@.*$' '' -- $email | string replace --regex --all '[^A-Za-z0-9._-]' '')
            set name (__claude_cred_prompt "save outgoing login ($email) as? (empty = skip) " "$suggestion")
            or begin
                echo "claude-cred: warning — outgoing login ($email) NOT saved (no matching profile, not a TTY)" >&2
                return 0
            end
        end
        test -z "$name"; and return 0
        __claude_cred_save $creds $profiles $name $identity; or return 1
    else
        # Can't verify (expired token / offline). .active is offered as a DEFAULT the human
        # confirms — the one thing the old code did silently, and the heart of the incident.
        set --local default (__claude_cred_active $profiles)
        set name (__claude_cred_prompt "save outgoing login (unverified) as? (empty = skip) " "$default")
        or begin
            echo "claude-cred: warning — outgoing login NOT saved (can't verify identity, not a TTY)" >&2
            return 0
        end
        test -z "$name"; and return 0
        __claude_cred_save $creds $profiles $name; or return 1
    end

    set --global __claude_cred_outgoing $name
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
        if not isatty stdin; and not set --query CLAUDE_CRED_ASSUME_TTY
            echo "claude-cred: set-refresh needs a token argument when stdin is not a TTY" >&2
            return 1
        end
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

    # Hard validation BEFORE any side effect. The 2026-07-22 incident started exactly here: an
    # access token was accepted with only a warning, then the pre-write capture scrambled the
    # profiles before the bad token even landed. The prefix is Anthropic's to change — but
    # re-editing this guard beats accepting a wrong-type token ever again.
    if string match --quiet 'sk-ant-oat01-*' -- $token
        echo "claude-cred: that's an ACCESS token (sk-ant-oat01-…), not a refresh token." >&2
        echo "  Copy the refreshToken field (sk-ant-ort01-…) from the source machine's" >&2
        echo "  ~/.claude/.credentials.json instead." >&2
        return 1
    end
    if not string match --quiet 'sk-ant-ort01-*' -- $token
        echo "claude-cred: refusing — that doesn't look like a refresh token (sk-ant-ort01-…)." >&2
        return 1
    end

    __claude_cred_notice_running
    __claude_cred_capture_outgoing $creds $profiles; or return 1
    set --local backup (__claude_cred_backup $creds $backups); or return 1

    set --local minted (__claude_cred_oauth_refresh $token)
    if test $status -eq 0
        __claude_cred_set_refresh_online $creds $profiles $backups $token "$minted" $backup
    else
        # __claude_cred_oauth_refresh classified the failure (429 vs dead token vs network) into
        # this global — thread it through so the user knows whether to retry or reseed.
        __claude_cred_set_refresh_fallback $creds $profiles $token $backup "$__claude_cred_exchange_reason"
    end
end

function __claude_cred_set_refresh_online --argument-names creds profiles backups injected minted backup
    set --local at (printf '%s' $minted | jq -r '.access_token')
    # The response's refresh_token is the ROTATED one — the injected token may be retired
    # server-side the instant the exchange succeeds, so writing it would store a dead token.
    # OAuth also allows omitting refresh_token ("old one still valid"); only then does the
    # injected token remain the right thing to keep.
    set --local rt (printf '%s' $minted | jq -r '.refresh_token // ""')
    test -z "$rt"; and set rt $injected
    set --local expires_in (printf '%s' $minted | jq -r '.expires_in')
    set --local now_s (date +%s)
    set --local expires_at (math "($now_s + $expires_in) * 1000")
    set --local scopes (printf '%s' $minted | jq -r '.scope // ""')

    set --local identity (__claude_cred_identity $at)
    set --local idrc $status
    set --local plan ''
    test $idrc -eq 0; and set plan (printf '%s' $identity | jq -r '.plan // ""')

    # Full real credentials — no placeholder needed: CC finds an unexpired access token and just
    # works. refreshTokenExpiresAt belonged to the OLD account's clock; CC repopulates it (and
    # rateLimitTier, which we can't know here) on its own next refresh.
    jq --arg at "$at" --arg rt "$rt" --argjson exp $expires_at --arg sub "$plan" --arg scopes "$scopes" '
        .claudeAiOauth.accessToken = $at
        | .claudeAiOauth.refreshToken = $rt
        | .claudeAiOauth.expiresAt = $exp
        | del(.claudeAiOauth.refreshTokenExpiresAt)
        | (if $sub != "" then .claudeAiOauth.subscriptionType = $sub else . end)
        | (if $scopes != "" then .claudeAiOauth.scopes = ($scopes | split(" ")) else . end)
    ' $creds | __claude_cred_write $creds
    or begin
        __claude_cred_rescue $backups $at $rt $expires_at
        return 1
    end

    echo "claude-cred: logged in — token exchanged for a live access token (backup: $backup)"

    if test $idrc -eq 0
        set --local email (printf '%s' $identity | jq -r '.email // ""')
        # save with an empty name + a known identity: matches the email to an existing profile, or
        # prompts for a new name — the exact "tie the name to the email" moment.
        if __claude_cred_save $creds $profiles '' $identity
            return 0
        end
        __claude_cred_set_active $profiles ''
        echo "claude-cred: logged in as $email — profile not saved; run: claude-cred save <name>"
    else
        # Exchange worked but the identity lookup blipped — rare, but don't guess a name.
        __claude_cred_set_active $profiles ''
        echo "claude-cred: identity lookup failed right after login — run: claude-cred save <name>"
    end
end

function __claude_cred_rescue --argument-names backups at rt expires_at
    # The exchange succeeded but the creds write didn't: the ROTATED refresh token exists only in
    # this process, and losing it can strand the account. Park it in a 0600 file. The extension is
    # deliberately NOT .json: undo and the backup sweep glob $backups/*.json, and a rescue fragment
    # (no mcpOAuth) must never be swept away — or worse, restored over the real file by undo.
    set --local dest $backups/rescue-(date -u +%Y%m%dT%H%M%SZ).json.rescue
    if jq -n --arg at "$at" --arg rt "$rt" --argjson exp $expires_at \
            '{claudeAiOauth: {accessToken: $at, refreshToken: $rt, expiresAt: $exp}}' \
            | __claude_cred_write $dest
        echo "claude-cred: creds write FAILED after a successful token exchange." >&2
        echo "  The minted (rotated) tokens are parked in: $dest" >&2
    else
        # Printing to a TTY is the very last resort — stderr is not fish history, and losing the
        # only copy of a rotated refresh token is worse than showing it.
        echo "claude-cred: creds write AND rescue write failed. SAVE THIS NOW — rotated refresh token:" >&2
        echo "  $rt" >&2
    end
end

function __claude_cred_set_refresh_fallback --argument-names creds profiles injected backup reason
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
    jq --arg t "$injected" --arg ph (__claude_cred_placeholder) '
        .claudeAiOauth.refreshToken = $t
        | .claudeAiOauth.accessToken = $ph
        | .claudeAiOauth.expiresAt = 0
        | del(.claudeAiOauth.refreshTokenExpiresAt)
    ' $creds | __claude_cred_write $creds; or return 1

    # The new token belongs to an account we can't name yet, so no profile is active.
    __claude_cred_set_active $profiles ''

    echo "claude-cred: refresh token injected — $reason (backup: $backup)"
    echo "  Start Claude Code to mint a fresh access token, then: claude-cred save"
end

function __claude_cred_save --argument-names creds profiles name identity_json
    # Resolve identity once: callers that already fetched it pass it through (4th arg), so a
    # capture→save chain costs a single network round-trip and offline tests stay deterministic.
    if test -z "$identity_json"
        set identity_json (__claude_cred_identity (__claude_cred_field $creds accessToken))
        or set identity_json ''
    end
    set --local email ''
    set --local uuid ''
    set --local org ''
    if test -n "$identity_json"
        set email (printf '%s' $identity_json | jq -r '.email // ""')
        set uuid (printf '%s' $identity_json | jq -r '.uuid // ""')
        set org (printf '%s' $identity_json | jq -r '.org // ""')
    end

    if test -z "$name"
        if test -n "$email"
            set --local matches (__claude_cred_find_profile_by_email $profiles $email)
            if test (count $matches) -eq 1
                # Verified email → exactly one profile: no prompt needed. Forking a second profile
                # of the same account requires an explicit name.
                set name $matches[1]
                echo "claude-cred: live login is $email — saving to profile '$name'"
            else
                set --local suggestion (string replace --regex '@.*$' '' -- $email | string replace --regex --all '[^A-Za-z0-9._-]' '')
                test (count $matches) -gt 1; and set suggestion $matches[1]
                set name (__claude_cred_prompt "save live login ($email) as? " "$suggestion")
                or begin
                    echo "claude-cred: give a name: claude-cred save <name>" >&2
                    return 1
                end
            end
        else
            set --local default (__claude_cred_active $profiles)
            set name (__claude_cred_prompt "save live login (unverified) as? " "$default")
            or begin
                echo "claude-cred: no verifiable identity — give a name: claude-cred save <name>" >&2
                return 1
            end
        end
        if test -z "$name"
            echo "claude-cred: no name given" >&2
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

    # Anti-pollution guard: never overwrite a profile that RECORDS a different owner without the
    # human confirming. (v1 profiles record nothing, so the guard can't fire on them.)
    if test -n "$email"; and test -f $dest
        set --local stored (__claude_cred_profile_email $dest)
        if test -n "$stored"; and test "$stored" != "$email"
            set --local answer (__claude_cred_prompt "profile '$name' holds $stored but the live login is $email — overwrite? [y/N] " '')
            or begin
                echo "claude-cred: refusing to overwrite '$name' ($stored) with $email non-interactively" >&2
                return 1
            end
            string match --quiet --regex '^[Yy]' -- "$answer"; or begin
                echo "claude-cred: not overwriting '$name'" >&2
                return 1
            end
        end
    end

    # Identity is sticky: an offline re-save of a v2 profile keeps its recorded owner (doctor
    # catches drift) — going backwards to "unknown" would just destroy information.
    if test -z "$email"; and test -f $dest
        set email (__claude_cred_profile_email $dest)
        set uuid (jq -r 'if has("claudeAiOauth") then (.accountUuid // "") else "" end' $dest 2>/dev/null)
        set org (jq -r 'if has("claudeAiOauth") then (.organization // "") else "" end' $dest 2>/dev/null)
    end

    # Profiles store the claudeAiOauth object plus identity metadata (v2) — never the whole creds
    # file, so a later restore can't roll mcpOAuth back to stale Datadog/memini tokens. Emails live
    # only here (age-encrypted in the repo) and in local 0600 files — never plaintext in git.
    jq --arg email "$email" --arg uuid "$uuid" --arg org "$org" --arg now (date -u +%Y-%m-%dT%H:%M:%SZ) '
        {version: 2,
         email: (if $email == "" then null else $email end),
         accountUuid: (if $uuid == "" then null else $uuid end),
         organization: (if $org == "" then null else $org end),
         savedAt: $now,
         claudeAiOauth: .claudeAiOauth}
    ' $creds | __claude_cred_write $dest; or return 1
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
    if not jq -e 'if has("claudeAiOauth") then .claudeAiOauth.refreshToken else .refreshToken end' $src >/dev/null 2>&1
        echo "claude-cred: profile '$name' has no refreshToken — it may be corrupt" >&2
        return 1
    end

    # Offline, .active is the only oracle — keep the cheap early-return but say it's unverified.
    # Online, identity decides below: a stale pointer must not block a real switch.
    set --local active (__claude_cred_active $profiles)
    if __claude_cred_offline; and test "$active" = "$name"
        echo "claude-cred: '$name' is already active (per .active — can't verify offline)"
        return 0
    end

    __claude_cred_notice_running
    __claude_cred_capture_outgoing $creds $profiles; or return 1
    set --local outgoing "$__claude_cred_outgoing"
    set --erase __claude_cred_outgoing 2>/dev/null
    if test -n "$outgoing"; and test "$outgoing" = "$name"
        # The live file holds this account's NEWEST (rotated) token; splicing the profile's older
        # copy back over it would be a downgrade. Capture already refreshed the profile from live.
        echo "claude-cred: '$name' is already the live account (profile refreshed from live creds)"
        __claude_cred_set_active $profiles $name
        return 0
    end
    set --local backup (__claude_cred_backup $creds $backups); or return 1

    # Splice the profile into .claudeAiOauth — mcpOAuth is left exactly as found.
    #
    # A saved profile normally carries a real accessToken, and it's near-certainly EXPIRED by the
    # time you switch back (~3h life), which is fine: non-empty + past expiry is exactly the state
    # that sends CC down its refresh branch. But a profile saved while a set-refresh was pending
    # could hold an empty one, and CC reads an empty accessToken as "not logged in" rather than
    # "refresh me" — so normalize it to the same non-empty placeholder set-refresh uses.
    jq --slurpfile p $src --arg ph (__claude_cred_placeholder) '
        .claudeAiOauth = (if ($p[0] | has("claudeAiOauth")) then $p[0].claudeAiOauth else $p[0] end)
        | if (.claudeAiOauth.accessToken // "") == ""
          then .claudeAiOauth.accessToken = $ph
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
            set --local email (__claude_cred_profile_email $f)
            test -z "$email"; and set email '(no identity — re-save to record it)'
            set --local marker '  '
            test "$name" = "$active"; and set marker '* '
            printf '  %s%-12s %s\n' $marker $name $email
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

function __claude_cred_whoami --argument-names creds
    set --local identity (__claude_cred_identity (__claude_cred_field $creds accessToken))
    set --local rc $status
    if test $rc -eq 0
        printf '%s' $identity | jq -r '.email + (if .org != "" then "\norg:  " + .org else "" end) + (if .plan != "" then "\nplan: " + .plan else "" end) + "\nuuid: " + .uuid'
        return 0
    end
    switch $rc
        case 1
            echo "claude-cred: live access token rejected — expired, revoked, or a pending refresh" >&2
        case 2
            echo "claude-cred: can't reach the Anthropic API (network)" >&2
        case 3
            echo "claude-cred: offline mode — identity lookup skipped" >&2
    end
    return $rc
end

function __claude_cred_doctor --argument-names creds profiles
    # Strictly READ-ONLY: doctor never writes anything, so it's always safe to run. The repairs it
    # suggests are the human's to make.
    set --local now_ms (math (date +%s)" * 1000")
    set --local active (__claude_cred_active $profiles)

    set --local live_email ''
    set --local identity (__claude_cred_identity (__claude_cred_field $creds accessToken))
    test $status -eq 0; and set live_email (printf '%s' $identity | jq -r '.email // ""')
    echo "live login:  "(__claude_cred_account_line $creds)

    echo "profiles:"
    set --local live_match ''
    set --local any 0
    for f in $profiles/*.json
        set any 1
        set --local name (basename $f .json)
        set --local fmt v1
        jq -e 'has("claudeAiOauth")' $f >/dev/null 2>&1; and set fmt v2
        set --local email (__claude_cred_profile_email $f)
        set --local saved (jq -r 'if has("claudeAiOauth") then (.savedAt // "") else "" end' $f 2>/dev/null)
        set --local mode (stat -c %a $f 2>/dev/null)
        set --local prt (jq -r 'if has("claudeAiOauth") then .claudeAiOauth else . end | .refreshToken // ""' $f 2>/dev/null)
        set --local pat (jq -r 'if has("claudeAiOauth") then .claudeAiOauth else . end | .accessToken // ""' $f 2>/dev/null)
        set --local pexp (jq -r 'if has("claudeAiOauth") then .claudeAiOauth else . end | .expiresAt // 0' $f 2>/dev/null)

        set --local idlabel '(no identity recorded)'
        test -n "$email"; and set idlabel $email
        set --local when ''
        test -n "$saved"; and set when "  saved $saved"
        echo "  $name: $fmt  $idlabel$when"

        test -z "$prt"; and echo "    ⚠ no refreshToken — corrupt or mid-write" >&2
        test -n "$mode"; and test "$mode" != 600; and echo "    ⚠ mode $mode (expected 600)" >&2

        # Live verification is only possible while the profile's own access token still works —
        # a refresh token can't be checked without USING it (rotation), which doctor never does.
        if test -n "$pat"; and test "$pat" != (__claude_cred_placeholder); and test "$pexp" -gt $now_ms 2>/dev/null
            set --local pid (__claude_cred_identity $pat)
            if test $status -eq 0
                set --local vemail (printf '%s' $pid | jq -r '.email // ""')
                if test -n "$email"; and test "$vemail" != "$email"
                    echo "    ⚠ token actually belongs to $vemail — metadata says $email" >&2
                    set email $vemail
                else
                    echo "    ✓ token verified: $vemail"
                    set email $vemail
                end
            else
                echo "    (stored access token no longer verifiable)"
            end
        else
            echo "    (access token expired — identity from metadata only)"
        end

        test -n "$live_email"; and test "$email" = "$live_email"; and set live_match $name
    end
    test $any -eq 0; and echo "  (none)"

    if test -n "$live_email"
        if test -z "$live_match"
            echo "⚠ live login ($live_email) is saved in NO profile — run: claude-cred save" >&2
        else
            echo "live login matches profile '$live_match'"
            if test -n "$active"; and test "$active" != "$live_match"
                echo "⚠ .active says '$active' but the live login matches '$live_match' — stale pointer" >&2
            else if test -z "$active"
                echo "note: no .active pointer — the next save/use will set it"
            end
        end
    else
        echo "note: live identity unavailable — structural checks only"
    end
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

function __claude_cred_account_line --argument-names creds
    # Skip the network in the two common can't-answer states so `show` stays instant.
    set --local at (__claude_cred_field $creds accessToken)
    set --local exp (__claude_cred_field $creds expiresAt)
    if test -z "$at"; or test "$at" = (__claude_cred_placeholder)
        echo '(pending refresh — start Claude Code, then: claude-cred save)'
        return
    end
    set --local now_ms (math (date +%s)" * 1000")
    if test -n "$exp"; and test "$exp" -lt $now_ms 2>/dev/null
        echo '(access token expired — restart Claude Code to refresh, then retry)'
        return
    end

    set --local identity (__claude_cred_identity $at)
    set --local rc $status
    switch $rc
        case 0
            printf '%s' $identity | jq -r '.email + (if .org != "" then " — " + .org else "" end) + (if .plan != "" then " (" + .plan + ")" else "" end)'
        case 1
            echo '(token rejected by the API — expired or revoked)'
        case 2
            echo "(network unreachable — can't verify)"
        case 3
            echo '(offline mode)'
    end
end

function __claude_cred_show --argument-names creds profiles
    set --local active (__claude_cred_active $profiles)
    test -z "$active"; and set active '(unnamed — claude-cred save <name>)'

    echo "profile:        $active"
    echo "account:        "(__claude_cred_account_line $creds)
    echo "accessToken:    "(__claude_cred_fingerprint (__claude_cred_field $creds accessToken))
    echo "refreshToken:   "(__claude_cred_fingerprint (__claude_cred_field $creds refreshToken))
    echo "expiresAt:      "(__claude_cred_when (__claude_cred_field $creds expiresAt))
    echo "refreshExpires: "(__claude_cred_when (__claude_cred_field $creds refreshTokenExpiresAt))
    echo "subscription:   "(__claude_cred_field $creds subscriptionType)" / "(__claude_cred_field $creds rateLimitTier)
    echo "mcpOAuth:       "(jq -r '.mcpOAuth // {} | keys | length' $creds)" server(s) — untouched by this tool"
end
