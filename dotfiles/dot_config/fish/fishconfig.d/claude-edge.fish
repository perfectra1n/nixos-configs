#!/usr/bin/env fish
# claude-edge.fish — Manage multiple Claude Code versions side-by-side
#
# INSTALL
#   1. Copy this file to ~/.config/fish/fishconfig.d/claude-edge.fish
#   2. Ensure config.fish sources it (or `source` it once)
#   3. Run:  claude-edge install
#
# COMMANDS
#   claude-edge install [VER]    – download & activate a version (default: latest)
#   claude-edge update [CHAN]    – re-download & activate latest or stable
#   claude-edge use VERSION      – switch the active version
#   claude-edge run [args...]    – launch the active version (or just type `claude-edge`)
#   claude-edge run -V VER [..] – launch a specific installed version
#   claude-edge versions         – show remote channels & locally installed versions
#   claude-edge list             – list locally installed versions
#   claude-edge version          – print the active version
#   claude-edge status           – show stable & edge info side-by-side
#   claude-edge diff             – compare stable vs active version strings
#   claude-edge which            – print path to the active binary
#   claude-edge clean            – remove all versions except the active one
#   claude-edge uninstall        – remove everything
#
# HOW IT WORKS
#   • Binaries are downloaded directly from the GCS distribution bucket
#     with SHA-256 checksum verification — no install.sh needed.
#   • Each version is stored in $CLAUDE_EDGE_DIR/versions/X.Y.Z/claude
#   • The active version is symlinked to $CLAUDE_EDGE_BIN
#   • Auto-updates are DISABLED so it never touches your stable install.
#     Run `claude-edge update` yourself.
#
# CONFIGURATION (set these in your config.fish *before* this file is sourced)
#   CLAUDE_EDGE_DIR   – storage root          (default: ~/.claude-edge)
#   CLAUDE_EDGE_BIN   – where the symlink goes (default: ~/.local/bin/claude-edge)

# ── defaults ──────────────────────────────────────────────────────────────────
set -q CLAUDE_EDGE_DIR; or set -g CLAUDE_EDGE_DIR "$HOME/.claude-edge"
set -q CLAUDE_EDGE_BIN; or set -g CLAUDE_EDGE_BIN "$HOME/.local/bin/claude-edge"

set -g __CE_GCS "https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases"

# ── helpers: messages ─────────────────────────────────────────────────────────
function __ce_info
    echo (set_color green)"[claude-edge]"(set_color normal)" $argv"
end
function __ce_warn
    echo (set_color yellow)"[claude-edge]"(set_color normal)" $argv" >&2
end
function __ce_err
    echo (set_color red)"[claude-edge]"(set_color normal)" $argv" >&2
end

# ── helper: detect platform ──────────────────────────────────────────────────
function __ce_platform
    set -l os
    set -l arch
    switch (uname -s)
        case Darwin; set os darwin
        case Linux;  set os linux
        case '*'
            __ce_err "Unsupported OS: "(uname -s)
            return 1
    end
    switch (uname -m)
        case x86_64 amd64;  set arch x64
        case arm64 aarch64; set arch arm64
        case '*'
            __ce_err "Unsupported arch: "(uname -m)
            return 1
    end
    if test "$os" = darwin -a "$arch" = x64
        if test (sysctl -n sysctl.proc_translated 2>/dev/null) = 1
            set arch arm64
        end
    end
    if test "$os" = linux
        if test -f /lib/libc.musl-x86_64.so.1
            or test -f /lib/libc.musl-aarch64.so.1
            or ldd /bin/ls 2>&1 | string match -q '*musl*'
            echo "linux-$arch-musl"
        else
            echo "linux-$arch"
        end
    else
        echo "$os-$arch"
    end
end

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

# ── helper: paths ─────────────────────────────────────────────────────────────
function __ce_version_dir
    echo "$CLAUDE_EDGE_DIR/versions/$argv[1]"
end

function __ce_version_bin
    echo "$CLAUDE_EDGE_DIR/versions/$argv[1]/claude"
end

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

# ── core: download a specific version ─────────────────────────────────────────
function __ce_download_version
    set -l ver $argv[1]
    set -l force $argv[2]
    set -l platform (__ce_platform); or return 1

    set -l dest_dir (__ce_version_dir $ver)
    set -l dest_bin "$dest_dir/claude"

    if test -x "$dest_bin" -a "$force" != --force
        __ce_info "Version $ver already installed"
        return 0
    end

    __ce_info "Downloading $ver for $platform …"

    set -l manifest (curl -fsSL "$__CE_GCS/$ver/manifest.json" 2>/dev/null)
    if test -z "$manifest"
        __ce_err "Failed to fetch manifest for $ver — version may not exist"
        return 1
    end

    set -l checksum
    if command -q jq
        set checksum (echo $manifest | jq -r ".platforms[\"$platform\"].checksum // empty" 2>/dev/null)
    else if command -q python3
        set checksum (echo $manifest | python3 -c "
import sys, json
m = json.load(sys.stdin)
print(m.get('platforms',{}).get('$platform',{}).get('checksum',''))
" 2>/dev/null)
    end

    if test -z "$checksum"
        __ce_err "Platform $platform not found in manifest for $ver"
        return 1
    end

    mkdir -p "$dest_dir"
    if not curl -fsSL "$__CE_GCS/$ver/$platform/claude" -o "$dest_bin"
        __ce_err "Failed to download binary"
        rm -rf "$dest_dir"
        return 1
    end

    set -l actual
    if command -q sha256sum
        set actual (sha256sum "$dest_bin" | cut -d' ' -f1)
    else
        set actual (shasum -a 256 "$dest_bin" | cut -d' ' -f1)
    end

    if test "$actual" != "$checksum"
        __ce_err "Checksum mismatch! Expected $checksum, got $actual"
        rm -rf "$dest_dir"
        return 1
    end

    chmod +x "$dest_bin"
    __ce_info "Downloaded and verified $ver ✓"
end

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

# ── main entrypoint ───────────────────────────────────────────────────────────
function claude-edge --description "Manage & run multiple Claude Code versions"
    set -l sub $argv[1]
    set -l rest $argv[2..-1]

    switch "$sub"
        case install
            set -l target $rest[1]
            test -z "$target"; and set target latest
            set -l ver (__ce_resolve_version $target); or return 1
            __ce_info "Resolved '$target' → $ver"
            __ce_download_version $ver; or return 1
            __ce_activate_version $ver; or return 1
            __ce_info "Run with:  claude-edge"

        case update up upgrade
            set -l target $rest[1]
            test -z "$target"; and set target latest
            __ce_info "Updating ($target) …"
            set -l ver (__ce_resolve_version $target); or return 1
            __ce_info "Resolved '$target' → $ver"
            rm -rf (__ce_version_dir $ver)
            __ce_download_version $ver --force; or return 1
            __ce_activate_version $ver

        case use switch
            if test -z "$rest[1]"
                __ce_err "Usage: claude-edge use <version|channel>"
                __ce_err "Installed: "(__ce_installed_versions | string join ", ")
                return 1
            end
            set -l ver (__ce_resolve_version $rest[1]); or return 1
            if not test -x (__ce_version_bin $ver)
                __ce_err "Version $ver is not installed"
                __ce_err "Run: claude-edge install $ver"
                return 1
            end
            __ce_activate_version $ver

        case versions remote
            echo ""
            set -l _cyan  (set_color cyan)
            set -l _bold  (set_color --bold)
            set -l _dim   (set_color brblack)
            set -l _green (set_color green)
            set -l _reset (set_color normal)

            echo "  "$_bold"Remote channels:"$_reset
            set -l stable_ver (curl -fsSL "$__CE_GCS/stable" 2>/dev/null | string trim)
            set -l latest_ver (curl -fsSL "$__CE_GCS/latest" 2>/dev/null | string trim)
            test -n "$stable_ver"; and echo "    "$_cyan"stable"$_reset"  $stable_ver"
            test -n "$latest_ver"; and echo "    "$_cyan"latest"$_reset"  $latest_ver"
            echo ""

            set -l active (__ce_active_version)
            set -l installed (__ce_installed_versions)
            if test (count $installed) -gt 0
                echo "  "$_bold"Installed:"$_reset
                for v in $installed
                    set -l marker "   "
                    set -l suffix ""
                    if test "$v" = "$active"
                        set marker " "$_green"▸"$_reset
                        set suffix " "$_dim"(active)"$_reset
                    end
                    set -l tags ""
                    test "$v" = "$stable_ver"; and set tags "$tags "$_cyan"stable"$_reset
                    test "$v" = "$latest_ver"; and set tags "$tags "$_cyan"latest"$_reset
                    echo "  $marker $v$tags$suffix"
                end
            else
                echo "  "$_bold"Installed:"$_reset"  (none)"
            end

            set -l stable_bin (__ce_stable_bin)
            if test -n "$stable_bin"
                set -l sv (command "$stable_bin" --version 2>/dev/null | string trim)
                echo ""
                echo "  "$_bold"System claude:"$_reset"  $sv  "$_dim"($stable_bin)"$_reset
            end
            echo ""

        case list ls
            set -l active (__ce_active_version)
            set -l installed (__ce_installed_versions)
            if test (count $installed) -eq 0
                __ce_info "No versions installed"
                return 0
            end
            for v in $installed
                if test "$v" = "$active"
                    echo (set_color green)"▸ $v"(set_color normal)" (active)"
                else
                    echo "  $v"
                end
            end

        case uninstall remove
            __ce_info "Removing all edge binaries and data …"
            rm -f "$CLAUDE_EDGE_BIN"
            rm -rf "$CLAUDE_EDGE_DIR"
            __ce_info "Done. System claude untouched."

        case clean prune
            set -l active (__ce_active_version)
            set -l installed (__ce_installed_versions)
            set -l removed 0
            for v in $installed
                if test "$v" != "$active"
                    rm -rf (__ce_version_dir $v)
                    __ce_info "Removed $v"
                    set removed (math $removed + 1)
                end
            end
            if test $removed -eq 0
                __ce_info "Nothing to clean"
            else
                __ce_info "Removed $removed version(s), kept $active"
            end

        case version ver -v --version
            set -l active (__ce_active_version)
            if test -n "$active"
                echo $active
            else if test -x "$CLAUDE_EDGE_BIN"
                env DISABLE_AUTOUPDATER=1 "$CLAUDE_EDGE_BIN" --version 2>/dev/null
            else
                __ce_err "No active version. Run: claude-edge install"
                return 1
            end

        case which where path
            if test -x "$CLAUDE_EDGE_BIN"
                echo "$CLAUDE_EDGE_BIN"
                if test -L "$CLAUDE_EDGE_BIN"
                    echo "  → "(realpath "$CLAUDE_EDGE_BIN")
                end
            else
                __ce_err "Not installed."
                return 1
            end

        case status st
            echo ""
            set -l _cyan  (set_color cyan)
            set -l _dim   (set_color brblack)
            set -l _reset (set_color normal)

            set -l stable_bin (__ce_stable_bin)
            if test -n "$stable_bin"
                set -l sv (command "$stable_bin" --version 2>/dev/null | string trim)
                test -z "$sv"; and set sv "unknown"
                echo "  "$_cyan"stable"$_reset"  $sv  "$_dim"($stable_bin)"$_reset
            else
                echo "  "$_cyan"stable"$_reset"  (not found)"
            end

            set -l active (__ce_active_version)
            if test -n "$active"
                echo "  "$_cyan"edge"$_reset"    $active  "$_dim"($CLAUDE_EDGE_BIN → "(__ce_version_bin $active)")"$_reset
            else if test -x "$CLAUDE_EDGE_BIN"
                set -l ev (env DISABLE_AUTOUPDATER=1 "$CLAUDE_EDGE_BIN" --version 2>/dev/null | string trim)
                test -z "$ev"; and set ev "unknown"
                echo "  "$_cyan"edge"$_reset"    $ev  "$_dim"($CLAUDE_EDGE_BIN)"$_reset
            else
                echo "  "$_cyan"edge"$_reset"    (not installed)"
            end

            set -l installed (__ce_installed_versions)
            if test (count $installed) -gt 1
                echo ""
                echo "  "$_dim(count $installed)" versions installed (claude-edge list)"$_reset
            end
            echo ""

        case diff cmp compare
            set -l stable_bin (__ce_stable_bin)
            set -l sv ""
            set -l ev ""
            if test -n "$stable_bin"
                set sv (command "$stable_bin" --version 2>/dev/null | string trim)
            end
            set -l active (__ce_active_version)
            if test -n "$active"
                set ev $active
            else if test -x "$CLAUDE_EDGE_BIN"
                set ev (env DISABLE_AUTOUPDATER=1 "$CLAUDE_EDGE_BIN" --version 2>/dev/null | string trim)
            end

            if test -z "$sv" -a -z "$ev"
                __ce_err "Neither stable nor edge found."
                return 1
            end

            if test "$sv" = "$ev"
                __ce_info "Both at the same version: $sv"
            else
                test -n "$sv"; and __ce_info "stable → $sv"
                test -n "$ev"; and __ce_info "edge   → $ev"
            end

        case run "" -h --help help
            if test "$sub" = run
                if test (count $rest) -ge 2
                    and begin
                        test "$rest[1]" = -V; or test "$rest[1]" = --use-version
                    end
                    set -l run_ver (__ce_resolve_version $rest[2]); or return 1
                    set -l run_bin (__ce_version_bin $run_ver)
                    if not test -x "$run_bin"
                        __ce_err "Version $run_ver not installed. Run: claude-edge install $run_ver"
                        return 1
                    end
                    __ce_info "Running $run_ver"
                    env DISABLE_AUTOUPDATER=1 "$run_bin" $rest[3..-1]
                else
                    if not test -x "$CLAUDE_EDGE_BIN"
                        __ce_err "No active version. Run: claude-edge install"
                        return 1
                    end
                    env DISABLE_AUTOUPDATER=1 "$CLAUDE_EDGE_BIN" $rest
                end
            else if test "$sub" = -h; or test "$sub" = --help; or test "$sub" = help; or test -z "$sub"
                echo ""
                echo "  "(set_color --bold)"claude-edge"(set_color normal)" — multi-version Claude Code manager"
                echo ""
                echo "  "(set_color --bold)"Subcommands:"(set_color normal)
                echo "    install [VER]       Download & activate a version (default: latest)"
                echo "    update [CHANNEL]    Re-download & activate latest or stable"
                echo "    use VERSION         Switch the active version"
                echo "    run [args...]       Launch the active version"
                echo "    run -V VER [args]   Launch a specific installed version"
                echo "    versions            Show remote channels & local installs"
                echo "    list                List locally installed versions"
                echo "    version             Print the active version"
                echo "    status              Show stable & edge versions side-by-side"
                echo "    diff                Compare stable vs edge version strings"
                echo "    which               Print path to the active binary"
                echo "    clean               Remove all versions except the active one"
                echo "    uninstall           Remove everything"
                echo ""
                echo "  "(set_color --bold)"Examples:"(set_color normal)
                echo "    claude-edge install             # install latest"
                echo "    claude-edge install stable       # install current stable"
                echo "    claude-edge install 2.1.105      # install a specific version"
                echo "    claude-edge use 2.1.97           # switch active version"
                echo "    claude-edge run                  # launch active"
                echo "    claude-edge run -V 2.1.105       # launch a specific version"
                echo "    claude-edge versions             # see what's available"
                echo ""
                echo "  "(set_color --bold)"Config variables"(set_color normal)" (set before sourcing):"
                echo "    CLAUDE_EDGE_DIR   Storage root    [$CLAUDE_EDGE_DIR]"
                echo "    CLAUDE_EDGE_BIN   Symlink target  [$CLAUDE_EDGE_BIN]"
                echo ""
            end

        case '*'
            if not test -x "$CLAUDE_EDGE_BIN"
                __ce_err "No active version. Run: claude-edge install"
                return 1
            end
            env DISABLE_AUTOUPDATER=1 "$CLAUDE_EDGE_BIN" $argv
    end
end

# ── tab completions ───────────────────────────────────────────────────────────
complete -c claude-edge -f
complete -c claude-edge -n "__fish_use_subcommand" -a install   -d "Download & install a version"
complete -c claude-edge -n "__fish_use_subcommand" -a update    -d "Pull newest build from channel"
complete -c claude-edge -n "__fish_use_subcommand" -a use       -d "Switch the active version"
complete -c claude-edge -n "__fish_use_subcommand" -a versions  -d "Show remote channels & local installs"
complete -c claude-edge -n "__fish_use_subcommand" -a list      -d "List installed versions"
complete -c claude-edge -n "__fish_use_subcommand" -a run       -d "Launch edge binary"
complete -c claude-edge -n "__fish_use_subcommand" -a version   -d "Print active version"
complete -c claude-edge -n "__fish_use_subcommand" -a status    -d "Show stable & edge info"
complete -c claude-edge -n "__fish_use_subcommand" -a diff      -d "Compare stable vs edge"
complete -c claude-edge -n "__fish_use_subcommand" -a which     -d "Print binary path"
complete -c claude-edge -n "__fish_use_subcommand" -a clean     -d "Remove old versions"
complete -c claude-edge -n "__fish_use_subcommand" -a uninstall -d "Remove everything"
complete -c claude-edge -n "__fish_use_subcommand" -a help      -d "Show help"
complete -c claude-edge -n "__fish_seen_subcommand_from run"     -F
complete -c claude-edge -n "__fish_seen_subcommand_from install" -a "stable latest" -d "Channel"
complete -c claude-edge -n "__fish_seen_subcommand_from update"  -a "stable latest" -d "Channel"
complete -c claude-edge -n "__fish_seen_subcommand_from use"     -a "(__ce_installed_versions)" -d "Version"
