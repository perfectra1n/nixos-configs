{ config, pkgs, lib, ... }:

# Headless kanbot runner "kanbot-1". Hardware + identity only — what this host COMPOSES (server
# baseline + dev stack + the runner) lives in ./spec.nix.
#
# ── Storage: ONE PM9A3, holding everything ──
# Root, /nix, $HOME (repos, sccache, scratch targets) and Docker's data-root all share the one
# drive — no /fast-u2-style split like the desktop, because the split there existed to get churn
# OFF a consumer NVMe, and this box has no consumer drive. The PM9A3 is the part rated for it
# (power-loss protection, ~1 DWPD), so session builds and overlay2 write amplification can land
# on it directly. Install-time choices the flake can't express: GPT with a 1G ESP + the rest as
# ext4 root, formatted `mkfs.ext4 -m 1` — the root reserve can't protect anything on a box where
# dockerd and nix-daemon both write as root, so 5% would only be stranded space.
#
# ── Bring-up runbook (on the box, after a minimal NixOS install) ──
#   1. clone this repo to ~/repos/nixos-configs (modules/dotfiles.nix pins chezmoi there)
#   2. mise run apply          — pulls the age key, captures the real hardware config, switches
#   3. where the daemon runs: `kanbot runner register` prints this runner's OWN token, once. Commit
#      it encrypted — `chezmoi encrypt --output dotfiles/.kanbot-runner-tokens/kanbot-1.token.age`
#      (stdin) — never reuse the desktop's. The runner.token template picks it up by hostname.
#   4. chezmoi apply           — lands runner.token; the runner unit's ConditionPathExists flips,
#      `systemctl --user start kanbot-runner` (or reboot — lingering starts it, see the module)
{
  imports = [ ./hardware-configuration.nix ];

  networking.hostName = "kanbot-1";

  # UEFI boot. If this box is older/BIOS, replace with:
  #   boot.loader.grub = { enable = true; device = "/dev/nvme0n1"; };
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Mainline-ish kernel, not the desktop's CachyOS one: nothing here benefits from sched_ext or
  # gaming tuning, and staying off chaotic keeps this host's closure fully on cache.nixos.org.
}
