{ config, pkgs, lib, ... }:

# Headless server baseline — the `server` host. No desktop, no audio. SSH-first,
# with a few extra ops conveniences. Docker + OpenSSH come from modules/common.nix.
{
  # Key-only SSH (no passwords over the network). Local console password still works.
  services.openssh.settings = {
    PasswordAuthentication = false;
    KbdInteractiveAuthentication = false;
    PermitRootLogin = "prohibit-password";
  };

  # Put your public key here (or manage via sops) so you can log in once passwords
  # are off. Replace the placeholder before relying on remote SSH.
  # users.users.${"root"}.openssh.authorizedKeys.keys = [ "ssh-ed25519 AAAA... you@host" ];

  # Headless boxes should stay reachable through transient errors — keep the OOM
  # killer and journald sane, and don't sleep.
  systemd.targets = {
    sleep.enable = false;
    suspend.enable = false;
    hibernate.enable = false;
    hybrid-sleep.enable = false;
  };

  # Trim journald so logs don't fill a small root disk.
  services.journald.extraConfig = ''
    SystemMaxUse=500M
  '';

  environment.systemPackages = with pkgs; [
    htop
    tmux
    rsync
    dnsutils
  ];
}
