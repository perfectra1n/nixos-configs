# rustdesk (modules/desktop-apps.nix) fails with a src hash mismatch on current nixos-unstable.
# Upstream deleted and recreated the 1.5.0 GitHub release on 2026-09-30, moving the tag from
# a 09-28 commit to master HEAD (fada664) — after r-ryantm had already hashed the old tag
# (NixOS/nixpkgs#567710, opened 09-28, merged 10-01 with the now-unreachable hash).
#
# Pin by `rev` rather than tag so a further retag can't break us the same way. Remove this
# file once nixpkgs' rustdesk src hash moves off sha256-xuIUWxicsqCJ… (or the version bumps).
{
  nixpkgs.overlays = [
    (final: prev: {
      rustdesk = prev.rustdesk.overrideAttrs (old: {
        src = final.fetchFromGitHub {
          owner = "rustdesk";
          repo = "rustdesk";
          rev = "fada664df7a294d1d1a9ca3e7cd3637069122f17"; # what the 1.5.0 tag points at since the retag
          fetchSubmodules = true;
          hash = "sha256-1xa7X+swBIb8Lz3c6m8SeNZAiJWNCUpw+UbdSsMkeSk=";
        };
      });
    })
  ];
}
