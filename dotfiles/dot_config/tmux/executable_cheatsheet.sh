#!/usr/bin/env bash
# Searchable cheat sheet of the live tmux server's keybinds (prefix+?).
# Joins `list-keys -N` (the human note a bind declares via -N) against plain
# `list-keys` (the real command) so both sit on one line. Binds WITHOUT a
# note — mostly plugin-installed ones — aren't hidden; they sink below the
# noted ones with "—" in the note column. Only the prefix and copy-mode-vi
# tables: root is almost entirely mouse binds with screen-length menu
# commands that drown everything else.
# `--list` prints the raw table for grepping outside a TTY/fzf.
set -euo pipefail

build() {
    for t in prefix copy-mode-vi; do
        # -P '' strips the "C-a " the -N listing prepends to prefix-table keys;
        # plain list-keys escapes special keys (\" \;) where -N does not, so
        # drop the leading backslash before joining.
        awk -v t="$t" '
            NR == FNR {
                key = $1; $1 = ""; sub(/^ +/, "")
                note[key] = $0
                next
            }
            {
                key = ""
                for (i = 1; i <= NF; i++) if ($i == "-T") { key = $(i + 2); cs = i + 3; break }
                if (key == "") next
                sub(/^\\/, "", key)
                cmd = ""
                for (i = cs; i <= NF; i++) cmd = cmd $i " "
                line = sprintf("%-13s %-12s %-46s %s", t, key, (key in note ? note[key] : "—"), cmd)
                if (key in note) print line; else deferred = deferred line "\n"
            }
            END { printf "%s", deferred }
        ' <(tmux list-keys -N -P '' -T "$t" 2>/dev/null) <(tmux list-keys -T "$t")
    done
}

if [ "${1:-}" = "--list" ]; then
    build
    exit 0
fi

build | fzf --reverse --no-sort \
    --prompt='keybinds> ' \
    --header='table | key | what it does | actual command — type to filter, Esc closes'
