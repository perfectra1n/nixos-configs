# ── helper: active version from symlink ───────────────────────────────────────
function __ce_active_version
    if test -L "$CLAUDE_EDGE_BIN"
        set -l target (realpath "$CLAUDE_EDGE_BIN" 2>/dev/null)
        if test -n "$target"
            string replace -r '.*/versions/([^/]+)/claude$' '$1' "$target"
            return 0
        end
    else if test -x "$CLAUDE_EDGE_BIN"
        env DISABLE_AUTOUPDATER=1 "$CLAUDE_EDGE_BIN" --version 2>/dev/null | string trim
        return 0
    end
    return 1
end
