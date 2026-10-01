# regclient (regctl lives in home/common.nix, every host) fails fixupPhase on current
# nixos-unstable with `multiple-outputs.sh: line 214: : invalid variable name`. Two
# upstream changes collided, neither broken alone:
#
# - regclient's postInstall builds its per-binary outputs by temporarily exporting
#   outputBin=bin, then `unset bin outputBin` — leaving outputBin EMPTY, not restored to
#   its default (`out`, since the package has no `bin` output).
# - stdenv's _multioutPropagateDev was refactored from a word-split string to a bash
#   array (readarray over `tr ' ' '\n'` of "$outputBin $outputInclude $outputLib"). The
#   empty outputBin now becomes an empty array ELEMENT instead of vanishing in word
#   splitting, and `${!output}` on "" is a bash error.
#
# Restoring outputBin's default after upstream's postInstall is the minimal fix and
# changes nothing about what ends up in the outputs. Still broken on nixpkgs master as of
# 2026-10-01; remove this file once regclient stops unsetting outputBin (or the stdenv
# hook skips empty entries) — check pkgs/by-name/re/regclient/package.nix.
{
  nixpkgs.overlays = [
    (final: prev: {
      regclient = prev.regclient.overrideAttrs (old: {
        postInstall = old.postInstall + ''
          outputBin=out
        '';
      });
    })
  ];
}
