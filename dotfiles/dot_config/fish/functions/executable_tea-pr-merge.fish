#!/usr/bin/env fish

# Interactive PR merger for tea CLI
# Usage: tea-pr-merge.fish or create a fish function/alias

function tea-pr-merge
    # Check if tea is installed
    if not command -v tea &> /dev/null
        echo "Error: 'tea' command not found. Please install tea CLI first."
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

    echo "Fetching pull requests..."

    # Get PR list in simple format for easier parsing
    set pr_data (tea pr ls --output csv 2>&1)

    if test $status -ne 0
        echo "Error fetching PRs: $pr_data"
        return 1
    end

    # Store each PR line in an array, skipping the header
    set pr_lines
    set line_num 0
    for line in $pr_data
        set line_num (math $line_num + 1)
        if test $line_num -gt 1  # Skip CSV header
            set pr_lines $pr_lines "$line"
        end
    end

    if test (count $pr_lines) -eq 0
        echo "No pull requests found."
        return 0
    end

    # ANSI color codes
    set -l COLOR_RESET '\033[0m'
    set -l COLOR_CYAN '\033[36m'
    set -l COLOR_GREEN '\033[32m'
    set -l COLOR_YELLOW '\033[33m'
    set -l COLOR_BLUE '\033[34m'
    set -l COLOR_MAGENTA '\033[35m'
    set -l COLOR_BOLD '\033[1m'

    # Parse CSV and format for display with colors
    set formatted_prs
    for line in $pr_lines
        # Parse CSV (tea emits simple, unquoted CSV:
        #   index,title,state,author,milestone,updated,labels)
        # Only the title can contain commas, so anchor the volatile fields
        # off the END of the line (fixed positions) and treat whatever is
        # left in the middle as the title.
        set fields (string split ',' -- $line)
        if test (count $fields) -lt 7
            continue
        end

        set pr_number $fields[1]
        set pr_labels   $fields[-1]   # labels
        set pr_author   $fields[-4]   # author
        set pr_state    $fields[-5]   # state
        # Title = everything between the index and the state field.
        set pr_title (string join ',' -- $fields[2..-6])

        # Only show open PRs
        if test "$pr_state" = "open"
            # Color the PR number in cyan and bold
            set colored_pr "$COLOR_BOLD$COLOR_CYAN#$pr_number$COLOR_RESET"

            # Color the author in yellow
            set colored_author "$COLOR_YELLOW@$pr_author$COLOR_RESET"

            # Color labels based on type
            set colored_labels ""
            if test -n "$pr_labels"
                set label_prefix "["
                set label_suffix "]"
                # Color Breaking PRs in red, Dependency in green, Bug in yellow
                if string match -q "*Breaking*" -- "$pr_labels"
                    set colored_labels " $COLOR_BOLD\033[31m$label_prefix$pr_labels$label_suffix$COLOR_RESET"
                else if string match -q "*Bug*" -- "$pr_labels"
                    set colored_labels " $COLOR_YELLOW$label_prefix$pr_labels$label_suffix$COLOR_RESET"
                else if string match -q "*Dependency*" -- "$pr_labels"
                    set colored_labels " $COLOR_GREEN$label_prefix$pr_labels$label_suffix$COLOR_RESET"
                else
                    set colored_labels " $COLOR_MAGENTA$label_prefix$pr_labels$label_suffix$COLOR_RESET"
                end
            end

            # Format: #123 | Title | @author | [labels]
            # Use printf to properly handle escape sequences
            set display_line (printf "%b | %s | %b%b" "$colored_pr" "$pr_title" "$colored_author" "$colored_labels")
            set formatted_prs $formatted_prs "$display_line"
        end
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
        # Strip ANSI color codes and extract PR number (format: #123 | ...)
        set clean (string replace -ra '\x1b\[[0-9;]*m' '' -- $line)
        # Extract just the digits after the # (use sed to avoid multiple matches)
        set pr_num (echo $clean | sed -n 's/^#\([0-9]\+\).*/\1/p')
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
            tea pr merge $pr_num

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
