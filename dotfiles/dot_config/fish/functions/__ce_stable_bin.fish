# ── helper: find the *stable* claude binary (not our edge one) ────────────────
function __ce_stable_bin
    for p in $PATH
        set -l candidate "$p/claude"
        if test -x "$candidate"
            set -l real_candidate (realpath "$candidate" 2>/dev/null)
            set -l real_edge (realpath "$CLAUDE_EDGE_BIN" 2>/dev/null)
            if test -n "$real_candidate" -a -n "$real_edge" -a "$real_candidate" != "$real_edge"
                echo "$candidate"
                return 0
            else if test -z "$real_edge"
                echo "$candidate"
                return 0
            end
        end
    end
    return 1
end
