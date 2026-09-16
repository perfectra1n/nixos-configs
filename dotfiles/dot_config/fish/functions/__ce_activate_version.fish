# ── core: activate a version (symlink) ────────────────────────────────────────
function __ce_activate_version
    set -l ver $argv[1]
    set -l bin (__ce_version_bin $ver)

    if not test -x "$bin"
        __ce_err "Version $ver is not installed"
        return 1
    end

    mkdir -p (dirname "$CLAUDE_EDGE_BIN")
    rm -f "$CLAUDE_EDGE_BIN"
    ln -sf "$bin" "$CLAUDE_EDGE_BIN"
    __ce_info "Active version → $ver"
end
