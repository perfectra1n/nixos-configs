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
