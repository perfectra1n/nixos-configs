{ config, pkgs, lib, inputs, ... }:

# Rebuild visibility: a package-level diff (old running system → incoming config) printed at
# every activation, and each generation stamped with the git commit that built it. Applied to
# ALL hosts via mkHost. WHY: a flake.lock bump once rebuilt xdg-desktop-portal-hyprland at the
# SAME version (store path changed, version didn't) and regressed portal screenshots — diagnosis
# needs per-switch diffs plus a generation→commit mapping. See docs/package-versioning.md.
{
  # Readable later, per generation:
  #   /nix/var/nix/profiles/system-N-link/sw/bin/nixos-version --configuration-revision
  # (`nix run .#whatchanged` prints it per change). dirtyRev (nix ≥ 2.19) covers switches
  # from a dirty tree; the literal is the last-ditch fallback.
  system.configurationRevision = inputs.self.rev or inputs.self.dirtyRev or "dirty";

  # During activation /run/current-system still points at the OLD system and $systemConfig is
  # the incoming one — exactly the pair to diff. The guard skips the two activations with no
  # old system (boot, nixos-install). supportsDryActivation → `nixos-rebuild dry-activate`
  # previews the diff without switching. --nix-bin-dir because activation PATH is minimal and
  # nvd shells out to nix for closure queries; config.nix.package matches the daemon's nix.
  system.activationScripts.diff = {
    supportsDryActivation = true;
    text = ''
      if [ -e /run/current-system ]; then
        ${pkgs.nvd}/bin/nvd --nix-bin-dir=${config.nix.package}/bin diff /run/current-system "$systemConfig"
      fi
    '';
  };
}
