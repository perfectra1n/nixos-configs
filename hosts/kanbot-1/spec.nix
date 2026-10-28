# What `kanbot-1` composes: the headless server baseline + the dev stack the graphical hosts carry,
# because this box exists to host kanbot's Claude Code sessions — they clone, build, push and run
# docker exactly like a session on the desktop does. A second runner ALONGSIDE the desktop's, not
# a replacement: each runner registers its own token (`kanbot runner register`), see default.nix.
# A plain spec consumed by mkHost — NOT a NixOS module, so no module imports another module.
#
# Deliberately NOT `graphical`: that drags in Hyprland, Steam, Electron apps and the CachyOS kernel
# for a box nobody sits at. The dev modules below are cherry-picked from it; every one is
# secret-gated, so a fresh checkout still evaluates green.
{ inputs, graphical }:
{
  extraModules = [
    ../../modules/server.nix
    ../../modules/kanbot-runner.nix
    ../../modules/dotfiles.nix # chezmoi: delivers ~/.config/kanbot/{config.toml,env,runner.token}, mcp.json, fish
    ../../modules/git-credentials.nix # sessions push to GitHub/Gitea/Forgejo non-interactively
    ../../modules/docker-credentials.nix # ...and pull/push the private registries
    ../../modules/rust-build-cache.nix # sccache + weekly target/ sweep — agent worktrees are the worst offenders
    ../../modules/oomd.nix # a runaway session build gets its scope killed instead of wedging the box
    # kanbot's evidence_root (config.toml) is on /mnt/main_smb — without the mount, sessions write
    # evidence into an empty local dir that nothing else ever sees.
    ../../modules/smb-mounts.nix
    # Sessions run browser tests and screenshots; the desktop's Playwright lives in the GUI-only
    # desktop-apps.nix, so this box takes the headless subset.
    ../../modules/playwright.nix
  ];
  homeModules = [ ../../home/docker.nix ];
}
