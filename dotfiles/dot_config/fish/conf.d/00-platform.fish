# Platform detection for the guarded conf.d files (20-aliases-*.fish, 30-os-*.fish). fish sources
# conf.d/ alphabetically, so this runs first and each platform file just checks $__platform and
# `return`s if it isn't theirs — no central dispatcher to keep in sync. The values mirror what
# config.fish's old uname switch distinguished: the amzn/centos work-box flavours never got the
# homelab linux env file and still don't.
#   linux | linux-wsl | linux-amzn | linux-centos | darwin | bsd
# Not exported: it's shell-local state, nothing spawned needs it.
set -l os (uname -s | string lower)
switch $os
    case linux
        set -g __platform linux
        if test -n "$IS_WSL"; or test -n "$WSL_DISTRO_NAME"
            set -g __platform linux-wsl
        else if test -r /etc/os-release
            string match -q 'ID="amzn"' < /etc/os-release; and set -g __platform linux-amzn
            string match -q 'ID="centos"' < /etc/os-release; and set -g __platform linux-centos
        end
    case darwin
        set -g __platform darwin
    case dragonfly freebsd netbsd openbsd
        set -g __platform bsd
    case '*'
        set -g __platform $os
end
