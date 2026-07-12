# Architecture & design decisions

Why this repo is shaped the way it is. The root [`CLAUDE.md`](../CLAUDE.md) states the
rules; this explains the reasoning behind them.

## Plain `mkHost` factory — no framework

This is a hand-rolled flake: a small `mkHost` function in `flake.nix` and a flat directory
of single-concern modules. snowfall-lib and flake-parts were **deliberately rejected** —
for a handful of personal hosts they add a layer of indirection and magic that costs more
in "where does this come from?" than it saves in boilerplate. The whole control flow fits
on one screen of `flake.nix`, which is the point.

```nix
mkHost = hostName: { extraModules ? [ ], homeModules ? [ ] }:
  nixpkgs.lib.nixosSystem {
    specialArgs = { inherit inputs hostName username; };
    modules = [ common facter ./hosts/${hostName} sops home-manager { … } ] ++ extraModules;
  };
```

Every host gets `common` + `facter` + its `hosts/<name>` dir + sops + home-manager + the
base `home/common.nix`, then **opts into** features via `extraModules` (system) and
`homeModules` (home-manager, graphical hosts add `home/gui.nix`).

## Composition, not cross-import

Modules never `import` each other. A host gains a feature by listing the module in its
`hosts/<name>/spec.nix`, so the full feature set of a host is readable in one place. This avoids
hidden dependency graphs where enabling one module silently drags in others.

`spec.nix` is a plain function — `{ inputs, graphical } -> { extraModules, homeModules }` — that
`mkHost` consumes. It is **not** a NixOS module, which is why this is still composition rather than
cross-import, and why it is named `spec.nix` and not `modules.nix`: it sits next to `default.nix`,
which *is* a module, and a file called `modules.nix` that isn't one would be a trap.

Modules shared by BOTH graphical hosts live in the `graphical` list in `flake.nix`, so they are
declared once instead of being copy-pasted into two host lists (which had already drifted apart).

`flake.nix` discovers `hosts/*` with `readDir`, so there is no host list to keep in sync — not in
the flake, not in the CI matrix. One consequence to know: `readDir` sees only **git-tracked**
content, so an unstaged `hosts/<x>/` silently does not exist rather than erroring. `mise run verify`
runs `git add -A` first, which covers the normal path — but it is the same "flakes only see tracked
files" gotcha wearing a quieter disguise.

Allowed exceptions, all intentional:
- A host's `default.nix` imports its own `hardware-configuration.nix`.
- `modules/hyprland.nix` imports `modules/chromium-cm-fix.nix` and the DMS modules — these
  register a **nixpkgs overlay** and **NixOS module options**, which can't be supplied
  through `extraModules` the way a plain config module can, so they're pulled in by the one
  module that needs them.

## The chezmoi boundary

This is the load-bearing rule of the repo. **This flake owns** system packages, services,
state, and `/etc`. **chezmoi owns `~/.config/*`** — fish, neovim, hypr, waybar, pyprland,
etc. The two never write the same path.

**One repo, two peer tools.** The chezmoi source lives in this repo under `dotfiles/`; the
repo-root `.chezmoiroot` (one line, `dotfiles`) redirects chezmoi there, so it never scans the
Nix tree and the flake never renders `dotfiles/`. `modules/dotfiles.nix` pins chezmoi's
`sourceDir` to this checkout — the one load-bearing path the merge introduced (the repo must live
where `sourceDir` points). Merging buys atomic cross-boundary commits (change a fragment and the
`hyprland.conf` that sources it in one commit) and a single clone/bootstrap; it does NOT collapse
the tooling — chezmoi keeps live-editing + age encryption, sops-nix keeps system secrets. The old
standalone `chezmoi-dotfiles` repo is archived for history, and the `chezmoi/gitea_token` sops
secret that used to gate cloning it is retired (its now-orphaned ciphertext in `secrets.yaml` can
be pruned anytime via `mise run secrets:edit`).

Consequences baked into the code:
- No `programs.fish` / `programs.neovim` / generic `xdg.configFile` in home-manager —
  those generate files under `~/.config` and would fight chezmoi. fish-as-login-shell is
  set system-side (`modules/common.nix`); `mise` is installed as a bare package and
  activated by a chezmoi-managed `fish/conf.d` snippet.
- **Two allowed flake-written fragments**, both `source`d by the chezmoi `hyprland.conf`:
  - `hypr/gpu.conf` — GPU env vars, written by `modules/{nvidia,amd}.nix` (hardware-specific,
    so the flake is the right owner).
  - `hypr/autostart.conf` — the `exec-once` daemon list, written by `modules/desktop-apps.nix`.
    The flake owns it because it autostarts daemons the *flake* installs (`dms`, `pypr`,
    `hyprshell`, `solaar`, `linux-wallpaperengine`, …); keeping the list next to the packages stops the
    two drifting apart. **Requires** the chezmoi `hyprland.conf` to `source` it.

## Secrets — sops-nix

**Single-key model:** one age identity decrypts every secret on every host. `sops-nix`
reads it from `sops.age.keyFile` (`/var/lib/sops-nix/key.txt`) at activation; the private
key lives in Bitwarden and a fresh box pulls it down via `mise run secrets:key-bootstrap`
(also invoked automatically by `mise run apply`). This deliberately trades per-host isolation for
zero-enrollment bootstrap — see the comment at the top of `.sops.yaml`. (`sshKeyPaths` stays
configured as a fallback.) Wiring lives in `modules/common.nix` but is **inert until you
declare a `sops.secrets.*` entry**, so a fresh checkout still evaluates (CI stays green). The
shipped `secrets/secrets.yaml` holds real sops-encrypted values (keys visible, values
ciphertext — safe in the public repo), and `validateSopsFiles = true` checks its sops
structure at every eval without needing the key. `.sops.yaml` is CLI-only (for the `sops`
tool), not read by Nix.

## Hardware detection — facter

`modules/facter.nix` uses nixpkgs' **built-in** `hardware.facter` module (the standalone
nixos-facter-modules flake was upstreamed and deprecated). It activates only when a
`hosts/<host>/facter.json` exists and exposes `config.detected.{isLaptop,nvidia,amd,wireless}`
for other modules to branch on — a stable replacement for the fragile
`nixos-generate-config` hardware scan.

## Out-of-tree pins — nvfetcher

Tools not in nixpkgs (or deliberately version-pinned) are declared in `nvfetcher.toml` with
`# renovate:` comments; `nvfetcher` resolves each to a prefetched source + SHA in
`_sources/generated.nix` (the lockfile for these), and Renovate bumps the versions and
refills hashes. Static Go binaries (`kubectl`, `talosctl`) are installed as-is via the
`mkBin` helper in `modules/common.nix`. **After editing `nvfetcher.toml` you must run `nvfetcher` and
`git add _sources/generated.nix`** or the new pin is invisible / breaks eval.

## CI-green on a fresh checkout

Eval must never hard-require a decrypted secret or a real machine: not-yet-installed
hosts ship a placeholder `hardware-configuration.nix` (currently `server`), and
secret-consuming modules gate on key *presence* in `secrets.yaml` (sops keeps YAML keys
plaintext), so `nix build --dry-run` works on a fresh checkout. The rule: don't add
anything that hard-requires a real secret or hardware report at **eval** time. (Build
time is fine — e.g. the CachyOS kernel and DMS's quickshell only build on a real switch.)

## Flake inputs and why each exists

| Input | Why it's here | Used by |
|-------|---------------|---------|
| `nixpkgs` (nixos-unstable) | Package set. | everything |
| `home-manager` | Per-user config; follows nixpkgs. | `flake.nix` |
| `sops-nix` | Activation-time secret decryption. | `modules/common.nix` |
| `hyprswitch` | GUI Alt+Tab switcher (`hyprshell`); not in nixpkgs. | `modules/hyprland.nix` |
| `dms` + `dms-plugin-registry` | DankMaterialShell (Quickshell Wayland shell) + declarative plugins. | `modules/hyprland.nix` |
| `chaotic` | CachyOS kernel + its binary cache. **Does not follow nixpkgs** — following it would force a local kernel compile and miss the chaotic cache. | `desktop` host only |

> `scx` (the sched_ext gaming scheduler in `modules/gaming.nix`) is a **stock nixpkgs**
> option and needs only a kernel with sched_ext (≥6.12) — it does *not* require chaotic.
> Chaotic is added solely for the CachyOS kernel on the NVIDIA desktop; the laptop runs scx
> on the stock kernel.

## Why `modules/chromium-cm-fix.nix` exists

Chromium ≥141 declares its SDR UI as sRGB over `wp_color_manager_v1`, so Hyprland renders
it at ~80-nit reference brightness on an HDR output and skips the `sdrbrightness` boost —
Chrome/VSCode/Brave/Trilium/Slack look dim. Until the proper upstream fix (hyprwm/Hyprland
#14999) lands, this overlay appends `--disable-features=WaylandWpColorManagerV1` to those
apps (binary + `.desktop` Exec). It's harmless on non-HDR/AMD outputs — it just turns off
one Chromium feature — so it's applied on both Hyprland hosts. Delete the file once #14999
ships.
