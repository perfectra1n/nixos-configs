# ── helper: resolve channel/version to a concrete version ────────────────────
function __ce_resolve_version
    set -l target $argv[1]
    test -z "$target"; and set target latest
    switch "$target"
        case stable latest
            set -l ver (curl -fsSL "$__CE_GCS/$target" 2>/dev/null | string trim)
            if test -z "$ver"
                __ce_err "Failed to resolve channel '$target'"
                return 1
            end
            echo $ver
        case '*'
            echo $target
    end
end
