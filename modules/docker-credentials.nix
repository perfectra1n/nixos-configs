{ config, lib, username, secrets, ... }:

# Renders ~/.docker/config.json's content from sops so `docker pull/push` to the two Gitea
# instances + ghcr.io works non-interactively, without a plaintext token ever living on disk.
# The home-manager side (the ~/.docker/config.json symlink) lives in home/docker.nix.
#
# WHY a pre-base64'd secret (not interpolate user+token like git-credentials does): Docker's
# config.json stores `auths.<registry>.auth = base64("user:token")`. We CANNOT base64-encode at
# Nix eval — a sops placeholder isn't the real value until sops substitutes it at activation, so
# base64-ing the placeholder then asking sops to find it inside the blob fails. So the secret
# VALUE we store IS the finished base64 "user:token" blob (no more sensitive than the raw token):
#     printf '%s:%s' perf3ct <token> | base64 -w0
#
# WHY not just point DOCKER_CONFIG at /run/secrets: unlike git (which only READS its helper file),
# `docker build` (buildx) WRITES state under $DOCKER_CONFIG. A read-only /run dir would break it.
# So home/docker.nix symlinks only config.json and leaves ~/.docker writable.
#
# COUPLING: the two Gitea registry hostnames reuse the git/*_host placeholders declared in
# git-credentials.nix (keeps the duck host encrypted, consistent with git creds). So this module
# must ride alongside git-credentials.nix — both are listed on desktop + laptop in flake.nix.
#
# EVAL GATE: same tolerate-missing-secret trick as git-credentials.nix — declare the secrets +
# template ONLY once secrets.yaml actually holds the docker/* keys, so a fresh checkout that lacks
# them doesn't brick sops activation / `nixos-rebuild`. Inert until `mise run secrets:pull`.
let
  # sops keeps YAML KEYS in plaintext (only values are encrypted), so this needs no age identity.
  declareSecret = secrets.has "docker/main_gitea_auth";

  ph = name: config.sops.placeholder.${name};
in
lib.mkIf declareSecret {
  # owner=user so the user's docker CLI can read the rendered file.
  sops.secrets = {
    "docker/main_gitea_auth" = { };
    "docker/duck_gitea_auth" = { };
    "docker/ghcr_auth" = { };
    "docker/dockerhub_auth" = { };
  };

  sops.templates."docker-config" = {
    owner = username;
    mode = "0400"; # read-only: creds are declarative, `docker login` never writes them back here
    path = "/run/secrets/rendered/docker-config.json"; # pinned so home/docker.nix's symlink is stable
    content = ''
      {
        "auths": {
          "${ph "git/main_gitea_host"}": { "auth": "${ph "docker/main_gitea_auth"}" },
          "${ph "git/duck_gitea_host"}": { "auth": "${ph "docker/duck_gitea_auth"}" },
          "ghcr.io": { "auth": "${ph "docker/ghcr_auth"}" },
          "https://index.docker.io/v1/": { "auth": "${ph "docker/dockerhub_auth"}" }
        }
      }
    '';
  };
}
