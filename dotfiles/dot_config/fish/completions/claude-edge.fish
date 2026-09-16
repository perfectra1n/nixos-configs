# Completions for claude-edge (functions/claude-edge.fish). The `use` candidates come from
# __ce_installed_versions, autoloaded on first Tab; it reads $CLAUDE_EDGE_DIR from conf.d/claude-edge.fish.
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
