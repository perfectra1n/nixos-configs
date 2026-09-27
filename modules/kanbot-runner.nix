{ config, pkgs, lib, username, secrets, ... }:

# `kanbot runner` — this box hosts the Claude Code sessions of the kanbot daemon that runs in the
# cluster (homelab-ops, kubernetes/apps/kanbot). The runner dials OUT to the daemon over a
# WebSocket, so it works across NAT and suspend and reconnects by itself; the daemon launches
# sessions here in tmux (`tmux -L kanbot`), in this box's checkouts, with this box's claude.
# Mirrors upstream's deploy/systemd/kanbot-runner.service, NixOS-shaped.
#
# ── Where each piece lives (CLAUDE.md's ownership tree) ──
#   binary        pkgs/kanbot.nix — a launcher that installs the pinned release on first use
#                 (see that file for why it cannot be a build-time fetch)
#   fetch creds   sops, REUSED: git/main_gitea_host + docker/main_gitea_auth are already the
#                 Gitea hostname and a base64 user:token blob — exactly an HTTP Basic header.
#                 No new secret; the hostname stays out of this public repo.
#   config.toml,  chezmoi, age-encrypted (dotfiles/dot_config/private_kanbot/): user config in
#   env,          ~/.config belongs to chezmoi, and all three are secret or name private hosts
#   runner.token  (the runner token authenticates this box to the daemon).
#
# EVAL GATE: same as docker-credentials.nix — nothing is declared until secrets.yaml holds the
# keys, so a fresh checkout evaluates green. RUNTIME GATE: ConditionPathExists on the runner
# token, like rclone-mounts.nix — until `chezmoi apply` lands it, the unit is *skipped*, not
# failed, so there is no crash loop on a box that hasn't been set up.
let
  declareSecret = secrets.has "git/main_gitea_host" && secrets.has "docker/main_gitea_auth";

  ph = name: config.sops.placeholder.${name};

  fetchEnv = "/run/secrets/rendered/kanbot-fetch.env";
  kanbot = import ../pkgs/kanbot.nix { inherit pkgs fetchEnv; };
in
lib.mkIf declareSecret {
  # Already declared by git-credentials.nix / docker-credentials.nix; re-declaring the same
  # names merges, and keeps this module from depending on theirs being listed.
  sops.secrets = {
    "git/main_gitea_host" = { };
    "docker/main_gitea_auth" = { };
  };

  # owner=user: the launcher runs as the user, from the service or an interactive shell.
  sops.templates."kanbot-fetch.env" = {
    owner = username;
    mode = "0400";
    path = fetchEnv;
    content = ''
      KANBOT_FETCH_HOST=${ph "git/main_gitea_host"}
      KANBOT_FETCH_AUTH=${ph "docker/main_gitea_auth"}
    '';
  };

  # On PATH too: `kanbot doctor --runner`, and `kanbot open`-style one-offs.
  users.users.${username}.packages = [ kanbot ];

  systemd.user.services.kanbot-runner = {
    description = "kanbot runner: hosts Claude Code sessions for the cluster's kanbot";
    wantedBy = [ "default.target" ];
    unitConfig.ConditionPathExists = "%h/.config/kanbot/runner.token";

    # Sessions inherit this PATH (through the tmux server the runner starts), so it must reach
    # everything a session runs: claude (~/.local/bin, native installer), gea/fjo (~/.cargo/bin),
    # and the Nix-installed tmux/git/gh/tea/fj. mkForce because NixOS writes every unit's PATH
    # from its `path` option; this one must REPLACE that (a store-only PATH has no claude),
    # and /run/current-system/sw/bin still carries the coreutils/grep/sed that default gives.
    environment = {
      PATH = lib.mkForce (lib.concatStringsSep ":" [
        "%h/.local/bin"
        "%h/.cargo/bin"
        "/etc/profiles/per-user/${username}/bin"
        "/run/current-system/sw/bin"
      ]);
      RUST_LOG = "info,kanbot=debug";
    };

    serviceConfig = {
      Type = "simple";
      ExecStart = "${lib.getExe kanbot} runner";
      # Mode 0600, chezmoi-managed: what sessions need that must not live in config.toml
      # (the Anthropic gateway + token). Optional, as upstream.
      EnvironmentFile = "-%h/.config/kanbot/env";

      # A revoked token or an incompatible server makes `kanbot runner` exit non-zero (retrying
      # can't help); anything else it retries itself. Restart slowly: not a hot loop.
      Restart = "on-failure";
      RestartSec = "30s";
      TimeoutStopSec = "15s";

      # Sessions live in the tmux server the runner starts, inside this unit's cgroup.
      # KillMode=process signals only the runner, so a restart (or a rebuild that changes the
      # unit) leaves every session running; the daemon re-adopts them on reconnect.
      KillMode = "process";

      # Inherited by the tmux server and so by every session — upstream's choice, kept as-is.
      NoNewPrivileges = true;
      PrivateTmp = false;
      PrivateUsers = true;
      ProtectSystem = "full";
    };
  };
}
