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
