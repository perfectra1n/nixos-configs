#!/usr/bin/env fish

# Clone (or pull, if already present) every repo in a GitHub org.
# The org defaults to the CURRENT directory's name, so `cd ~/repos/AtvikSecurity`
# then `gh-org-sync` fetches the whole AtvikSecurity org into that folder.
#
# Usage:
#   gh-org-sync                # org = basename of $PWD
#   gh-org-sync AtvikSecurity  # explicit org, still clones into $PWD
#   gh-org-sync --no-archived  # skip archived repos (flags pass through to `gh repo list`)

function gh-org-sync
    # gh does all the auth + protocol plumbing; without it there's nothing to do.
    if not command -v gh &>/dev/null
        echo "Error: 'gh' command not found. Install GitHub CLI first."
        return 1
    end

    if not gh auth status &>/dev/null
        echo "Error: Not authenticated with GitHub CLI. Run 'gh auth login' first."
        return 1
    end

    # First bare word overrides the org; everything else forwards to `gh repo list`
    # (e.g. --no-archived, --source, --fork, --limit N, --language go).
    # value_flags take an argument, so the token after them is a value, not the org.
    set -l org
    set -l passthru
    set -l value_flags -L --limit -l --language -t --template --topic --visibility
    set -l expect_value 0
    for arg in $argv
        if test $expect_value -eq 1
            set passthru $passthru $arg
            set expect_value 0
        else if string match -q -- '-*' $arg
            set passthru $passthru $arg
            # "--limit=5" is self-contained; "--limit 5" needs the next token too.
            if contains -- $arg $value_flags; and not string match -q -- '*=*' $arg
                set expect_value 1
            end
        else if test -z "$org"
            set org $arg
        else
            set passthru $passthru $arg
        end
    end

    # No explicit org → use the folder we're standing in.
    if test -z "$org"
        set org (basename (pwd))
    end

    # ANSI colors, matching the house style in gh-pr-merge.fish.
    set -l C_RESET '\033[0m'
    set -l C_CYAN '\033[36m'
    set -l C_GREEN '\033[32m'
    set -l C_YELLOW '\033[33m'
    set -l C_RED '\033[31m'
    set -l C_BOLD '\033[1m'

    printf "%bSyncing GitHub org %b%s%b into %s%b\n" \
        "$C_BOLD" "$C_CYAN" "$org" "$C_RESET$C_BOLD" (pwd) "$C_RESET"

    # Default --limit high so we don't silently truncate large orgs (gh defaults to 30),
    # but respect a user-supplied limit instead of passing it twice.
    set -l limit_args --limit 1000
    if contains -- --limit $passthru; or contains -- -L $passthru; or string match -q -- '--limit=*' $passthru
        set limit_args
    end
    set -l repos (gh repo list $org --json nameWithOwner --jq '.[].nameWithOwner' $limit_args $passthru 2>&1)
    if test $status -ne 0
        echo "Error listing repos for '$org': $repos"
        return 1
    end

    if test (count $repos) -eq 0
        echo "No repositories found in org '$org' (or you lack access)."
        return 0
    end

    printf "Found %b%d%b repositories.\n\n" "$C_BOLD" (count $repos) "$C_RESET"

    set -l cloned 0
    set -l pulled 0
    set -l failed

    for full in $repos
        # nameWithOwner is "org/repo" — the local dir is just the repo name.
        set -l name (string split -m1 / $full)[2]

        if test -d $name/.git
            printf "%b↻%b %s — pulling\n" "$C_YELLOW" "$C_RESET" "$name"
            if git -C $name pull --ff-only --quiet
                set pulled (math $pulled + 1)
            else
                printf "  %b✗ pull failed%b\n" "$C_RED" "$C_RESET"
                set failed $failed $name
            end
        else if test -e $name
            # Something's there but it isn't a git repo — don't clobber it.
            printf "%b⚠%b %s — path exists but isn't a git repo, skipping\n" "$C_YELLOW" "$C_RESET" "$name"
            set failed $failed $name
        else
            printf "%b↓%b %s — cloning\n" "$C_GREEN" "$C_RESET" "$name"
            if gh repo clone $full -- --quiet
                set cloned (math $cloned + 1)
            else
                printf "  %b✗ clone failed%b\n" "$C_RED" "$C_RESET"
                set failed $failed $name
            end
        end
    end

    printf "\n%b=== Summary ===%b\n" "$C_BOLD" "$C_RESET"
    printf "Cloned:  %b%d%b\n" "$C_GREEN" $cloned "$C_RESET"
    printf "Pulled:  %b%d%b\n" "$C_YELLOW" $pulled "$C_RESET"
    if test (count $failed) -gt 0
        printf "Failed:  %b%d%b (%s)\n" "$C_RED" (count $failed) "$C_RESET" (string join ', ' $failed)
        return 1
    end
    printf "All %d repos in sync.\n" (count $repos)
    return 0
end
