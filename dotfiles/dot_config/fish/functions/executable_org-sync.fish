#!/usr/bin/env fish

# Clone (or pull, if already present) every repo in an org that lives on GitHub,
# a Gitea instance, or both — and audit where each checkout's `origin` points.
# The org defaults to the CURRENT directory's name, so `cd ~/repos/AtvikSecurity`
# then `org-sync` fetches the whole org into that folder.
#
# Canonical remote per repo (the "mirror rule"):
#   Gitea, mirror=false → Gitea is canonical (migrated there; GitHub copies may be stale)
#   Gitea, mirror=true  → the mirror's original_url (GitHub) is canonical; never push to the mirror
#   GitHub only         → GitHub
#
# Usage:
#   org-sync                      # org = basename of $PWD; clone missing, pull existing, REPORT drift
#   org-sync --report             # audit only: no clone, no pull, no remote changes
#   org-sync --fix-remotes        # also repoint stale-host / mirror origins (old URL kept as old-origin)
#   org-sync --fix-github         # --fix-remotes, plus move GitHub origins whose Gitea copy is canonical
#   org-sync --forge github|gitea|auto   (default auto: union of both)
#   org-sync --gitea-host HOST    # else $ORG_SYNC_GITEA_HOST, else ./.org-sync-gitea-host, else inferred
#   org-sync --no-archived        # other flags pass through to `gh repo list` (--no-archived also filters Gitea)

function org-sync --description 'Clone/pull an org across GitHub + Gitea and audit origin remotes'
    # First bare word overrides the org; unknown flags forward to `gh repo list`.
    # value_flags take an argument, so the token after them is a value, not the org.
    set -l org
    set -l passthru
    set -l forge auto
    set -l gitea_host
    set -l report 0
    set -l fix 0
    set -l fix_github 0
    set -l no_archived 0
    set -l value_flags -L --limit -l --language -t --template --topic --visibility
    set -l expect
    for arg in $argv
        if test -n "$expect"
            switch $expect
                case --forge
                    set forge $arg
                case --gitea-host
                    set gitea_host $arg
                case '*'
                    set -a passthru $arg
            end
            set expect
            continue
        end
        switch $arg
            case --forge --gitea-host
                set expect $arg
            case '--forge=*'
                set forge (string split -m1 = -- $arg)[2]
            case '--gitea-host=*'
                set gitea_host (string split -m1 = -- $arg)[2]
            case --report
                set report 1
            case --fix-remotes
                set fix 1
            case --fix-github
                set fix 1
                set fix_github 1
            case -h --help
                sed -n '/^# Clone/,/^$/p' (status filename) | string replace -r '^# ?' ''
                return 0
            case '-*'
                set -a passthru $arg
                test "$arg" = --no-archived; and set no_archived 1
                # "--limit=5" is self-contained; "--limit 5" needs the next token too.
                if contains -- $arg $value_flags
                    set expect passthru
                end
            case '*'
                if test -z "$org"
                    set org $arg
                else
                    set -a passthru $arg
                end
        end
    end

    if not contains -- $forge auto github gitea
        echo "Error: --forge must be auto, github or gitea (got '$forge')."
        return 1
    end
    if test $report -eq 1 -a $fix -eq 1
        echo "Error: --report is read-only; drop it to use --fix-remotes/--fix-github."
        return 1
    end

    # No explicit org → use the folder we're standing in.
    if test -z "$org"
        set org (basename (pwd))
    end
    set -l org_lc (string lower -- $org)

    # ANSI colors, matching the house style in gh-pr-merge.fish.
    set -l C_RESET '\033[0m'
    set -l C_CYAN '\033[36m'
    set -l C_GREEN '\033[32m'
    set -l C_YELLOW '\033[33m'
    set -l C_RED '\033[31m'
    set -l C_DIM '\033[2m'
    set -l C_BOLD '\033[1m'

    # Index local checkouts by what their origin POINTS AT, not by folder name:
    # dirs get renamed (atviksecurity-iac holds `iac`) and one repo can have several
    # checkouts (lupina + lupina-adopt).
    set -l l_dir
    set -l l_url
    set -l l_host
    set -l l_key
    for gitdir in */.git .*/.git
        set -l d (string replace -r '/\.git$' '' -- $gitdir)
        set -l url (git -C $d remote get-url origin 2>/dev/null)
        set -l p
        test -n "$url"; and set p (__org_sync_parse_url "$url")
        set -a l_dir $d
        set -a l_url "$url"
        if test (count $p) -eq 2
            set -a l_host $p[1]
            set -a l_key (string lower -- $p[2])
        else
            set -a l_host ''
            set -a l_key ''
        end
    end
    set -l l_seen

    # --- Which forges can we talk to? -------------------------------------------------
    set -l use_gh 0
    if test $forge != gitea
        if command -q gh; and gh auth status &>/dev/null
            set use_gh 1
        else if test $forge = github
            echo "Error: 'gh' missing or not authenticated. Run 'gh auth login' first."
            return 1
        else
            printf "%b⚠ gh missing or unauthenticated — GitHub side skipped%b\n" "$C_YELLOW" "$C_RESET"
        end
    end

    set -l use_gea 0
    if test $forge != github
        if not command -q gea
            if test $forge = gitea
                echo "Error: 'gea' command not found."
                return 1
            end
            printf "%b⚠ gea not found — Gitea side skipped%b\n" "$C_YELLOW" "$C_RESET"
        else
            # The host is never hardcoded (this repo is public): flag > env > pin file > inference.
            set -l host_src
            if test -n "$gitea_host"
                set host_src --gitea-host
            else if set -q ORG_SYNC_GITEA_HOST; and test -n "$ORG_SYNC_GITEA_HOST"
                set gitea_host $ORG_SYNC_GITEA_HOST
                set host_src '$ORG_SYNC_GITEA_HOST'
            else if test -f .org-sync-gitea-host
                set gitea_host (string trim < .org-sync-gitea-host)[1]
                set host_src .org-sync-gitea-host
            else
                # Several gea hosts can carry the same org (a live instance AND an older
                # copy), so "has the org" isn't enough — prefer the host our org checkouts
                # already use, and refuse to guess when that's still ambiguous.
                set -l gea_hosts (gea auth status --json host,authenticated --jq '.[] | select(.authenticated) | .host' 2>/dev/null)
                set -l used
                for j in (seq (count $l_dir))
                    if string match -q -- "$org_lc/*" $l_key[$j]; and contains -- $l_host[$j] $gea_hosts
                        contains -- $l_host[$j] $used; or set -a used $l_host[$j]
                    end
                end
                set -l with_org
                for h in $gea_hosts
                    gea --host $h api "/orgs/$org" --jq .username &>/dev/null; and set -a with_org $h
                end
                if test (count $used) -eq 1
                    set gitea_host $used
                    set host_src "inferred from local origins"
                else if test (count $used) -eq 0 -a (count $with_org) -eq 1
                    set gitea_host $with_org
                    set host_src "only gea host with org '$org'"
                else if test (count $with_org) -eq 0 -a (count $used) -eq 0
                    if test $forge = gitea
                        echo "Error: no logged-in gea host has org '$org'."
                        return 1
                    end
                    printf "%bno gea host has org '%s' — GitHub only%b\n" "$C_DIM" "$org" "$C_RESET"
                else
                    echo "Error: can't tell which Gitea host is canonical for '$org' (candidates: "(printf '%s\n' $used $with_org | sort -u | string join ', ')")."
                    echo "Pass --gitea-host HOST, or pin it: echo HOST > .org-sync-gitea-host"
                    return 1
                end
            end
            if test -n "$gitea_host"
                set use_gea 1
                printf "%bGitea host: %s (%s)%b\n" "$C_DIM" "$gitea_host" "$host_src" "$C_RESET"
            end
        end
    end

    if test $use_gh -eq 0 -a $use_gea -eq 0
        echo "Error: no usable forge for org '$org'."
        return 1
    end

    # git talks to Gitea through gea's token, scoped to that host and per-invocation
    # (an empty helper resets the list) — global git config is never touched.
    # The helper gets gea's REAL binary: git runs helpers inside the repo, where a mise
    # shim refuses to start if that repo carries an untrusted .mise config.
    set -l gitcred
    if test $use_gea -eq 1
        set -l gea_bin (string match -v -- '*/mise/shims/*' (command -s -a gea))[1]
        if test -z "$gea_bin"
            set gea_bin (mise which gea 2>/dev/null); or set gea_bin (command -s gea)
        end
        set gitcred -c "credential.https://$gitea_host.helper=" \
            -c "credential.https://$gitea_host.helper=!$gea_bin --host $gitea_host auth git-credential"
    end

    printf "%bSyncing org %b%s%b into %s%b\n" \
        "$C_BOLD" "$C_CYAN" "$org" "$C_RESET$C_BOLD" (pwd) "$C_RESET"

    # --- Union of both forges, resolved to one canonical URL per repo ------------------
    set -l r_name
    set -l r_key
    set -l r_canon
    set -l r_kind
    set -l n_gitea 0
    set -l n_mirror 0
    set -l n_github 0

    if test $use_gea -eq 1
        # gea pages at 30 by default — an unpaged listing once silently dropped 17 repos,
        # so page explicitly AND cross-check against the server's X-Total-Count.
        set -l rows (gea --host $gitea_host api "/orgs/$org/repos?limit=50" --paginate \
            --jq '.[] | [.name, .mirror, (.original_url // ""), .clone_url, .archived] | map(tostring) | join("\t")' 2>&1)
        if test $status -ne 0
            echo "Error listing Gitea repos for '$org' on $gitea_host: $rows"
            return 1
        end
        set -l total (gea --host $gitea_host api -i "/orgs/$org/repos?limit=1" 2>/dev/null \
            | string match -ri '^x-total-count:\s*(\d+)')[2]
        if test -n "$total"; and test (count $rows) -ne $total
            printf "%bError: Gitea listing truncated — got %d of %d repos. Refusing to continue.%b\n" \
                "$C_RED" (count $rows) $total "$C_RESET"
            return 1
        end
        for row in $rows
            set -l f (string split \t -- $row)
            test $no_archived -eq 1 -a "$f[5]" = true; and continue
            set -a r_name $f[1]
            set -a r_key (string lower -- "$org/$f[1]")
            if test "$f[2]" = true -a -n "$f[3]"
                set -a r_canon $f[3]
                set -a r_kind mirror
                set n_mirror (math $n_mirror + 1)
            else
                set -a r_canon $f[4]
                set -a r_kind gitea
            end
            set n_gitea (math $n_gitea + 1)
        end
    end

    if test $use_gh -eq 1
        # Default --limit high so we don't silently truncate large orgs (gh defaults to 30),
        # but respect a user-supplied limit instead of passing it twice.
        set -l limit_args --limit 1000
        if contains -- --limit $passthru; or contains -- -L $passthru; or string match -q -- '--limit=*' $passthru
            set limit_args
        end
        set -l names (gh repo list $org --json name --jq '.[].name' $limit_args $passthru 2>&1)
        if test $status -ne 0
            echo "Error listing GitHub repos for '$org': $names"
            return 1
        end
        set n_github (count $names)
        for n in $names
            # Gitea already decided this repo's canonical home (non-mirror → Gitea,
            # mirror → its GitHub original), so GitHub only adds repos Gitea lacks.
            set -l k (string lower -- "$org/$n")
            contains -- $k $r_key; and continue
            set -a r_name $n
            set -a r_key $k
            set -a r_canon "https://github.com/$org/$n.git"
            set -a r_kind github
        end
    end

    if test (count $r_name) -eq 0
        echo "No repositories found in org '$org' (or you lack access)."
        return 0
    end

    set -l src
    test $use_gea -eq 1; and set -a src "Gitea $n_gitea ($n_mirror mirrors)"
    test $use_gh -eq 1; and set -a src "GitHub $n_github"
    printf "Found %b%d%b repositories (%s).\n\n" "$C_BOLD" (count $r_name) "$C_RESET" (string join ' · ' $src)

    set -l cloned 0
    set -l pulled 0
    set -l repointed 0
    set -l would_clone
    set -l drift
    set -l foreign
    set -l failed

    for i in (seq (count $r_name))
        set -l name $r_name[$i]
        set -l canon $r_canon[$i]
        set -l kind $r_kind[$i]
        set -l cp (__org_sync_parse_url $canon)
        set -l chost $cp[1]

        set -l idx
        for j in (seq (count $l_dir))
            test "$l_key[$j]" = $r_key[$i]; and set -a idx $j
        end

        # --- Not checked out anywhere → clone from the canonical forge ---
        if test (count $idx) -eq 0
            if test -d $name/.git
                # Same name, someone else's repo (e.g. a third-party upstream like
                # nccgroup/sadcloud) — never touch it.
                set -l j (contains -i -- $name $l_dir)
                set -a l_seen $name
                set -a foreign $name
                printf "%b↷%b %s — origin is %s, not %s's; leaving it alone\n" \
                    "$C_DIM" "$C_RESET" "$name" (test -n "$l_url[$j]"; and echo $l_url[$j]; or echo none) "$org"
            else if test -e $name
                # Something's there but it isn't a git repo — don't clobber it.
                printf "%b⚠%b %s — path exists but isn't a git repo, skipping\n" "$C_YELLOW" "$C_RESET" "$name"
                set -a failed $name
            else if test $report -eq 1
                printf "%b+%b %s — not checked out (would clone %s)\n" "$C_GREEN" "$C_RESET" "$name" "$canon"
                set -a would_clone $name
            else
                printf "%b↓%b %s — cloning from %s\n" "$C_GREEN" "$C_RESET" "$name" "$chost"
                set -l ok 1
                if test $use_gea -eq 1 -a "$chost" = "$gitea_host"
                    gea --host $gitea_host repo clone $org/$name $name -- --quiet; or set ok 0
                else if test "$chost" = github.com -a $use_gh -eq 1
                    gh repo clone $cp[2] $name -- --quiet; or set ok 0
                else
                    git $gitcred clone --quiet $canon $name; or set ok 0
                end
                if test $ok -eq 1
                    set cloned (math $cloned + 1)
                else
                    printf "  %b✗ clone failed%b\n" "$C_RED" "$C_RESET"
                    set -a failed $name
                end
            end
            continue
        end

        # --- Existing checkout(s): audit origin, optionally repoint, then pull ---
        for j in $idx
            set -l d $l_dir[$j]
            set -a l_seen $d
            set -l label $name
            test "$d" != "$name"; and set label "$d → $name"

            set -l state ok
            if test "$l_host[$j]" != "$chost"
                if test $kind = mirror -a "$l_host[$j]" = "$gitea_host"
                    set state mirror-origin
                else if test $kind = gitea -a "$l_host[$j]" = github.com
                    set state github-diverged
                else
                    set state stale-host
                end
            end

            switch $state
                case ok
                    printf "%b✓%b %s — origin ok (%s%s)\n" "$C_GREEN" "$C_RESET" "$label" "$chost" \
                        (test $kind = mirror; and echo ", Gitea mirrors it")
                case stale-host
                    printf "%b⚠%b %s — %bstale host%b %s → %s\n" "$C_YELLOW" "$C_RESET" "$label" \
                        "$C_YELLOW" "$C_RESET" "$l_host[$j]" "$canon"
                case mirror-origin
                    printf "%b⚠%b %s — %bpoints at the Gitea pull-mirror%b; GitHub is canonical → %s\n" \
                        "$C_YELLOW" "$C_RESET" "$label" "$C_YELLOW" "$C_RESET" "$canon"
                case github-diverged
                    printf "%b⚠%b %s — %bon GitHub, but Gitea is canonical%b (GitHub copy likely stale) → %s\n" \
                        "$C_RED" "$C_RESET" "$label" "$C_RED" "$C_RESET" "$canon"
            end

            set -l do_fix 0
            if test $state != ok -a $fix -eq 1
                if test $state != github-diverged -o $fix_github -eq 1
                    set do_fix 1
                end
            end

            if test $state != ok -a $do_fix -eq 0
                set -a drift $d
            end

            test $report -eq 1; and continue

            if test $do_fix -eq 1
                if git -C $d remote get-url old-origin &>/dev/null
                    printf "  %b✗ remote 'old-origin' already exists — not repointing%b\n" "$C_RED" "$C_RESET"
                    set -a failed $d
                    continue
                end
                # add + set-url (not `remote rename`, which would drag every branch's
                # tracking config over to old-origin). Reverse with:
                #   git remote set-url origin (git remote get-url old-origin); git remote remove old-origin
                git -C $d remote add old-origin $l_url[$j]
                and git -C $d remote set-url origin $canon
                # --prune: a leftover origin/<branch> from the old host would otherwise
                # make the tracking check below pass when the new remote lacks the branch.
                and git $gitcred -C $d fetch --quiet --prune origin
                if test $status -ne 0
                    # Roll all the way back — a half-repointed checkout is worse than a stale one.
                    git -C $d remote set-url origin $l_url[$j]
                    git -C $d remote remove old-origin 2>/dev/null
                    printf "  %b✗ repoint/fetch failed — origin restored to %s%b\n" "$C_RED" "$l_url[$j]" "$C_RESET"
                    set -a failed $d
                    continue
                end
                set repointed (math $repointed + 1)
                printf "  %b↪ origin repointed; old URL kept as old-origin%b\n" "$C_CYAN" "$C_RESET"

                set -l branch (git -C $d symbolic-ref --quiet --short HEAD)
                if test -z "$branch"
                    printf "  %bdetached HEAD — pull skipped%b\n" "$C_DIM" "$C_RESET"
                    continue
                end
                if not git -C $d rev-parse --verify --quiet "$branch@{upstream}" &>/dev/null
                    if git -C $d rev-parse --verify --quiet "refs/remotes/origin/$branch" &>/dev/null
                        git -C $d branch --quiet --set-upstream-to=origin/$branch $branch
                    else
                        printf "  %b✗ branch '%s' has no counterpart on the new origin — not pulling%b\n" \
                            "$C_RED" "$branch" "$C_RESET"
                        set -a failed $d
                        continue
                    end
                end
            else if test $state = stale-host
                # Pulling from a host we've moved off is at best stale, at worst a 401.
                printf "  %bpull skipped (stale remote — rerun with --fix-remotes)%b\n" "$C_DIM" "$C_RESET"
                continue
            end

            if git $gitcred -C $d pull --ff-only --quiet
                set pulled (math $pulled + 1)
            else
                printf "  %b✗ pull failed%b\n" "$C_RED" "$C_RESET"
                set -a failed $d
            end
        end
    end

    # Checkouts that matched nothing in the listing — never touched, just surfaced.
    set -l unlisted
    for j in (seq (count $l_dir))
        contains -- $l_dir[$j] $l_seen; and continue
        if test -z "$l_url[$j]"
            set -a unlisted "$l_dir[$j] (no origin)"
        else if not string match -q -- "$org_lc/*" $l_key[$j]
            set -a foreign $l_dir[$j]
            set -a unlisted "$l_dir[$j] (third-party: $l_url[$j])"
        else
            set -a unlisted "$l_dir[$j] (not in either listing: $l_url[$j])"
        end
    end
    if test (count $unlisted) -gt 0
        printf "\n%bNot in the org listing (left alone):%b\n" "$C_DIM" "$C_RESET"
        printf "  %s\n" $unlisted
    end

    printf "\n%b=== Summary ===%b\n" "$C_BOLD" "$C_RESET"
    if test $report -eq 1
        printf "Would clone: %b%d%b\n" "$C_GREEN" (count $would_clone) "$C_RESET"
    else
        printf "Cloned:      %b%d%b\n" "$C_GREEN" $cloned "$C_RESET"
        printf "Pulled:      %b%d%b\n" "$C_YELLOW" $pulled "$C_RESET"
        printf "Repointed:   %b%d%b\n" "$C_CYAN" $repointed "$C_RESET"
    end
    if test (count $drift) -gt 0
        printf "Drifted:     %b%d%b (%s)\n" "$C_YELLOW" (count $drift) "$C_RESET" (string join ', ' $drift)
        printf "             %b→ --fix-remotes repoints stale/mirror origins; --fix-github also moves GitHub ones%b\n" \
            "$C_DIM" "$C_RESET"
    end
    if test (count $foreign) -gt 0
        printf "Third-party: %b%d%b (%s)\n" "$C_DIM" (count $foreign) "$C_RESET" (string join ', ' $foreign)
    end
    if test (count $failed) -gt 0
        printf "Failed:      %b%d%b (%s)\n" "$C_RED" (count $failed) "$C_RESET" (string join ', ' $failed)
        return 1
    end
    if test $report -eq 0 -a (count $drift) -eq 0
        printf "All %d repos in sync.\n" (count $r_name)
    end
    return 0
end
