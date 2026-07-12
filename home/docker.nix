{ config, lib, osConfig, ... }:

# Points ~/.docker/config.json at the sops-rendered registry auth (modules/docker-credentials.nix).
#
# An out-of-store symlink (not a home.file copy) so the secret stays only on tmpfs in /run, never
# in the nix store. ~/.docker itself stays a real, writable directory — home-manager manages only
# this one file — so `docker build` (buildx state under ~/.docker/buildx) keeps working. No chezmoi
# collision: .docker is already in dotfiles/.chezmoiignore.
#
# EVAL GATE: gate on the RENDERED TEMPLATE existing, not on a second, parallel read of
# secrets.yaml. The symlink's only real dependency is that modules/docker-credentials.nix actually
# declared the template — so ask that module, via osConfig, instead of re-deriving the same
# conclusion from the raw YAML and hoping the two stay in agreement. This makes a skew between the
# two files impossible rather than merely unlikely: no template, no symlink, by construction.
lib.mkIf (osConfig.sops.templates ? "docker-config") {
  home.file.".docker/config.json" = {
    source = config.lib.file.mkOutOfStoreSymlink "/run/secrets/rendered/docker-config.json";
    # force: overwrite a pre-existing ~/.docker/config.json from an earlier `docker login`.
    # HM refuses to clobber files it didn't create; here the sops-rendered file is authoritative
    # (auths only), so we take ownership instead of erroring on every box that has logged in.
    force = true;
  };
}
