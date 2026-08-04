# CLAUDE.md

Guidance for working in this repo. Read this before editing.

## What this is

A multi-host NixOS + Home Manager flake. **Plain `mkHost` factory — no framework**
(snowfall-lib/flake-parts were deliberately rejected for maintainability). Modeled on
the sibling `../duck-nixos-configs`, borrowing sops-nix + facter from `../m00n-nixos-configs`.

Hosts: `desktop` (NVIDIA), `laptop` (AMD), `server` (headless).

## Hard rules

- **Flakes only see git-tracked files.** `git add` any NEW file before `nixos-rebuild`
  or `nix flake check`, or it's invisible. This is the #1 gotcha.
- **The chezmoi boundary is sacred — ownership decision tree** for any config/thing:
  - **Colors / themes / palettes → DMS** (DankMaterialShell matugen): e.g. `hypr/dms/colors.conf`,
    `gtk-3.0/dank-colors.css`. Don't hardcode theme colors in chezmoi or the flake.
  - **Host-specific / hardware config → the flake**, written as per-host `xdg.configFile`
    *fragments* that the chezmoi-managed `hyprland.conf` `source`s: `hypr/gpu.conf` (GPU,
    `modules/{nvidia,amd}.nix`), `hypr/monitors.conf` + `hypr/input.conf` (monitor scale +
    touchpad, `hosts/<name>/default.nix`), `hypr/autostart.conf` (`exec-once` daemons,
    `modules/desktop-apps.nix`).
  - **All other `~/.config/*` user config → chezmoi** (hypr, fish, kitty, tmux, gtk `settings.ini`).
    NEVER have the flake (home-manager `gtk`/`qt`, `programs.fish`, `programs.neovim`, generic
    `xdg.configFile`) write a `~/.config` file chezmoi manages. The chezmoi SOURCE lives in THIS
    repo under `dotfiles/` (chezmoi finds it via the repo-root `.chezmoiroot`); `chezmoi edit`/`add`
    land there, and `modules/dotfiles.nix` pins chezmoi's `sourceDir` to this checkout.
  - **Everything else → the flake** (system packages, services, setuid, kernel, users, secrets).
  - ⚠️ A chezmoi↔home-manager collision on a `~/.config` file makes `home-manager-<user>.service`
    fail with "would be clobbered" and **silently stops ALL HM file updates** until resolved — e.g.
    a chezmoi-owned `gtk-3.0/settings.ini` vs `home/gui.nix`'s `gtk` block blocked `monitors.conf`
    (and every other HM file) from ever updating.
- **Nix and chezmoi are PEERS sharing one repo, not nested.** Neither tool applies or templates the
  other's tree: chezmoi never sees `flake.nix`/`modules/` (the `.chezmoiroot` redirect scopes it to
  `dotfiles/`), and the flake never renders `dotfiles/`. Secrets stay split — system secrets in
  sops-nix (encrypted at rest, decrypted to `/run/secrets` at activation), user dotfile secrets
  age-encrypted *inside* `dotfiles/` (the `.age` file). This keeps the repo **publishable**: only
  ciphertext + the recipient pubkey are tracked — never plaintext or the age private key (that lives
  in Bitwarden + `~/.config/age`). One coupling cost: the flake checkout path is load-bearing —
  `modules/dotfiles.nix` bakes it into `sourceDir`, so the repo must live where that points.
- **`username` is a single `let` binding in `flake.nix`.** Never hardcode the login name
  elsewhere — modules/home receive it via `specialArgs`/`extraSpecialArgs`. Use
  `users.users.${username}` / `home.username = username`.
- **Keep the build CI-green on a fresh checkout.** Eval never needs a decrypted secret or
  a real machine: not-yet-installed hosts ship a placeholder `hardware-configuration.nix`
  (currently `server`), and secret-consuming modules gate on key *presence* in
  `secrets.yaml` (sops keeps YAML keys plaintext). Don't add anything that hard-requires
  a real secret/report at eval.

## Layout & conventions

```
flake.nix            # inputs + mkHost factory + nixosConfigurations
modules/*.nix        # NixOS system modules — ONE concern each, flat dir, no god-modules
home/{common,gui}.nix# home-manager: common = CLI/dev (every host), gui = graphical only
hosts/<name>/        # per-machine: default.nix (identity/boot/services) +
                     #   hardware-configuration.nix (+ optional facter.json)
secrets/secrets.yaml # sops-encrypted (real values as ciphertext — publishable by design)
.sops.yaml           # sops keys + creation rules (CLI-only; not read by Nix)
_sources/            # nvfetcher output (kubectl/talosctl/ksops/libratbag pins) — generated, don't hand-edit
manifests/           # generated per-host name-version inventories (nix run .#gen-manifests, auto via mise verify; CI-gated) — don't hand-edit
docs/                # design decisions, package inventory, host×module matrix
.chezmoiroot         # one line ("dotfiles") — redirects chezmoi into the dotfiles/ subtree
dotfiles/            # chezmoi SOURCE (shell rc + ~/.config/* app config + one .age secret).
                     #   NOT scanned by the flake; flat dotfile-name convention (dot_config/ …)
```

- **Flake inputs beyond the basics** (`nixpkgs`/`home-manager`/`sops-nix`):
  `hyprswitch` (Alt+Tab switcher, used in `modules/hyprland.nix`), `dms` +
  `dms-plugin-registry` (DankMaterialShell, `modules/hyprland.nix`), and `chaotic`
  (CachyOS kernel — `inputs.chaotic.nixosModules.default` on the `desktop` host only; it
  must NOT follow nixpkgs, see the flake.nix comment). See `docs/architecture.md`.
- **Graphical-host modules** `modules/desktop-apps.nix` (GUI apps + autostart),
  `modules/pentest.nix` (security tooling, desktop+laptop), and `modules/chromium-cm-fix.nix`
  (an overlay imported by `modules/hyprland.nix`, the one module that *is* imported by
  another — overlays can't be composed via `extraModules`).

- **Modules are composed, not cross-imported.** A host opts into features by listing
  modules in `flake.nix`'s `mkHost` call (`extraModules` / `homeModules`), not by one
  module importing another. The one allowed exception is hardware-config imports inside
  a host's `default.nix`.
- **Module signature:** `{ config, pkgs, lib, ... }:`. Add `username` to the args only if
  you use it; add `inputs` / `hostName` if needed (both come via `specialArgs`).
- **Comments explain WHY**, in the duck house style — a short note on the non-obvious
  reason for a setting, not what the option does. Match the density of existing modules.
- **`hardware.facter`** is nixpkgs' built-in module (the standalone nixos-facter-modules
  flake was upstreamed/deprecated). `modules/facter.nix` activates it only when
  `hosts/<host>/facter.json` exists and exposes `config.detected.{isLaptop,nvidia,amd,wireless}`.

## Common tasks

- **Add a host:** `NAME=<name> mise run new-host`. That's the whole thing — `flake.nix`
  derives `nixosConfigurations` from `hosts/` (`readDir`) and the CI matrix comes from
  `ls hosts`, so neither needs editing. It scaffolds `hosts/<name>/{default.nix,spec.nix,
  hardware-configuration.nix}`; adjust `spec.nix` if it isn't a plain server.
- **Add a system feature:** new single-concern `modules/<feature>.nix`, opt hosts in by
  listing it in their `hosts/<name>/spec.nix` `extraModules` (or in `graphical` in
  `flake.nix`, if BOTH graphical hosts should get it).
- **Add a package:** CLI/ops → `home/common.nix`; GUI → `home/gui.nix`; system service or
  setuid wrapper → the relevant `modules/*.nix`. Unfree is already allowed.
- **Pin an out-of-tree binary:** add to `nvfetcher.toml`, run `nvfetcher`, reference via
  the `mkBin` helper in `modules/common.nix`.

## Verify before claiming done

Run these before committing (or just `mise run verify`, which also refreshes `manifests/`):

```sh
git add -A                       # flakes only see tracked files
nix flake check                  # evaluates EVERY host's toplevel + runs the lib/ unit tests
```

`nix flake check` forces `config.system.build.toplevel.drvPath` for every `nixosConfigurations`
entry, so it already covers all hosts — there is no need to loop and `nix build --dry-run` each
one. It realizes the `checks` + `packages` outputs, which are kept trivial for that reason.

**Never add `--no-build`.** It sets Nix's read-only mode, which computes `.drv` paths without
writing them, making **Import From Derivation impossible** — and both graphical closures need IFD
(trilium's pnpm2nix reads `pnpm-lock.yaml` that way). The failure is
`error: path '<hash>-toJSON.drv' is not valid`, which looks like store corruption but isn't, and
it hides until a GC evicts the cached `.drv`.

Apply on a real host: `sudo nixos-rebuild switch --flake .#<HOST>` (hostname auto-selects,
so `#<HOST>` is optional on the box itself).
