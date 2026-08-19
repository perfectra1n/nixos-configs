#!/usr/bin/env fish

# Fan out GitHub Actions secrets (and variables) across every repo in an org.
#
# Why fan out at all, when GitHub HAS org-level secrets: on the FREE plan an org
# secret only reaches PUBLIC repos, so a free org's private repos each need their own
# copy. Per-repo is the only path short of a Team upgrade — and it keeps the token at
# `repo` scope, where org secrets would demand `admin:org`.
#
# Usage:
#   gh-org-secrets set    NAME [--from-bw ITEM[.FIELD]] [flags]
#   gh-org-secrets list   [NAME]                        [flags]
#   gh-org-secrets delete NAME                          [flags]
#
# Flags (all subcommands):
#   --org NAME        target org (default: $GH_ORG, else basename of $PWD)
#   --variable        operate on Actions variables instead of secrets
#   --only GLOB       only repos matching GLOB (repeatable)
#   --exclude GLOB    skip repos matching GLOB (repeatable)
#   --include-public  also write to PUBLIC repos (set/delete skip them by default)
#   --dry-run         print the target repos and exit without touching anything
#   --yes, -y         skip the confirmation prompt
#
# set/delete are private-only by default: a secret in a public repo is reachable by
# far more workflows (notably fork PRs), so widening that blast radius is opt-in.
# `list` is exempt — it is read-only, and an audit that silently hides repos lies.
#
# The value for `set` comes from --from-bw, else piped stdin, else a silent prompt —
# never from an argv token, so it stays out of history and /proc/<pid>/cmdline.

function gh-org-secrets --description "Fan out GitHub Actions secrets/variables across an org"
    if not command -v gh &>/dev/null
        echo "Error: 'gh' command not found. Install GitHub CLI first."
        return 1
    end

    if not gh auth status &>/dev/null
        echo "Error: Not authenticated with GitHub CLI. Run 'gh auth login' first."
        return 1
    end

    # Normalize "--flag=value" into two tokens so the parser below handles one form only.
    set -l args
    for a in $argv
        if string match -qr -- '^--[a-z][a-z-]*=' $a
            set -a args (string split -m1 '=' -- $a)
        else
            set -a args $a
        end
    end

    set -l cmd
    set -l name
    set -l org
    set -l from_bw
    set -l kind secret
    set -l only
    set -l exclude
    set -l dry_run 0
    set -l assume_yes 0
    set -l include_public 0

    set -l i 1
    set -l n (count $args)
    while test $i -le $n
        set -l a $args[$i]
        # Out-of-range indexing yields empty silently, so every value flag must check
        # that a value actually follows it rather than trusting $args[$i+1].
        switch $a
            case --org --from-bw --only --exclude
                if test (math $i + 1) -gt $n
                    echo "Error: $a requires a value."
                    return 1
                end
                set i (math $i + 1)
                switch $a
                    case --org
                        set org $args[$i]
                    case --from-bw
                        set from_bw $args[$i]
                    case --only
                        set -a only $args[$i]
                    case --exclude
                        set -a exclude $args[$i]
                end
            case --variable
                set kind variable
            case --include-public
                set include_public 1
            case --dry-run
                set dry_run 1
            case --yes -y
                set assume_yes 1
            case -h --help
                __gh_org_secrets_help
                return 0
            case '-*'
                echo "Error: unknown flag '$a'."
                __gh_org_secrets_help
                return 1
            case '*'
                if test -z "$cmd"
                    set cmd $a
                else if test -z "$name"
                    set name $a
                else
                    echo "Error: unexpected argument '$a'."
                    return 1
                end
        end
        set i (math $i + 1)
    end

    if test -z "$cmd"
        __gh_org_secrets_help
        return 1
    end

    if not contains -- $cmd set list delete
        echo "Error: unknown subcommand '$cmd' (expected set, list, or delete)."
        return 1
    end

    if test -z "$name"; and contains -- $cmd set delete
        echo "Error: '$cmd' requires a NAME."
        return 1
    end

    if test -n "$from_bw"; and test "$cmd" != set
        echo "Error: --from-bw only applies to 'set'."
        return 1
    end

    # No explicit org → $GH_ORG, else the folder we're standing in (matching gh-org-sync).
    if test -z "$org"
        if test -n "$GH_ORG"
            set org $GH_ORG
        else
            set org (basename (pwd))
        end
    end

    set -l C_RESET '\033[0m'
    set -l C_CYAN '\033[36m'
    set -l C_GREEN '\033[32m'
    set -l C_YELLOW '\033[33m'
    set -l C_RED '\033[31m'
    set -l C_DIM '\033[2m'
    set -l C_BOLD '\033[1m'

    # Writing a secret into a PUBLIC repo exposes it to far more workflows (fork PRs
    # most of all), so mutations stay private-only unless --include-public says
    # otherwise. `list` is read-only and exempt: hiding repos from an audit is worse
    # than showing them.
    set -l enforce_private 0
    if contains -- $cmd set delete; and test $include_public -eq 0
        set enforce_private 1
    end

    set -l scope "all repos"
    test $enforce_private -eq 1; and set scope "private repos only"

    printf "%b%s %s%b in org %b%s%b %b(%s)%b\n" \
        "$C_BOLD" "$cmd" "$kind" "$C_RESET" "$C_CYAN" "$org" "$C_RESET" \
        "$C_DIM" "$scope" "$C_RESET"

    # --no-archived isn't tidiness: archived repos reject secret writes, so without it
    # every run ends with spurious failures and you learn to ignore the summary.
    # Visibility rides along in the same call so the private filter and the `list`
    # marker share one fetch. "owner/repo" can't contain '|', so it's a safe separator.
    set -l repos (gh repo list $org --no-archived --limit 1000 \
        --json nameWithOwner,visibility \
        --jq '.[] | "\(.nameWithOwner)|\(.visibility | ascii_downcase)"' 2>&1)
    if test $status -ne 0
        echo "Error listing repos for '$org': $repos"
        return 1
    end

    if test (count $repos) -eq 0
        echo "No repositories found in org '$org' (or you lack access)."
        return 0
    end

    set -l targets
    set -l skipped_public 0
    for rec in $repos
        set -l parts (string split -m1 '|' -- $rec)
        set -l full $parts[1]
        set -l vis $parts[2]
        set -l short (string split -m1 / -- $full)[2]
        if test (count $only) -gt 0
            set -l hit 0
            for g in $only
                if string match -q -- $g $short; or string match -q -- $g $full
                    set hit 1
                    break
                end
            end
            test $hit -eq 1; or continue
        end
        set -l skip 0
        for g in $exclude
            if string match -q -- $g $short; or string match -q -- $g $full
                set skip 1
                break
            end
        end
        test $skip -eq 0; or continue

        if test $enforce_private -eq 1; and test "$vis" = public
            set skipped_public (math $skipped_public + 1)
            continue
        end

        set -a targets $rec
    end

    if test (count $targets) -eq 0
        echo "No repositories matched after filtering."
        test $skipped_public -gt 0; and printf "(%d public repo(s) skipped — pass --include-public to include them.)\n" $skipped_public
        return 1
    end

    printf "Targeting %b%d%b of %d repos.\n" \
        "$C_BOLD" (count $targets) "$C_RESET" (count $repos)
    if test $skipped_public -gt 0
        printf "%bSkipping %d public repo(s) — pass --include-public to include them.%b\n" \
            "$C_YELLOW" $skipped_public "$C_RESET"
    end

    if test $dry_run -eq 1
        printf "\n%bDry run — nothing will be changed.%b\n" "$C_YELLOW" "$C_RESET"
        for rec in $targets
            set -l parts (string split -m1 '|' -- $rec)
            printf "  %-45s %b%s%b\n" $parts[1] "$C_DIM" $parts[2] "$C_RESET"
        end
        return 0
    end

    # `list` is read-only: no value to collect, no confirmation to ask for.
    if test "$cmd" = list
        __gh_org_secrets_list "$kind" "$name" $targets
        return $status
    end

    set -l value
    if test "$cmd" = set
        if test -n "$from_bw"
            # $pipestatus[1], not $status: piping through `string collect` would otherwise
            # mask the helper's failure behind collect's always-zero exit.
            set value (__gh_org_secrets_bw "$from_bw" | string collect)
            if test $pipestatus[1] -ne 0
                return 1
            end
        else if not isatty stdin
            # Piped in: `printf %s "$V" | gh-org-secrets set NAME`.
            #
            # `read -z`, NOT `(cat | string collect)`: a command substitution does not
            # inherit the pipe feeding this function — it gets the outer shell's stdin
            # and blocks forever. The `read` builtin sees the real piped stdin.
            # -z slurps to EOF instead of stopping at the first newline.
            read -z value
            # -z keeps the trailing newline a piped file almost always ends with;
            # GitHub would store it verbatim, so trim it. `string collect` also keeps
            # the whole thing as ONE element so internal newlines (PEM keys) survive.
            set value (string collect -- $value)
        else
            read -s -P "Value for $name: " value
            echo
        end

        if test -z "$value"
            echo "Error: empty value — refusing to set '$name'."
            return 1
        end

        # Show length + digest so the value can be eyeballed without echoing it.
        set -l fp (printf '%s' $value | sha256sum | string sub -l 12)
        printf "Value: %b%d chars, sha256:%s…%b\n" \
            "$C_DIM" (string length -- $value) "$fp" "$C_RESET"
    end

    if test $assume_yes -eq 0
        read -l -P (printf "%bProceed to %s '%s' on %d repos? [y/N] %b" \
            "$C_BOLD" "$cmd" "$name" (count $targets) "$C_RESET") reply
        if not string match -qi -- 'y*' "$reply"
            echo "Aborted."
            return 1
        end
    end

    echo

    set -l applied 0
    set -l absent 0
    set -l failed

    for rec in $targets
        set -l full (string split -m1 '|' -- $rec)[1]
        switch $cmd
            case set
                # printf is a fish BUILTIN, so the value never reaches an argv array —
                # unlike `gh secret set --body "$v"`, which exposes it in /proc/<pid>/cmdline.
                set -l out (printf '%s' $value | gh $kind set $name --repo $full 2>&1)
                if test $status -eq 0
                    printf "%b✓%b %s\n" "$C_GREEN" "$C_RESET" $full
                    set applied (math $applied + 1)
                else
                    printf "%b✗%b %s — %s\n" "$C_RED" "$C_RESET" $full (string join ' ' $out)
                    set -a failed $full
                end
            case delete
                set -l out (gh $kind delete $name --repo $full 2>&1)
                if test $status -eq 0
                    printf "%b✓%b %s\n" "$C_GREEN" "$C_RESET" $full
                    set applied (math $applied + 1)
                else if string match -qr -- 'HTTP 404|[Nn]ot [Ff]ound' "$out"
                    # Already gone is the desired end state, not a failure.
                    printf "%b·%b %s — not present\n" "$C_DIM" "$C_RESET" $full
                    set absent (math $absent + 1)
                else
                    printf "%b✗%b %s — %s\n" "$C_RED" "$C_RESET" $full (string join ' ' $out)
                    set -a failed $full
                end
        end
    end

    printf "\n%b=== Summary ===%b\n" "$C_BOLD" "$C_RESET"
    printf "Applied: %b%d%b\n" "$C_GREEN" $applied "$C_RESET"
    if test "$cmd" = delete
        printf "Absent:  %b%d%b\n" "$C_YELLOW" $absent "$C_RESET"
    end
    if test (count $failed) -gt 0
        printf "Failed:  %b%d%b (%s)\n" \
            "$C_RED" (count $failed) "$C_RESET" (string join ', ' $failed)
        return 1
    end
    set -l verb (test "$cmd" = set; and echo set; or echo deleted)
    printf "%s '%s' %s across %d repos.\n" $kind $name $verb $applied
    return 0
end

function __gh_org_secrets_help
    echo "gh-org-secrets — fan out GitHub Actions secrets/variables across an org"
    echo
    echo "Usage:"
    echo "  gh-org-secrets set    NAME [--from-bw ITEM[.FIELD]] [flags]"
    echo "  gh-org-secrets list   [NAME]                        [flags]"
    echo "  gh-org-secrets delete NAME                          [flags]"
    echo
    echo "Flags:"
    echo "  --org NAME        target org (default: \$GH_ORG, else basename of \$PWD)"
    echo "  --variable        operate on Actions variables instead of secrets"
    echo "  --only GLOB       only repos matching GLOB (repeatable)"
    echo "  --exclude GLOB    skip repos matching GLOB (repeatable)"
    echo "  --include-public  also write to PUBLIC repos (set/delete skip them by default)"
    echo "  --dry-run         print target repos and exit without changing anything"
    echo "  --yes, -y         skip the confirmation prompt"
    echo
    echo "set/delete target PRIVATE repos only unless --include-public is passed."
    echo "list is read-only and always shows every repo, marking public ones."
    echo
    echo "Examples:"
    echo "  gh-org-secrets list --org AtvikSecurity"
    echo "  gh-org-secrets list NPM_TOKEN --org AtvikSecurity"
    echo "  gh-org-secrets set NPM_TOKEN --from-bw 'npm registry' --org AtvikSecurity"
    echo "  printf %s \"\$TOKEN\" | gh-org-secrets set NPM_TOKEN --org AtvikSecurity -y"
    echo "  gh-org-secrets delete OLD_KEY --org AtvikSecurity --exclude 'legacy-*'"
end

# Read-only audit view. Without NAME: every repo's secret names. With NAME: which repos
# have it and which don't — the check that tells you a rotation actually landed.
function __gh_org_secrets_list --argument-names kind want
    set -l targets $argv[3..-1]

    set -l C_RESET '\033[0m'
    set -l C_GREEN '\033[32m'
    set -l C_RED '\033[31m'
    set -l C_DIM '\033[2m'
    set -l C_BOLD '\033[1m'

    # Variables aren't encrypted, so their values are readable; secrets only ever
    # expose names + timestamps, which is why this is a presence check, not a diff.
    set -l fields name,updatedAt
    test "$kind" = variable; and set fields name,value,updatedAt

    set -l present 0
    set -l missing 0
    set -l failed

    echo
    for rec in $targets
        set -l parts (string split -m1 '|' -- $rec)
        set -l full $parts[1]
        # Flag public repos inline: a secret living in one is worth noticing during an audit.
        set -l tag ""
        test "$parts[2]" = public; and set tag " [public]"

        set -l out (gh $kind list --repo $full --json $fields 2>&1)
        if test $status -ne 0
            printf "%b✗%b %s%s — %s\n" "$C_RED" "$C_RESET" $full "$tag" (string join ' ' $out)
            set -a failed $full
            continue
        end

        if test -n "$want"
            set -l hit (echo $out | jq -r --arg n "$want" \
                '.[] | select(.name == $n) | .updatedAt' | string collect)
            if test -n "$hit"
                printf "%b✓%b %-45s %b%s%s%b\n" \
                    "$C_GREEN" "$C_RESET" $full "$C_DIM" (string sub -l 10 $hit) "$tag" "$C_RESET"
                set present (math $present + 1)
            else
                printf "%b·%b %-45s %b(absent)%s%b\n" \
                    "$C_DIM" "$C_RESET" $full "$C_DIM" "$tag" "$C_RESET"
                set missing (math $missing + 1)
            end
        else
            set -l names (echo $out | jq -r '.[].name' | string join ', ')
            test -n "$names"; or set names "(none)"
            printf "%b%s%b%b%s%b\n  %s\n" \
                "$C_BOLD" $full "$C_RESET" "$C_DIM" "$tag" "$C_RESET" $names
        end
    end

    if test -n "$want"
        printf "\n%b=== Summary ===%b\n" "$C_BOLD" "$C_RESET"
        printf "Present: %b%d%b\n" "$C_GREEN" $present "$C_RESET"
        printf "Absent:  %b%d%b\n" "$C_DIM" $missing "$C_RESET"
    end
    if test (count $failed) -gt 0
        printf "Failed:  %b%d%b (%s)\n" \
            "$C_RED" (count $failed) "$C_RESET" (string join ', ' $failed)
        return 1
    end
    return 0
end

# Resolve a Bitwarden spec to a value on stdout.
#   ITEM        → the item's login password
#   ITEM.FIELD  → that custom field
function __gh_org_secrets_bw --argument-names spec
    if not command -v bw &>/dev/null
        echo "Error: 'bw' not found (needed for --from-bw)." >&2
        return 1
    end

    # Reuse an already-unlocked session rather than re-prompting; same contract as
    # bw_unlock() in scripts/secrets-sync.py.
    set -l st (bw status 2>/dev/null | jq -r '.status')
    set -l session
    if test -n "$BW_SESSION"; and test "$st" = unlocked
        set session $BW_SESSION
    else if test "$st" = unauthenticated
        set session (bw login --raw)
    else
        set session (bw unlock --raw)
    end
    if test -z "$session"
        echo "Error: bw unlock failed (no session)." >&2
        return 1
    end
    # A stale local cache silently misses renamed or newly added items.
    BW_SESSION=$session bw sync >/dev/null 2>&1

    # Try the WHOLE spec as an item name first, and only split on the last dot if that
    # finds nothing — otherwise a dotted item name ("s3.example.com") gets mangled into
    # item "s3.example" plus a bogus field "com".
    set -l item $spec
    set -l field
    set -l json (__gh_org_secrets_bw_item "$spec" "$session" | string collect)
    if test -z "$json"
        set -l m (string match -r '^(.*)\.([^.]+)$' -- $spec)
        if test (count $m) -eq 3
            set item $m[2]
            set field $m[3]
            set json (__gh_org_secrets_bw_item "$item" "$session" | string collect)
        end
    end
    if test -z "$json"
        echo "Error: no Bitwarden item named exactly \"$item\"." >&2
        return 1
    end

    set -l value
    if test -n "$field"
        set value (echo $json | jq -r --arg f "$field" \
            '.fields[]? | select(.name == $f) | .value' | string collect)
        if test -z "$value"
            echo "Error: item \"$item\" has no custom field \"$field\"." >&2
            return 1
        end
    else
        set value (echo $json | jq -r '.login.password // empty' | string collect)
        if test -z "$value"
            echo "Error: item \"$item\" has no password (use ITEM.FIELD for a custom field)." >&2
            return 1
        end
    end

    printf '%s' $value
end

# Echo the ONE item whose name matches EXACTLY (case-insensitive), else nothing.
# `bw get item` is deliberately avoided: it fuzzy-matches name AND uris AND notes, so it
# happily returns the wrong item. Same discipline as bwitem() in scripts/secrets-sync.py.
function __gh_org_secrets_bw_item --argument-names name session
    set -l hits (BW_SESSION=$session bw list items --search "$name" 2>/dev/null \
        | jq --arg n "$name" '[.[] | select((.name // "" | ascii_downcase) == ($n | ascii_downcase))]')
    test -n "$hits"; or return 0
    if test (echo $hits | jq 'length') -eq 1
        echo $hits | jq -c '.[0]'
    end
end
