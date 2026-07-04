{ config, lib, ... }:

# Points ~/.docker/config.json at the sops-rendered registry auth (modules/docker-credentials.nix).
#
# An out-of-store symlink (not a home.file copy) so the secret stays only on tmpfs in /run, never
# in the nix store. ~/.docker itself stays a real, writable directory — home-manager manages only
# this one file — so `docker build` (buildx state under ~/.docker/buildx) keeps working. No chezmoi
# collision: .docker is already in dotfiles/.chezmoiignore.
#
# EVAL GATE: mirrors modules/docker-credentials.nix — only create the symlink once secrets.yaml
# holds the docker/* keys, so a host that hasn't run `secrets:pull` yet doesn't get a dangling link.
let
  secretsFile = builtins.readFile ../secrets/secrets.yaml;
  secretsReady = !(lib.hasInfix "replace me with" secretsFile);
  secretPresent = lib.hasInfix "main_gitea_auth" secretsFile;
in
lib.mkIf (secretsReady && secretPresent) {
  home.file.".docker/config.json" = {
    source = config.lib.file.mkOutOfStoreSymlink "/run/secrets/rendered/docker-config.json";
    # force: overwrite a pre-existing ~/.docker/config.json from an earlier `docker login`.
    # HM refuses to clobber files it didn't create; here the sops-rendered file is authoritative
    # (auths only), so we take ownership instead of erroring on every box that has logged in.
    force = true;
  };
}
