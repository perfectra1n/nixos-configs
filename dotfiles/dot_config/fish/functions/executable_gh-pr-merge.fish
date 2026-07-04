#!/usr/bin/env fish

# Interactive PR merger for GitHub CLI (gh)
# Usage: gh-pr-merge

function gh-pr-merge
    # Check if gh is installed
    if not command -v gh &> /dev/null
        echo "Error: 'gh' command not found. Please install GitHub CLI first."
        return 1
    end

    # Check if fzf is installed
    if not command -v fzf &> /dev/null
        echo "Error: 'fzf' command not found. Please install fzf for interactive selection."
        echo "Install with: apt install fzf, brew install fzf, or pacman -S fzf"
        return 1
    end

    # Check if we're in a git repository
    if not git rev-parse --git-dir &> /dev/null
        echo "Error: Not in a git repository"
        return 1
    end

    # Check if authenticated with gh
    if not gh auth status &> /dev/null
        echo "Error: Not authenticated with GitHub CLI. Run 'gh auth login' first."
        return 1
    end

    echo "Fetching pull requests..."

    # Get PR list in JSON format for reliable parsing
    # Include statusCheckRollup for CI/CD status
    set pr_data (gh pr list --state open --json number,title,author,labels,statusCheckRollup --limit 100 2>&1)

    if test $status -ne 0
        echo "Error fetching PRs: $pr_data"
        return 1
    end

    # Check if there are any PRs
    set pr_count (echo $pr_data | jq 'length')
    if test "$pr_count" = "0" -o -z "$pr_count"
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

    # Parse JSON and format for display with colors
    set formatted_prs
    for i in (seq 0 (math $pr_count - 1))
        set pr_number (echo $pr_data | jq -r ".[$i].number")
        set pr_title (echo $pr_data | jq -r ".[$i].title")
        set pr_author (echo $pr_data | jq -r ".[$i].author.login")
        set pr_labels (echo $pr_data | jq -r ".[$i].labels | map(.name) | join(\", \")")

        # Get CI/CD status from statusCheckRollup
        # CheckRun uses: status (COMPLETED, IN_PROGRESS, QUEUED) and conclusion (SUCCESS, FAILURE, etc.)
        # StatusContext uses: state (SUCCESS, FAILURE, PENDING, ERROR)
        set check_data (echo $pr_data | jq -r ".[$i].statusCheckRollup // []" 2>/dev/null)
        set check_count (echo $check_data | jq 'length' 2>/dev/null)

        # Determine overall CI status icon
        set ci_icon ""
        if test -n "$check_count" -a "$check_count" != "0" -a "$check_count" != "null"
            # Get conclusions (for CheckRun) and states (for StatusContext)
            set conclusions (echo $check_data | jq -r '.[]? | .conclusion // .state // empty' 2>/dev/null)
            set statuses (echo $check_data | jq -r '.[]? | .status // empty' 2>/dev/null)

            if echo $conclusions | grep -qi "FAILURE\|ERROR"
                set ci_icon (printf "%b" "$COLOR_RED")"[X]"(printf "%b" "$COLOR_RESET")  # Failed
            else if echo $statuses | grep -qi "IN_PROGRESS\|QUEUED\|PENDING"
                set ci_icon (printf "%b" "$COLOR_YELLOW")"[~]"(printf "%b" "$COLOR_RESET")  # Pending
            else if echo $conclusions | grep -qi "SUCCESS"
                set ci_icon (printf "%b" "$COLOR_GREEN")"[ok]"(printf "%b" "$COLOR_RESET")  # All passed
            else
                set ci_icon (printf "%b" "$COLOR_BLUE")"[-]"(printf "%b" "$COLOR_RESET")  # Unknown
            end
        else
            set ci_icon (printf "%b" "$COLOR_BLUE")"[-]"(printf "%b" "$COLOR_RESET")  # No checks
        end

        # Color the PR number in cyan and bold
        set colored_pr "$COLOR_BOLD$COLOR_CYAN#$pr_number$COLOR_RESET"

        # Color the author in yellow
        set colored_author "$COLOR_YELLOW@$pr_author$COLOR_RESET"

        # Color labels based on type
        set colored_labels ""
        if test -n "$pr_labels" -a "$pr_labels" != ""
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

        # Format: [CI] #123 | Title | @author | [labels]
        set display_line (printf "%b %b | %s | %b%b" "$ci_icon" "$colored_pr" "$pr_title" "$colored_author" "$colored_labels")
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
        # Strip ANSI color codes and extract PR number (format: [ok] #123 | ...)
        set clean (string replace -ra '\x1b\[[0-9;]*m' '' -- $line)
        # Extract PR number - look for #NNN pattern anywhere in the line
        set pr_num (echo $clean | sed -n 's/.*#\([0-9]\+\).*/\1/p')
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

    # Merge each selected PR with retry logic
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
            gh pr merge $pr_num --merge --delete-branch

            if test $status -eq 0
                echo "Successfully merged PR #$pr_num"
                set merge_success true
                break
            else
                set retry_count (math $retry_count + 1)
                if test $retry_count -lt $max_retries
                    echo "Merge failed (attempt $retry_count/$max_retries). Retrying in 2 seconds..."
                    sleep 2
                else
                    echo "Failed to merge PR #$pr_num after $max_retries attempts"
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
        echo "All PRs merged successfully!"
        return 0
    end
end
