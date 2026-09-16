# ── helper: list installed versions ───────────────────────────────────────────
function __ce_installed_versions
    if test -d "$CLAUDE_EDGE_DIR/versions"
        for d in $CLAUDE_EDGE_DIR/versions/*/
            set -l v (basename $d)
            if test -x "$CLAUDE_EDGE_DIR/versions/$v/claude"
                echo $v
            end
        end | sort -V
    end
end
