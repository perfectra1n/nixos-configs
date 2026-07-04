#!/usr/bin/env fish

# Interactive chezmoi front-end that thinks in 3 places instead of chezmoi verbs:
#
#   REMOTE git repo  <->  LOCAL git repo (the source)  <->  YOUR DOTFILES ($HOME)
#   (Gitea backup)        nixos-configs/dotfiles             the files apps read
#
# `cz` (no args) opens an fzf menu where every row says which two of those three
# places a change moves between. Power users can skip the menu: `cz push`,
# `cz pull`, `cz apply`, `cz capture`, `cz edit`, `cz new`, `cz status`, `cz help`.
# The plain `cz*` shortcuts (czadd/czapply/czpush/…) still exist for muscle memory;
# this is the discoverable thing that teaches you which one you wanted.

function cz --description "Interactive chezmoi wrapper (remote <-> local <-> dotfiles)"
    # ---- prerequisites ----------------------------------------------------
    if not command -v chezmoi &>/dev/null
        echo "Error: 'chezmoi' not found." >&2
        return 1
    end

    # ANSI colors (match executable_gh-pr-merge.fish style)
    set -l C_RESET '\033[0m'
    set -l C_CYAN '\033[36m'
    set -l C_GREEN '\033[32m'
    set -l C_YELLOW '\033[33m'
    set -l C_BLUE '\033[34m'
    set -l C_BOLD '\033[1m'
    set -l C_DIM '\033[2m'

    set -l src (chezmoi source-path)

    # ---- resolve the action: direct verb or fzf menu ----------------------
    set -l action
    switch "$argv[1]"
        case capture add-changed redd re-add
            set action capture
        case apply
            set action apply
        case edit
            set action edit
        case new add
            set action new
        case push
            set action push
        case pull update
            set action pull
        case status state st
            set action status
        case cd go
            set action cd
        case help explain '?'
            set action help
        case '*'
            # No (recognized) verb -> interactive menu. Needs fzf.
            if not command -v fzf &>/dev/null
                echo "Error: 'fzf' not found — needed for the interactive menu." >&2
                echo "Either install fzf, or use a verb: cz push|pull|apply|capture|edit|new|status|help" >&2
                return 1
            end
            # Menu rows: KEY tab "intent" tab "DIRECTION" tab "(real command)"
            # KEY is the first field; we split it back out after selection.
            set -l rows \
                "capture	Capture a dotfile edit into my local repo	HOME → LOCAL	(chezmoi re-add)" \
                "apply	Apply my local repo onto my dotfiles	LOCAL → HOME	(chezmoi apply)" \
                "edit	Edit a managed file	LOCAL → HOME	(chezmoi edit --apply)" \
                "new	Start managing a NEW dotfile	HOME → LOCAL	(chezmoi add)" \
                "push	Push my local repo to the remote	LOCAL → REMOTE	(git commit + push)" \
                "pull	Pull remote + refresh my dotfiles	REMOTE → LOCAL → HOME	(chezmoi update)" \
                "status	Show what's different across all 3 places	·	(czstate)" \
                "cd	Go to my local repo	·	(cd source)" \
                "help	Explain how the 3 places fit together	·	(czhelp)"

            # Pretty, column-aligned display; carry the key in a hidden first column.
            set -l display
            for r in $rows
                set -l key (string split -f1 \t -- $r)
                set -l intent (string split -f2 \t -- $r)
                set -l dir (string split -f3 \t -- $r)
                set -l cmd (string split -f4 \t -- $r)
                set display $display (printf "%b%-46s%b %b%-18s%b %b%s%b\t%s" \
                    "$C_BOLD" "$intent" "$C_RESET" \
                    "$C_CYAN" "$dir" "$C_RESET" \
                    "$C_DIM" "$cmd" "$C_RESET" \
                    "$key")
            end

            set -l picked (printf '%s\n' $display | fzf --ansi \
                --height=70% --border --layout=reverse \
                --with-nth=1 --delimiter=\t \
                --prompt="chezmoi > " \
                --header="REMOTE(Gitea) <-> LOCAL(nixos-configs/dotfiles) <-> DOTFILES(\$HOME)   |   ENTER: run  ESC: cancel")

            if test -z "$picked"
                echo "Cancelled."
                return 0
            end
            # Recover the hidden key (last tab-delimited field)
            set action (string split -f2 \t -- $picked)
    end

    # ---- actions ----------------------------------------------------------
    switch $action
        case capture
            # HOME -> LOCAL: pull edits you made to real dotfiles back into the source.
            # `chezmoi status` has TWO columns: col-1 = HOME was edited (re-add territory),
            # col-2 = the SOURCE is ahead (apply territory). ONLY offer col-1 changes — feeding
            # a source-ahead file to `re-add` clobbers your source edit with the stale HOME copy
            # (this is exactly what silently reverted an edit once). Source-ahead files are an
            # apply/push, not a capture, so we steer you there instead.
            set -l st (chezmoi status)
            set -l changed (printf '%s\n' $st | string match -r '^[^ ]. .*' | string replace -r '^.. ' '')
            set -l src_ahead (printf '%s\n' $st | string match -r '^ [^ ] .*' | string replace -r '^.. ' '')
            if test -z "$changed"
                if test -n "$src_ahead"
                    printf "%bNothing to capture from HOME — but your LOCAL repo is ahead on:%b\n" "$C_YELLOW" "$C_RESET"
                    printf "  %s\n" $src_ahead
                    printf "That's a %bcz apply%b (LOCAL → HOME) or %bcz push%b (LOCAL → REMOTE), not a capture.\n" \
                        "$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET"
                    return 0
                end
                printf "%bNothing to capture — your dotfiles already match your local repo.%b\n" "$C_GREEN" "$C_RESET"
                return 0
            end
            set -l sel
            if command -v fzf &>/dev/null
                set sel (printf '%s\n' $changed | fzf --multi --height=60% --border --layout=reverse \
                    --prompt="Capture which files? > " \
                    --header="HOME → LOCAL   |   SPACE/TAB: select  ENTER: confirm  ESC: cancel" \
                    --bind='ctrl-a:select-all,space:toggle')
            else
                set sel $changed
            end
            if test -z "$sel"
                echo "Nothing selected."
                return 0
            end
            # Targets are home-relative paths; chezmoi accepts ~/<path>.
            set -l paths
            for p in $sel
                set paths $paths "$HOME/$p"
            end
            printf "%b── preview (what would be captured into LOCAL) ──%b\n" "$C_DIM" "$C_RESET"
            chezmoi diff $paths
            read -l -P "Capture these into your local repo? [y/N] " ok
            if test "$ok" != y -a "$ok" != Y
                echo "Cancelled."
                return 0
            end
            chezmoi re-add $paths; or return $status
            printf "%bCaptured into LOCAL.%b\n" "$C_GREEN" "$C_RESET"
            read -l -P "Push to the remote now? [y/N] " push
            if test "$push" = y -o "$push" = Y
                czpush
            end

        case apply
            # LOCAL -> HOME: force the source back onto your live files.
            set -l st (chezmoi status)
            if test -z "$st"
                printf "%bNothing to apply — dotfiles already match your local repo.%b\n" "$C_GREEN" "$C_RESET"
                return 0
            end
            printf "%b── preview (what apply would change in HOME) ──%b\n" "$C_DIM" "$C_RESET"
            chezmoi diff
            read -l -P "Apply local repo onto your dotfiles? [y/N] " ok
            if test "$ok" != y -a "$ok" != Y
                echo "Cancelled."
                return 0
            end
            chezmoi apply -v

        case edit
            # Edit the LOCAL copy, then apply it straight back to HOME.
            set -l target $argv[2]
            if test -z "$target"; and command -v fzf &>/dev/null
                set target (chezmoi managed --include=files | fzf --height=70% --border --layout=reverse \
                    --prompt="Edit which managed file? > " \
                    --header="opens the LOCAL copy, applies on save (handles encrypted files)")
            end
            if test -z "$target"
                echo "Nothing selected."
                return 0
            end
            chezmoi edit --apply "$HOME/$target"

        case new
            # HOME -> LOCAL: start managing a brand-new dotfile.
            set -l path $argv[2]
            if test -z "$path"
                read -l -P "Path of the dotfile to start managing: " path
            end
            set path (string replace -r '^~' "$HOME" -- $path)
            if test -z "$path"; or not test -e "$path"
                echo "Error: '$path' does not exist." >&2
                return 1
            end
            read -l -P "Does this file contain secrets (encrypt at rest)? [y/N] " sec
            if test "$sec" = y -o "$sec" = Y
                chezmoi add --encrypt "$path"; and printf "%bAdded (encrypted) to LOCAL.%b\n" "$C_GREEN" "$C_RESET"
            else
                chezmoi add "$path"; and printf "%bAdded to LOCAL.%b\n" "$C_GREEN" "$C_RESET"
            end

        case push
            # LOCAL -> REMOTE
            printf "%b── local repo status ──%b\n" "$C_DIM" "$C_RESET"
            git -C $src status -sb
            read -l -P "Commit & push your local repo to the remote? [y/N] " ok
            if test "$ok" != y -a "$ok" != Y
                echo "Cancelled."
                return 0
            end
            czpush

        case pull
            # REMOTE -> LOCAL -> HOME
            chezmoi update -v

        case status
            czstate

        case cd
            cd $src

        case help
            czhelp

        case '*'
            echo "Unknown action: $action" >&2
            return 1
    end
end
