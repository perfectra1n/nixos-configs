# Completions for claude-cred. `-f` disables file completion outright: no subcommand takes a path,
# and the last thing we want is tab-completing a token or a credentials file onto the command line.

function __claude_cred_profile_names
    set --local dir $HOME/.claude/cred-profiles
    test -d $dir; or return
    for f in $dir/*.json
        basename $f .json
    end
end

complete -c claude-cred -f
complete -c claude-cred -n __fish_use_subcommand -a show -d 'active account + verified identity, redacted'
complete -c claude-cred -n __fish_use_subcommand -a whoami -d 'live account email (network)'
complete -c claude-cred -n __fish_use_subcommand -a set-refresh -d 'log in from a refresh token (silent prompt)'
complete -c claude-cred -n __fish_use_subcommand -a save -d 'snapshot the live login as a profile'
complete -c claude-cred -n __fish_use_subcommand -a use -d 'switch to a saved profile'
complete -c claude-cred -n __fish_use_subcommand -a list -d 'profiles with emails, and recent backups'
complete -c claude-cred -n __fish_use_subcommand -a doctor -d 'audit profiles vs live login (read-only)'
complete -c claude-cred -n __fish_use_subcommand -a undo -d 'restore the most recent auto-backup'

complete -c claude-cred -n '__fish_seen_subcommand_from use save' -a '(__claude_cred_profile_names)' \
    -d profile
