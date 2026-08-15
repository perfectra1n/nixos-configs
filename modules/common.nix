{ config, pkgs, lib, username, ... }:

# Universal base — applied to EVERY host (desktop, laptop, server).
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

  # Builds must never make the desktop unusable. Defaults are max-jobs=auto + cores=0 — every build
  # is entitled to all 24 threads AND runs at normal priority, so it competes with Hyprland, a game,
  # or a browser as an equal (a from-source blender, home/gui.nix, was what surfaced this: the box
  # became unusable and the compile had to be killed). SCHED_IDLE fixes the interactivity without
  # the permanent tax of capping cores: the kernel hands build threads only CPU that nothing else
  # wants, so a build still saturates an idle machine and finishes just as fast, but yields
  # instantly the moment anything interactive runs. IO likewise, so a big store write can't stall
  # the desktop. Applies to nix-daemon's children = every build on every host.
  nix.daemonCPUSchedPolicy = "idle";
  nix.daemonIOSchedClass = "idle";

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

  # ── Docker (all hosts) ──
  virtualisation.docker.enable = true;
  # Disable the containerd image store (Docker 28+/29 default). Its overlayfs
  # snapshotter exporter deadlocks on images with duplicate-content layers
  # ("failed to open writer: ref … locked … unavailable") — deterministic, e.g.
  # the Tyrfing dev image builds. The classic overlay2 image store has no such
  # bug. Drop this line once the upstream containerd-snapshotter export bug is
  # fixed and re-evaluate.
  virtualisation.docker.daemon.settings.features.containerd-snapshotter = false;

  # ── Stop Docker veth churn from killing Chrome's connections ──
  # Every container start/stop creates+destroys a veth pair on docker0, and the kernel
  # auto-assigns an fe80:: link-local to each one — so each container emits an
  # RTM_NEWADDR *and* RTM_DELADDR on rtnetlink. Chrome's NetworkChangeNotifierLinux
  # watches rtnetlink and treats an address change on ANY interface as "the network
  # changed" (it passes an EMPTY ignored-interfaces set on desktop Linux and does no
  # link-local/veth filtering), so it tears down live HTTP/2 sessions with
  # ERR_NETWORK_CHANGED (-21). A testcontainers suite doing a container-per-test
  # (~100/min) makes Chrome unusable — measured ~3 address events/sec, and Chrome's own
  # NetLog logged a transient CONNECTION_NONE while Ethernet never dropped carrier.
  # addr_gen_mode=1 ("none") stops the kernel generating those link-locals on NEW
  # devices, which removes the address events. Upstream: crbug 974711 and
  # docker/for-linux#914 (both open; the only workaround known there is disabling IPv6
  # wholesale — this is the surgical version).
  #
  # Safe because NetworkManager sets addr_gen_mode PER-DEVICE from its connection
  # profile, overriding this default: a managed uplink still gets an NM-generated
  # stable-privacy fe80:: regardless of this sysctl. (On desktop that uplink is now
  # deliberately link-local ONLY — see the ensureProfiles block in hosts/desktop/default.nix
  # for why RA-assigned addresses were costing a connection reset every ~30 min. That is a
  # separate decision from this sysctl, which would be safe either way.) So this only
  # reaches devices NM doesn't
  # manage — docker0, the veths, vmnet* — i.e. exactly the churn sources. NM-managed
  # WireGuard is unaffected for the same reason, and raw `wg-quick` tunnels don't use a
  # kernel link-local (point-to-point, no ND; addresses come from the .conf).
  # ⚠ Two knock-ons: new netns inherit this, so containers get no auto link-local (fine
  # — docker0 is IPv4-only here, EnableIPv6=false), and this does NOT suppress the
  # RTM_NEWLINK/DELLINK link churn, so the CONNECTION_NONE blip may persist. Revisit if
  # you ever want IPv6 inside containers or run a bridged/TAP VPN doing IPv6 ND.
  boot.kernel.sysctl."net.ipv6.conf.default.addr_gen_mode" = 1;

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

  # ── mtr without sudo ──
  # Same raw-socket problem as nethogs, but nixpkgs already ships the module: this
  # installs mtr AND wraps its mtr-packet helper with cap_net_raw, so plain
  # `mtr <host>` works rootless. That's why mtr is NOT in home/common.nix's list.
  programs.mtr.enable = true;

  # ── FHS-style /bin and /usr/bin via envfs ──
  # Maps /bin/* and /usr/bin/* to whatever is on PATH, so Debian-style shebangs in
  # chezmoi scripts (#!/bin/bash, #!/usr/bin/perl) work without rewriting them.
  services.envfs.enable = true;

  # ── OpenSSH server — installed and started on boot on every host ──
  # Defaults: root login key-only (prohibit-password); openFirewall opens TCP 22.
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
