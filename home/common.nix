{ config, osConfig, pkgs, lib, username, ... }:

# Base home-manager config — imported for EVERY host (including the headless server).
# CLI/dev only. GUI apps live in home/gui.nix (graphical hosts add it).
# Dotfiles under ~/.config are owned by chezmoi, NOT here — no xdg.configFile.
let
  # Repos every host should have checked out under ~/repos (destination =
  # <basename of path>). Clone-if-missing ONLY — activation never touches an
  # existing working copy (see home.activation.ensureRepos below).
  # nixos-configs itself is deliberately absent: the flake can't be rebuilt
  # unless it's already on disk, so an entry here could only ever no-op.
  # Bare owner/repo paths, NOT URLs: the Gitea hostname is a secret (this repo is
  # public), so the activation script reads it at RUNTIME from the sops-decrypted
  # /run/secrets/git/main_gitea_host (owner=user, see modules/git-credentials.nix)
  # and skips cloning until that secret exists on the machine.
  clonedRepos = [
    "perf3ct/custom-claude-skills"
  ];
  repoDest = path: lib.removeSuffix ".git" (baseNameOf path);
  giteaHostFile = "/run/secrets/git/main_gitea_host";
in
{
  home.username = username;
  home.homeDirectory = "/home/${username}";
  home.stateVersion = "25.05";

  programs.home-manager.enable = true;

  home.packages = with pkgs; [
    # ── Shell ──
    fish
    starship             # prompt
    fzf
    fishPlugins.fzf-fish # patrickf1/fzf.fish
    fishPlugins.z        # jethrokuan/z
    tmux

    nethogs
    flux
    #nsys
    py-spy
    perf
    #pidstat

    # ── CLI tools ──
    bat
    fd
    ripgrep
    jq
    nnn
    # yazi lives in programs.yazi below — the one HM `programs.*` we allow, because it
    # only writes ~/.config/yazi/plugins (code, not chezmoi's config files)
    mc                   # Midnight Commander — dual-pane TUI for bulk copy/move
    chafa                # image→colored-text mosaics — yazi's preview fallback for tmux
                         # sessions mirrored to mixed terminals (kitty + VS Code share no
                         # graphics protocol; the y.fish wrapper in chezmoi picks this)
    git
    delta                # git diff pager
    lazygit              # git TUI
    lazydocker           # docker TUI
    chezmoi              # dotfile manager (owns ~/.config)

    # ── Secrets scanning (the leak gate — see .lefthook.toml) ──
    # This repo is PUBLIC, so a leaked key or private hostname is a real incident. lefthook
    # runs gitleaks on every commit + gitleaks/trufflehog on every push; these live here (not
    # pentest.nix) so the gate works on EVERY host, server included. Broader audit scanners
    # you point at OTHER people's code are in modules/pentest.nix instead.
    lefthook             # git-hook manager; `mise run hooks` installs the hooks
    gitleaks             # the gate engine — fast, deterministic, offline
    trufflehog           # deeper scans that can VERIFY a credential is live (run by hand)
    git-filter-repo      # remediation: excise a secret from history if one ever lands
    # btop flavored to the host's GPU so its GPU panel works. The vendor truth is
    # whichever of modules/{nvidia,amd}.nix the host imported (videoDrivers), read
    # via osConfig — NOT detected.* (no facter.json is committed yet, so those are
    # all false). Server matches neither driver → plain btop.
    (if lib.elem "nvidia" osConfig.services.xserver.videoDrivers then btop-cuda
     else if lib.elem "amdgpu" osConfig.services.xserver.videoDrivers then btop-rocm
     else btop)
    ncdu
    lsof                 # list open files/sockets (who holds this port/file?)
    nvd                  # closure diff by package/version — modules/system-diff.nix prints it at switch; handy vs ./result too
    # flock + pgrep are absent on purpose: util-linux and procps are NixOS
    # requiredPackages (every system profile), so listing them would just shadow
    # the same tools — same reasoning as the archive section below.
    yq-go                # YAML processor (mikefarah/yq)
    hugo                 # static site generator
    pandoc               # universal document converter (md↔docx/html/etc.); PDF output needs texlive separately

    # ── Editor: neovim + LazyVim deps ──
    neovim
    gcc                  # treesitter compilation
    nodejs               # LSP servers + the `node`/`npm` runtime for JS/TS dev
    pnpm                 # fast npm-alternative package manager (own store; npm stays available too)
    lua-language-server
    stylua
    tree-sitter

    # ── Dev / ops ──
    gnumake              # `make` — many projects' build entrypoint (not bundled with gcc on Nix)
    cmake                # C/C++ build-system generator (also pulled in by some -sys crates)
    pkg-config           # lets `-sys` crates (openssl-sys, …) locate native libs via .pc files
    openssl              # OpenSSL libs/headers for Rust openssl-sys (PKG_CONFIG_PATH set in modules/common.nix)
    (python3.withPackages (ps: with ps; [ pip requests evtx ]))  # evtx = pyevtx-rs bindings for inline .evtx scripting
    # kubectl / talosctl are pinned via nvfetcher and installed system-wide
    # (modules/common.nix) so both the shell and root see the same version.
    k9s                  # k8s TUI
    kubernetes-helm
    kustomize
    krew                 # kubectl plugin manager
    cilium-cli           # install/manage the Cilium eBPF CNI + Hubble on k8s clusters
    talhelper            # Talos config templating
    sops                 # secrets management
    postgresql           # `psql` client (the package bundles the client; we don't run a server here)
    bitwarden-cli        # `bw` — Bitwarden vault CLI
    ansible
    terraform            # BSL-licensed upstream (unfree); coexists with opentofu — different binaries
    opentofu             # FOSS Terraform fork (`tofu`)
    tea                  # Gitea CLI
    gh                   # GitHub CLI
    awscli2
    saml2aws             # fetch temporary AWS STS creds via a SAML IdP (Okta/ADFS/etc.) for `aws`
    snowflake-cli        # Snowflake data-warehouse CLI; the binary is `snow`, not `snowflake-cli`
    claude-code          # nixpkgs lags releases; swap for the flake if you want latest
    beads                # `bd` — graph-based issue tracker / memory for AI coding agents
    dolt                 # version-controlled SQL database, git-style CLI
    mise                 # version manager; activated via chezmoi (fish/conf.d/mise.fish)
    kopia                # backup/snapshot tool — the CLI bundles the web UI (`kopia server
                         # start --ui`, served on localhost:51515); the standalone KopiaUI
                         # desktop app is NOT in nixpkgs (request #300702), so this is the UI.
    wireguard-tools      # `wg` + `wg-quick` VPN CLI; kernel module is in-tree, so just
                         # `sudo wg-quick up <conf>`. For an always-on tunnel managed by the
                         # system, use NixOS `networking.wireguard.interfaces` in a module instead.

    # ── Media ──
    ffmpeg
    imagemagick
    yt-dlp

    # ── Archives / (un)compression ──
    # tar/gzip/xz/zstd/bzip2 are absent on purpose: NixOS puts them in every system
    # profile (requiredPackages), so listing them here would just shadow the same tools.
    p7zip                # `7z` + `7za` (standalone) + `7zr` (LZMA-only) — POSIX port of 7-Zip
    _7zz                 # `7zz` — official upstream 7-Zip CLI (newer codecs than the p7zip fork)
    libarchive           # `bsdtar` + bsdcpio/bsdcat/bsdunzip — one binary reads zip/7z/iso/cab too
    unzip
    zip
    unrar                # official RAR extractor (unfree) — RARv5 support the free tools lack
    unar                 # The Unarchiver: `unar`/`lsar`, strong on legacy formats + non-UTF8 filenames
    cabextract           # Windows .cab
    ouch                 # `ouch decompress <anything>` — format auto-detect, nice for muscle memory
    lz4
    lzip
    lzop
    brotli               # `brotli`/`unbrotli` — mostly web assets (.br)

    # ── PDF / OCR ──
    poppler-utils        # `pdftotext` (the "pdf2text"), pdftoppm, pdfimages, pdfinfo, pdfunite, pdfseparate
    tesseract            # OCR engine (binary `tesseract`); ships eng + osd traineddata by default
    ocrmypdf             # adds a searchable text layer to scanned PDFs (drives tesseract + ghostscript + qpdf)
    qpdf                 # structural PDF transforms/repair (decrypt, linearize, split/merge)
    ghostscript          # `gs` — PDF/PostScript rendering & conversion (also the imagemagick PDF backend)
    img2pdf              # lossless image→PDF (no re-encode, unlike imagemagick's `convert`)
  ];

  # Yazi + its plugins. Plugins are CODE, not config, so nix owns them: store symlinks
  # under ~/.config/yazi/plugins, version-matched to this nixpkgs' yazi (`ya pkg` was
  # rejected — it fetches upstream main at apply time, which can drift ahead of the
  # installed yazi and needs the network). The chezmoi side keeps the sibling config
  # files that wire these up (yazi.toml / keymap.toml / init.lua) — zero file overlap
  # with what HM writes, so no clobber risk (see CLAUDE.md on that failure mode).
  programs.yazi = {
    enable = true;
    # The `y` cwd-follow wrapper is chezmoi's fish function; HM's generated one must
    # never land in chezmoi-owned fish config (moot while programs.fish is off, but
    # explicit beats relying on that).
    enableFishIntegration = false;
    enableBashIntegration = false;
    plugins = lib.genAttrs [
      "git"          # status signs in the listing (init.lua + fetchers in yazi.toml)
      "smart-enter"  # `l` opens files AND enters dirs (keymap.toml)
      "full-border"  # rounded full borders (init.lua)
      "chmod"        # `cm` perms editor (keymap.toml)
      "mount"        # `M` mount/unmount/eject (keymap.toml)
      "ouch"         # archive preview + `C` compress (yazi.toml + keymap.toml)
      "lazygit"      # `gi` lazygit popup (keymap.toml)
      "starship"     # starship prompt as yazi's status bar (init.lua)
    ] (name: pkgs.yaziPlugins.${name});
  };

  # Ensure clonedRepos (see top) exist under ~/repos on every switch. Fail-soft:
  # GIT_TERMINAL_PROMPT=0 makes a private/unauthenticated repo fail fast instead of
  # hanging activation, and a dead remote just warns — the clone retries next rebuild.
  # Private-repo auth rides the ~/.gitconfig credential helper (chezmoi) reading the
  # sops-rendered /run/secrets/rendered/git-credentials, so on a FRESH machine the
  # first rebuild warns (no chezmoi/secrets yet) and the clone lands on a later switch.
  # The Gitea HOST is likewise read at runtime (never baked into the store): until
  # `mise run secrets:pull` lands git/main_gitea_host, the whole step no-ops quietly.
  home.activation.ensureRepos = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    export GIT_TERMINAL_PROMPT=0
    if giteaHost=$(cat ${giteaHostFile} 2>/dev/null) && [ -n "$giteaHost" ]; then
      run mkdir -p "$HOME/repos"
      ${lib.concatMapStringsSep "\n" (path: ''
        if [ ! -e "$HOME/repos/${repoDest path}" ]; then
          run ${pkgs.git}/bin/git clone -- "https://$giteaHost/${path}" "$HOME/repos/${repoDest path}" \
            || echo "ensureRepos: could not clone ${path} (offline? auth?) — will retry next switch"
        fi
      '') clonedRepos}
    else
      echo "ensureRepos: ${giteaHostFile} not readable yet — skipping clones until secrets land"
    fi
  '';

  # NOTE: deliberately NO programs.fish / programs.mise here. Those modules GENERATE
  # ~/.config/fish/*, which collides with chezmoi (the sole owner of ~/.config/fish).
  # fish-as-login-shell is enabled system-side in modules/common.nix.
}
