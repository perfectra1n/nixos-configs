#!/usr/bin/env fish

# Interactive PR merger for fjo (Forgejo CLI)
# Usage: fjo-pr-merge
#
# Sibling of tea-pr-merge / gh-pr-merge. fjo emits real JSON (`--json` +
# `--jq`), so the picker rows are pre-formatted by ONE jq pass instead of
# tea's reverse-parsed CSV or gh's per-PR jq spawns.

function fjo-pr-merge
    # Check if fjo is installed
    if not command -v fjo &> /dev/null
        echo "Error: 'fjo' command not found. Install with: cargo install --git https://github.com/perfectra1n/fjo"
        return 1
    end

    # Check if fzf is installed
    if not command -v fzf &> /dev/null
        echo "Error: 'fzf' command not found. Please install fzf for interactive selection."
        return 1
    end

    # Check if we're in a git repository (fjo resolves the repo from the remote)
    if not git rev-parse --git-dir &> /dev/null
        echo "Error: Not in a git repository"
        return 1
    end

    echo "Fetching pull requests..."

    # One API call, one jq pass: each output line is
    #   number<TAB>title<TAB>author<TAB>labels<TAB>draft<TAB>mergeable<TAB>state
    # fjo's embedded jq has no `@tsv`, so build the row by hand; tabs are
    # scrubbed out of the title so ours are the only TABs on a line.
    # `--paginate` because Renovate can leave far more than one page open.
    set pr_lines (fjo pr list --state open --paginate \
        --json number,title,user,labels,draft,mergeable,state \
        --jq '.[] | [
            .number,
            (.title | gsub("[\\t\\n]"; " ")),
            .user.login,
            (.labels | map(.name) | join(", ")),
            .draft,
            .mergeable,
            .state
        ] | map(tostring) | join("\t")' 2>&1)

    if test $status -ne 0
        echo "Error fetching PRs: $pr_lines"
        return 1
    end

    if test (count $pr_lines) -eq 0
        echo "No open pull requests found."
        return 0
    end

    # ANSI color codes
    set -l COLOR_RESET '\033[0m'
    set -l COLOR_CYAN '\033[36m'
    set -l COLOR_GREEN '\033[32m'
    set -l COLOR_YELLOW '\033[33m'
    set -l COLOR_BLUE '\033[34m'
    set -l COLOR_MAGENTA '\033[35m'
    set -l COLOR_RED '\033[31m'
    set -l COLOR_BOLD '\033[1m'

    # Format each row for display with colors
    set formatted_prs
    for line in $pr_lines
        set fields (string split \t -- $line)
        if test (count $fields) -lt 7
            continue
        end

        set pr_number    $fields[1]
        set pr_title     $fields[2]
        set pr_author    $fields[3]
        set pr_labels    $fields[4]
        set pr_draft     $fields[5]
        set pr_mergeable $fields[6]
        set pr_state     $fields[7]

        # Defensive: never offer a non-open PR for merging, even if the
        # list default ever changes.
        if test "$pr_state" != "open"
            continue
        end

        # Mergeability icon — the list payload carries draft/mergeable for
        # free, so no per-PR checks call is needed.
        set merge_icon ""
        if test "$pr_draft" = "true"
            set merge_icon (printf "%b" "$COLOR_BLUE")"[draft]"(printf "%b" "$COLOR_RESET")
        else if test "$pr_mergeable" = "true"
            set merge_icon (printf "%b" "$COLOR_GREEN")"[ok]"(printf "%b" "$COLOR_RESET")
        else
            set merge_icon (printf "%b" "$COLOR_RED")"[conflict]"(printf "%b" "$COLOR_RESET")
        end

        # Color the PR number in cyan and bold
        set colored_pr "$COLOR_BOLD$COLOR_CYAN#$pr_number$COLOR_RESET"

        # Color the author in yellow
        set colored_author "$COLOR_YELLOW@$pr_author$COLOR_RESET"

        # Color labels based on type
        set colored_labels ""
        if test -n "$pr_labels"
            set label_prefix "["
            set label_suffix "]"
            # Color Breaking PRs in red, Bug in yellow, dependencies in green
            if string match -qi "*breaking*" -- "$pr_labels"
                set colored_labels " $COLOR_BOLD$COLOR_RED$label_prefix$pr_labels$label_suffix$COLOR_RESET"
            else if string match -qi "*bug*" -- "$pr_labels"
                set colored_labels " $COLOR_YELLOW$label_prefix$pr_labels$label_suffix$COLOR_RESET"
            else if string match -qi "*dependenc*" -- "$pr_labels"
                set colored_labels " $COLOR_GREEN$label_prefix$pr_labels$label_suffix$COLOR_RESET"
            else
                set colored_labels " $COLOR_MAGENTA$label_prefix$pr_labels$label_suffix$COLOR_RESET"
            end
        end

        # Format: [ok] #123 | Title | @author | [labels]
        set display_line (printf "%b %b | %s | %b%b" "$merge_icon" "$colored_pr" "$pr_title" "$colored_author" "$colored_labels")
        set formatted_prs $formatted_prs "$display_line"
    end

    if test (count $formatted_prs) -eq 0
        echo "No open pull requests found."
        return 0
    end

    # Show interactive multi-select with fzf
    echo ""
    echo "Select PRs to merge (use SPACE or TAB to select multiple, ENTER to confirm):"
    echo ""

    set selected_prs (printf '%s\n' $formatted_prs | fzf --multi \
        --ansi \
        --height=80% \
        --border \
        --prompt="Select PRs to merge > " \
        --header="SPACE/TAB: select/deselect | ENTER: confirm | ESC: cancel" \
        --preview-window=hidden \
        --layout=reverse \
        --bind='ctrl-a:select-all,ctrl-d:deselect-all,space:toggle')

    if test -z "$selected_prs"
        echo "No PRs selected. Exiting."
        return 0
    end

    # Extract PR numbers from selected lines (strip ANSI codes first)
    set pr_numbers
    for line in $selected_prs
        # Strip ANSI color codes; the number is the FIRST "#NNN" token
        # (format: [ok] #123 | ...), so anchor on it rather than a greedy
        # match that could pick a "#123" out of the title.
        set clean (string replace -ra '\x1b\[[0-9;]*m' '' -- $line)
        set pr_num (string match -r '^\S+ #(\d+) ' -- $clean)[2]
        if test -n "$pr_num"
            set pr_numbers $pr_numbers $pr_num
        end
    end

    echo ""
    echo "Selected PRs to merge: $pr_numbers"
    echo ""

    # Confirm before merging
    read -l -P "Proceed with merging these PRs? [y/N] " confirm
    if test "$confirm" != "y" -a "$confirm" != "Y"
        echo "Merge cancelled."
        return 0
    end

    # Merge each selected PR with retry logic (Forgejo returns 405 while a
    # PR's mergeability is still being recomputed after the previous merge).
    set max_retries 20
    set failed_prs

    for pr_num in $pr_numbers
        echo ""
        echo "=========================================="
        echo "Merging PR #$pr_num..."
        echo "=========================================="

        set retry_count 0
        set merge_success false

        while test $retry_count -lt $max_retries
            fjo pr merge $pr_num --delete-branch

            if test $status -eq 0
                echo "✓ Successfully merged PR #$pr_num"
                set merge_success true
                break
            else
                set retry_count (math $retry_count + 1)
                if test $retry_count -lt $max_retries
                    echo "⚠ Merge failed (attempt $retry_count/$max_retries). Retrying in 2 seconds..."
                    sleep 2
                else
                    echo "✗ Failed to merge PR #$pr_num after $max_retries attempts"
                end
            end
        end

        if test "$merge_success" = false
            set failed_prs $failed_prs $pr_num
        end
    end

    # Summary
    echo ""
    echo "=========================================="
    echo "Merge Summary"
    echo "=========================================="
    echo "Total PRs selected: "(count $pr_numbers)
    echo "Successfully merged: "(math (count $pr_numbers) - (count $failed_prs))

    if test (count $failed_prs) -gt 0
        echo "Failed PRs: $failed_prs"
        return 1
    else
        echo "All PRs merged successfully! 🎉"
        return 0
    end
end
