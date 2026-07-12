{ config, lib, username, secrets, ... }:

# Renders ~/.git-credentials' content from sops so `git push/pull` to GitHub + the two Gitea
# instances works non-interactively, without a plaintext token ever living in a dotfile.
#
# WHY sops.templates (not a plain sops.secret): a template interpolates secret PLACEHOLDERS
# into eval-time plaintext. The tokens AND the Gitea hostnames both come from Bitwarden (see
# `mise run secrets:pull`), so even the hosts are placeholders — this .nix file hardcodes
# nothing but the two usernames and github.com. The rendered file lands on tmpfs (/run), never
# on persistent disk and never in the nix store.
#
# THE GIT SIDE LIVES IN CHEZMOI, not here. Per the chezmoi boundary, ~/.config/git/config is
# chezmoi-owned, so the helper line goes in the dotfiles repo, NOT a home-manager programs.git
# block (which would clobber-collide). Add to your gitconfig:
#     [credential]
#         helper = store --file /run/secrets/rendered/git-credentials
#
# EVAL GATE: a real secrets.yaml that lacks the git/* keys would make sops activation fail and
# brick `nixos-rebuild`. So declare the secrets + template ONLY once secrets.yaml actually holds
# them — the tolerate-missing-secret gate shared via lib/secrets.nix (see also
# modules/{nextcloud-vfs,smb-mounts,docker-credentials}.nix and home/docker.nix).
# Until `mise run secrets:init`/`secrets:pull` populates them, this module is fully inert.
let
  # sops keeps YAML KEYS in plaintext (only values are encrypted), so this needs no age identity.
  declareSecret = secrets.has "git/github_token";

  ph = name: config.sops.placeholder.${name};
in
lib.mkIf declareSecret {
  # Bare tokens + bare hostnames, owner=user so the user's git can read the rendered file.
  # main_gitea_host is additionally owner=user itself (not just via the template): the
  # ensureRepos activation script in home/common.nix reads it at runtime to build clone
  # URLs, since the hostname can't appear in this (public) repo or the nix store.
  sops.secrets = {
    "git/github_token" = { };
    "git/main_gitea_token" = { };
    "git/main_gitea_host" = { owner = username; };
    "git/duck_gitea_token" = { };
    "git/duck_gitea_host" = { };
  };

  sops.templates."git-credentials" = {
    owner = username;
    mode = "0400"; # read-only: we provide creds declaratively, git never needs to write them back
    path = "/run/secrets/rendered/git-credentials"; # pinned so the chezmoi helper line is stable
    content = ''
      https://perfectra1n:${ph "git/github_token"}@github.com
      https://perf3ct:${ph "git/main_gitea_token"}@${ph "git/main_gitea_host"}
      https://perf3ct:${ph "git/duck_gitea_token"}@${ph "git/duck_gitea_host"}
    '';
  };
}
