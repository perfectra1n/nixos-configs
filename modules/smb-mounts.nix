{ config, pkgs, lib, username, ... }:

# CIFS/SMB mount of the TrueNAS share //192.168.2.155/main_smb at /mnt/main_smb.
# TrueNAS exposes the ZFS dataset main_pool/main_dataset as the single SMB share `main_smb`
# (the share name, NOT the dataset path) — verified with smbclient -L. The subfolders you
# care about (smb_folder1, etc.) live inside that share, so we mount the whole share.
#
# ── No-choke design ──
# This is a NETWORK mount that some hosts (the laptop) often can't reach, so it must never
# block boot or fail activation:
#   * x-systemd.automount + noauto → systemd creates an *automount* unit; the actual mount
#     only happens on first access to /mnt/main_smb. An unreachable server just means the
#     first `ls` hangs/times out — it does NOT delay boot or break `nixos-rebuild switch`.
#   * nofail + _netdev → even the automount itself is best-effort and ordered after network.
#   * x-systemd.idle-timeout → auto-unmount after 10 min idle so a server that goes away
#     mid-session doesn't leave a wedged mount.
#
# ── Secret model ──
# CIFS reads username+password from a credentials FILE (never the kernel cmdline / nix store).
# That file is ONE sops secret `smb/main_smb_creds` decrypted to /run/secrets at activation:
#   smb:
#     main_smb_creds: |
#       username=perf3ct
#       password=<password>
# Add/edit it with `mise run secrets:edit`.
#
# Same EVAL gate as modules/nextcloud-vfs.nix: the sops secret is only DECLARED once
# secrets.yaml actually contains `smb_creds` (sops keeps YAML keys in plaintext, only values
# are encrypted, so a raw readFile detects it). Declaring a secret whose key isn't in the
# file makes sops activation fail and bricks `nixos-rebuild`; until the secret lands this
# module adds nothing but the cifs-utils package, so a fresh checkout still builds CI-green.
let
  secretsFile = builtins.readFile ../secrets/secrets.yaml;
  secretsReady = !(lib.hasInfix "replace me with" secretsFile);
  secretPresent = lib.hasInfix "smb_creds" secretsFile;
  declareSecret = secretsReady && secretPresent;

  # sops-nix default location for a `name/subname` secret. Hardcoded (not the `.path` attr)
  # because the secret is only conditionally declared — referencing `.path` when undeclared
  # would error at eval.
  credsPath = "/run/secrets/smb/main_smb_creds";
in
{
  config = lib.mkMerge [
    {
      # mount.cifs helper (the kernel cifs module is built-in; this is the userspace mounter).
      environment.systemPackages = [ pkgs.cifs-utils ];
    }

    (lib.mkIf declareSecret {
      # root-only: the mount runs as root at automount trigger time.
      sops.secrets."smb/main_smb_creds".mode = "0400";

      fileSystems."/mnt/main_smb" = {
        device = "//192.168.2.155/main_smb";
        fsType = "cifs";
        options = [
          # On-demand, never-block-boot mount — see the no-choke note above.
          "noauto"
          "nofail"
          "_netdev"
          "x-systemd.automount"
          "x-systemd.idle-timeout=600"
          "x-systemd.mount-timeout=15s"   # don't hang forever when the server is gone
          # username/password from the sops credentials file — never in the nix store.
          "credentials=${credsPath}"
          # Map all files to the login user so it's read/write without sudo. mount.cifs
          # resolves the username/group names to ids itself.
          "uid=${username}"
          "gid=users"
          "file_mode=0664"
          "dir_mode=0775"
          "vers=3.1.1"                    # TrueNAS supports SMB3; pin it to skip dialect probing
        ];
      };
    })
  ];
}
