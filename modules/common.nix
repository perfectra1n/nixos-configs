{ config, pkgs, lib, username, ... }:

# Universal base — applied to EVERY host (desktop, laptop, server, wsl).
# Only things that make sense everywhere belong here. Graphical-only and
# host-specific settings live in the desktop modules / hosts/<name>.
let
  # Pinned out-of-tree CLIs (kubectl/talosctl): version + hash come from nvfetcher's
  # generated sources (single source of truth, bumped by Renovate — see nvfetcher.toml).
  # Both are static Go binaries, so just install the fetched file — no build, no patchelf.
  sources = pkgs.callPackage ../_sources/generated.nix { };
  mkBin = name: pkgs.stdenvNoCC.mkDerivation {
    inherit (sources.${name}) pname version src;
    dontUnpack = true;
    installPhase = "install -Dm755 $src $out/bin/${name}";
  };

  # krew (kubectl plugin manager). nixpkgs ships only the `krew` binary, but `kubectl krew`
  # needs `kubectl-krew` on PATH — expose both via symlinks. Plugins install to ~/.krew/bin.
  kubectl-krew = pkgs.runCommand "kubectl-krew" { } ''
    mkdir -p $out/bin
    ln -s ${pkgs.krew}/bin/krew $out/bin/krew
    ln -s ${pkgs.krew}/bin/krew $out/bin/kubectl-krew
  '';

  # ksops — viaduct-ai/kustomize-sops: the kustomize KRM plugin that decrypts SOPS-encrypted
  # secrets during `kustomize build --enable-alpha-plugins --enable-exec`. Not in nixpkgs, so
  # fetch the upstream prebuilt static Go binary. Unlike kubectl/talosctl it ships as a release
  # tarball, so we unpack here rather than using mkBin — but version/src/hash come from nvfetcher
  # (bumped by Renovate, see nvfetcher.toml) like the other pins.
  ksops = pkgs.stdenvNoCC.mkDerivation {
    inherit (sources.ksops) pname version src;
    sourceRoot = ".";           # flat tarball: LICENSE/README/ksops at root, no top-level dir
    dontConfigure = true;
    dontBuild = true;
    installPhase = "install -Dm755 ksops $out/bin/ksops";
  };
in
{
  # ── Nix / locale ──
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # Auto garbage-collection (all hosts): weekly GC keeping the last 14 days of generations,
  # plus store dedup (hardlink identical files) on every build. Stops generations + the store
  # ballooning. `--delete-older-than 14d` keeps a rollback window — lower it to keep less history.
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };
  nix.settings.auto-optimise-store = true;

  nixpkgs.config.allowUnfree = true; # google-chrome, vscode, terraform, …
  # bitwarden-desktop (home/gui.nix) bundles Electron 39, which Nix now refuses to eval as
  # EOL — upstream hasn't bumped it yet (nixpkgs#529107). Permit it until they do. Inert on
  # headless hosts that never pull Electron. Match the exact version from your eval error.
  nixpkgs.config.permittedInsecurePackages = [ "electron-39.8.10" ];
  time.timeZone = "America/Los_Angeles";
  i18n.defaultLocale = "en_US.UTF-8";

  # ── Native-lib discovery for mise/cargo builds (no nix devShell) ──
  # openssl-sys & friends shell out to pkg-config; point it at OpenSSL's .pc files.
  # pkg-config + openssl themselves are in home.packages. Set here (not home-manager)
  # because programs.fish is NixOS-managed and this module translates the var into fish.
  environment.sessionVariables = {
    PKG_CONFIG_PATH = "${pkgs.openssl.dev}/lib/pkgconfig";
  };

  # ── User (shared) ──
  # Graphical modules append more groups to this same user via
  # users.users.<name>.extraGroups (list options merge across modules).
  users.users.${username} = {
    isNormalUser = true;
    description = username;
    extraGroups = [ "wheel" "docker" ];
    shell = pkgs.fish;
    # To manage the password declaratively, generate a hash, store it in sops
    # (secrets/secrets.yaml under "passwords/${username}"), flip mutableUsers
    # to false below, and uncomment:
    # hashedPasswordFile = config.sops.secrets."passwords/${username}".path;
  };
  programs.fish.enable = true;

  # mutableUsers = true (default): the install-time password is preserved across the
  # first flake switch and never lives in the repo. Flip to false once you manage the
  # password via sops (see the user block above + secrets/secrets.yaml).
  # users.mutableUsers = false;

  # Don't pop the X11 GUI password dialog — NixOS sets SSH_ASKPASS whenever X is
  # enabled, which makes git/ssh prompt in a window. Off → they prompt in the terminal.
  programs.ssh.enableAskPassword = false;

  # Passwordless sudo for the user. Note: anything running as this user gets root with
  # no prompt — fine for a personal box, but it is a real privilege boundary removed.
  security.sudo.extraRules = [
    {
      users = [ username ];
      commands = [ { command = "ALL"; options = [ "NOPASSWD" ]; } ];
    }
  ];

  # ── sops-nix (secrets) ──
  # Single-key model: ONE age identity decrypts every secret on every host. It's
  # pulled from Bitwarden onto a fresh box by `mise run secrets:key-bootstrap`, landing at
  # keyFile below — so a new host decrypts on first rebuild with no enrollment.
  # sshKeyPaths is kept as a fallback (works if a host's SSH-derived age recipient is
  # ever added to .sops.yaml), but keyFile is the primary identity.
  # Nothing is decrypted until you actually declare a `sops.secrets.*` entry, so this
  # wiring is inert on a fresh checkout (CI eval stays green).
  sops.defaultSopsFile = ../secrets/secrets.yaml;
  sops.age.keyFile = "/var/lib/sops-nix/key.txt";
  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
  # secrets.yaml holds real sops-encrypted content now, so eval-time validation is back
  # on (the default) — it catches a malformed/hand-mangled secrets file at eval instead
  # of at activation. Validation checks sops STRUCTURE only, no key needed: CI stays green.
  sops.validateSopsFiles = true;

  # ── Docker (all hosts; works under WSL too) ──
  virtualisation.docker.enable = true;
  # Disable the containerd image store (Docker 28+/29 default). Its overlayfs
  # snapshotter exporter deadlocks on images with duplicate-content layers
  # ("failed to open writer: ref … locked … unavailable") — deterministic, e.g.
  # the Tyrfing dev image builds. The classic overlay2 image store has no such
  # bug. Drop this line once the upstream containerd-snapshotter export bug is
  # fixed and re-evaluate.
  virtualisation.docker.daemon.settings.features.containerd-snapshotter = false;

  # ── nix-ld: run foreign dynamic binaries (mise runtimes, downloaded ELFs) ──
  programs.nix-ld.enable = true;

  # ── nethogs without sudo ──
  # nethogs (home/common.nix) needs cap_net_admin+cap_net_raw to open packet sockets.
  # `setcap` on the store path doesn't survive rebuilds, so ship a capability wrapper
  # instead — /run/wrappers/bin precedes the HM profile in PATH, so plain `nethogs`
  # picks it up. `+p` only (not +ep): the NixOS wrapper raises permitted→ambient itself,
  # same as nixpkgs' iftop/mtr modules.
  security.wrappers.nethogs = {
    owner = "root";
    group = "root";
    capabilities = "cap_net_admin,cap_net_raw+p";
    source = lib.getExe pkgs.nethogs;
  };

  # ── FHS-style /bin and /usr/bin via envfs ──
  # Maps /bin/* and /usr/bin/* to whatever is on PATH, so Debian-style shebangs in
  # chezmoi scripts (#!/bin/bash, #!/usr/bin/perl) work without rewriting them.
  services.envfs.enable = true;

  # ── OpenSSH server — installed and started on boot on every host ──
  # Defaults: root login key-only (prohibit-password); openFirewall opens TCP 22.
  # (On WSL, port 22 can clash with Windows' own sshd — change services.openssh.ports.)
  services.openssh.enable = true;

  # ── Firewall — DISABLED on every host ──
  # Relying on network-level controls. Re-enable with `networking.firewall.enable = true`.
  networking.firewall.enable = false;

  # ── Minimal base packages; everything else is in home-manager ──
  # psmisc → killall/pstree/fuser; wireguard-tools → wg/wg-quick; zip/unzip → archives
  # (NOT in the NixOS base); cmake → some things self-compile; file → libmagic.
  environment.systemPackages = with pkgs; [
    git vim curl wget bash psmisc wireguard-tools
    zip unzip gzip gnutar
    cmake file
    ntfs3g              # ntfslabel / mkfs.ntfs / ntfsfix — NTFS tooling, run under sudo on block devices
    nvfetcher           # regenerates _sources/generated.nix (bump out-of-tree pin versions/hashes)
    sops age ssh-to-age # edit secrets + derive host age keys from SSH host keys
    (mkBin "kubectl") (mkBin "talosctl") # pinned via nvfetcher (see let above)
    kubectl-krew        # krew (kubectl plugin manager): `krew` + `kubectl-krew`; plugins → ~/.krew/bin
    ksops               # kustomize SOPS plugin (defined in `let` above) — decrypts SOPS secrets in kustomize builds
  ];

  # mkDefault so a host installed on a different release can override it.
  system.stateVersion = lib.mkDefault "25.05";
}
