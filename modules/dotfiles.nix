{ config, pkgs, lib, username, ... }:

# The Nix-only half of the chezmoi dotfiles setup: a single generated config file. The dotfiles
# SOURCE now lives in THIS repo under ./dotfiles — chezmoi finds it via the repo-root
# ./.chezmoiroot redirect — so there is no longer a separate private repo to clone. The
# ORCHESTRATION (rebuild → chezmoi apply) lives in mise.toml as `mise run apply`; with the source
# already on disk inside the checkout, that step is now just `chezmoi apply`.
#
#   chezmoi PLUMBING (~/.config/chezmoi/chezmoi.toml) — generated here. chezmoi never writes its
#   own config, so this is NOT a chezmoi-managed dotfile and does NOT collide with the chezmoi
#   boundary (hypr/fish/waybar etc.). Machine-local config that belongs in Nix. It pins:
#     - sourceDir → this flake checkout, so chezmoi reads ./.chezmoiroot (→ ./dotfiles) from there.
#     - the age identity + recipient pubkey so `chezmoi apply` can decrypt the one .age secret.
#
# Peers, not nested: Nix and chezmoi share this repo but neither applies/templates the other's
# tree (chezmoi never sees ./flake.nix etc.; the flake never renders ./dotfiles). User secrets
# stay age-encrypted at rest in ./dotfiles; system secrets stay in sops-nix.
#
# ONE-TIME setup on a real host (inherent to the secrets model):
#   - The age IDENTITY that decrypts dotfile secrets is placed by `mise run secrets:key-bootstrap`
#     (pulled from Bitwarden) at ~/.config/age/age.agekey — the same single key as sops-nix.
let
  home   = "/home/${username}";
  ageKey = "${home}/.config/age/age.agekey";
  # LOAD-BEARING: chezmoi's sourceDir. The flake must be checked out at this path so chezmoi can
  # read ./.chezmoiroot (→ ./dotfiles). Single binding, in the spirit of `username` in flake.nix.
  repoDir = "${home}/repos/nixos-configs";
  recipient = "age1cmyzv35xnw2kuv3crmta5xkfy06e2fysygwcn8vxq32enqrs0sestp3f7w";
in
{
  # chezmoi plumbing — NOT a managed dotfile (see header). Points at the repo checkout (whose
  # .chezmoiroot redirects to ./dotfiles), the hand-placed age identity, and the recipient pubkey.
  home-manager.users.${username}.xdg.configFile."chezmoi/chezmoi.toml".text = ''
    sourceDir = "${repoDir}"
    encryption = "age"
    [age]
      identity  = "${ageKey}"
      recipient = "${recipient}"
  '';
}
