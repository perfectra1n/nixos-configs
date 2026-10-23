{ config, pkgs, lib, username, ... }:

# Headless server baseline — every headless host (`server`, `kanbot-1`). No desktop, no audio.
# SSH-first, with a few extra ops conveniences. Docker + OpenSSH come from modules/common.nix.
{
  # Key-only SSH (no passwords over the network). Local console password still works.
  services.openssh.settings = {
    PasswordAuthentication = false;
    KbdInteractiveAuthentication = false;
    PermitRootLogin = "prohibit-password";
  };

  # Passwords are off just above, so without a key here a headless box is reachable only at its
  # console. A PUBLIC key is safe in this public repo. The user, not root: sudo is passwordless
  # (modules/common.nix), so root keys would add an attack surface and no capability.
  users.users.${username}.openssh.authorizedKeys.keys = [
    "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDWu0SgWvvJHwSImVvetpMZhaIanwZwMMd/vLfIUBI6NjOEAnCvLdD9HwFhy0P2Zcal5Vwf+g5ueGR+N2SK3XmgExTmAgKUTHXNxRBdN4Q6YNh62gz6qiSchIOpN8kzilA2ektzW271vnGzTNHSvKSwDFe94SsnTe7GqSEzQOueXmPYU3QDlRiSgMsLC9d5bVrLjxFCaiPObyia7NYuN0p3eYRlHtAEDAekdadircGMSfyCbGz3EZf4MXSLruhp2bx2XGykWsv0au6cwtaV7zSmmZI2n83hFnTZomzRlbXrb2PdxfUyDEf950w5f5blgfsk5bs2QULw8Cu1wBB3lEAb"
  ];

  # Headless boxes should stay reachable through transient errors — keep the OOM
  # killer and journald sane, and don't sleep.
  systemd.targets = {
    sleep.enable = false;
    suspend.enable = false;
    hibernate.enable = false;
    hybrid-sleep.enable = false;
  };

  # Trim journald so logs don't fill a small root disk.
  services.journald.settings.Journal.SystemMaxUse = "500M";

  environment.systemPackages = with pkgs; [
    htop
    tmux
    rsync
    dnsutils
  ];
}
