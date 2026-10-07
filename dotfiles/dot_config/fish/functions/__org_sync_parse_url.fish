# Split a git remote URL into two lines: host (lowercased) and owner/repo path
# (case kept, .git stripped). Handles https://, ssh:// and scp-style git@host:path,
# so org-sync can compare remotes by WHERE they point, not by their spelling.
function __org_sync_parse_url
    set -l u (string trim -- $argv[1])
    # scp-style "git@host:owner/repo" has no scheme — normalize it to ssh://.
    if string match -qr '^[^/:@]+@[^/:]+:' -- $u
        set u (string replace -r '^[^@]+@([^:]+):' 'ssh://$1/' -- $u)
    end
    set -l m (string match -r '^[a-z+]+://(?:[^@/]+@)?([^/:]+)(?::\d+)?/(.+?)(?:\.git)?/*$' -- $u)
    test (count $m) -eq 3; or return 1
    string lower -- $m[2]
    echo $m[3]
end
