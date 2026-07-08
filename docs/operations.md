# Operations — the mise task suite

[`mise.toml`](../mise.toml) is the operator interface to this repo: every workflow — rebuild,
verify, hardware capture, secrets — is a `mise run <task>` away. mise itself is installed by the
flake and shell-hooked via chezmoi, so the tasks autoload on `cd` into the checkout. `mise tasks`
lists them; this doc explains the *design* — what each task guards against and when to reach for
which.

## The mental model

Three layers, least- to most-frequently used:

| Layer | Tasks | Cadence |
|-------|-------|---------|
| **Bootstrap** | `secrets:key-bootstrap`, `secrets:init`, `hardware`, `dots-cutover`, `new-host` | once per machine / host |
| **Change loop** | `verify`, `diff`, `test`, `apply`, `dots-diff`, `update` | daily |
| **Maintenance** | `secrets:pull`, `bump`, `gc`, `rollback`, `generations`, `deploy`, `manifests`, `whatchanged` | occasional |

## `apply` — the self-healing entry point

`mise run apply` = rebuild this host, then `chezmoi apply`. The interesting part is the
**preflight chain** — four checks that turn "day-to-day rebuild" and "blank machine bootstrap"
into the *same command*:

1. **No sops age key yet?** (`/var/lib/sops-nix/key.txt` missing) → runs `secrets:key-bootstrap`
   first. sops-nix decrypts at *activation*, so the key must exist **before** the rebuild or every
   `sops.secrets.*` activation fails.
2. **Placeholder hardware config?** If this machine's real root UUID isn't in
   `hosts/<host>/hardware-configuration.nix` → runs `hardware` first. Switching onto the shipped
   placeholder (fake disk UUIDs) yields an **unbootable system**.
3. **Placeholder `secrets.yaml`?** → runs `secrets:init` to populate every Bitwarden-backed secret
   before the switch, so the rebuild can declare + decrypt them.
4. **New manifest keys not yet in `secrets.yaml`?** A cheap local check (sops keeps *keys*
   plaintext, only values are encrypted) — catches the case where you added a manifest row (e.g.
   `docker/*`) on an already-initialized box, where the gated module would otherwise stay
   *silently inert*. Only unlocks the vault when something is genuinely missing.

The host is auto-detected by `scripts/host.sh` (root-UUID match → hostname, prompts if unsure —
a fresh box's hostname is still the installer's `nixos`); override with `HOST=desktop`.

⚠️ The trailing `chezmoi apply` **overwrites uncommitted edits under `dotfiles/`** — commit WIP
first (see [chezmoi.md](chezmoi.md#daily-edit-loop)).

## The change loop

```sh
mise run verify      # git add -A + flake check + dry-build every host + refresh manifests/ — run BEFORE committing
mise run diff        # closure diff: what would a rebuild actually change vs the running system
mise run test        # activate WITHOUT touching the bootloader — auto-reverts on reboot
mise run apply       # the real switch (+ dotfiles)
mise run dots-diff   # chezmoi diff — preview dotfile changes only
mise run update      # chezmoi update: pull the whole monorepo + apply DOTFILES only (no rebuild)
```

- `verify` starts with `git add -A` because **flakes only see tracked files** — the repo's #1
  gotcha, encoded into the task so it can't be forgotten. It ends by regenerating
  `manifests/<host>.txt` (the committed package-version inventories) — CI fails if they drift
  from the evaluated closure, see [package-versioning.md](package-versioning.md).
- `test` vs `apply`: `nixos-rebuild test` is the safe trial — the change is live now but the
  bootloader still points at the old generation, so a reboot rolls back for free.
- `update` is the cheap cross-machine sync: pulled Nix changes just sit until the next `apply`.

## Secrets — values vs identity

The tasks split cleanly into two families (the comment headers in `mise.toml` mark the seam):

### The encrypted VALUES

Both Bitwarden→destination mappings live **once**, in the two manifests at the top of
`scripts/secrets-sync.py` (`SOPS_MANIFEST` + `FISHENV_MANIFEST`). Adding a Bitwarden-backed secret
= one manifest line; every task below reads the same manifests.

| Task | What it does |
|------|-------------|
| `secrets:init` | One-time: point `.sops.yaml` at the held key, populate `secrets.yaml` from Bitwarden, encrypt, commit |
| `secrets:pull` | Refresh **both** channels (sops `secrets.yaml` + the age-encrypted fish env) in one vault unlock, re-encrypt + commit. Run after rotating a token |
| `secrets:pull-env` | Same, fish-env channel only |
| `secrets:edit` | `sops secrets/secrets.yaml` with the right key path — for hand-set (non-manifest) secrets |
| `secrets:list` | Which keys exist, marking `[manifest: <bw item>]` vs `[hand-set]`. Read-only, no decryption |
| `secrets:status` | Health check: both key copies present? `secrets.yaml` real? held key matches the `.sops.yaml` recipient? |
| `secrets:get` | Decrypt + print one value: `KEY=git/github_token mise run secrets:get` |
| `secrets:updatekeys` | Re-encrypt `secrets.yaml` for the current `.sops.yaml` recipients (after enrolling a host key) |

### The age IDENTITY

One key decrypts everything ([chezmoi.md](chezmoi.md#secrets-one-key-two-encryption-systems));
these tasks move it around:

| Task | What it does |
|------|-------------|
| `secrets:key-bootstrap` | Fresh install: pull the key from Bitwarden (custom field `secret key` on item `AGE SOPS Key`) → **both** `/var/lib/sops-nix/key.txt` and `~/.config/age/age.agekey`. Refuses to clobber an existing key (`FORCE=1` to override) — clobbering is how you lose access to old secrets. Handles a custom Vaultwarden endpoint (`BW_SERVER=`), including the logout-before-reconfigure dance `bw` requires |
| `secrets:key-install` | Same destination, but from a path you supply (`KEY=/path`) |
| `secrets:key-enroll` | Print this host's ssh-derived age recipient (`ssh-to-age`) — add to `.sops.yaml` on a trusted box, then `secrets:updatekeys` |

## Machine and host lifecycle

| Task | What it does |
|------|-------------|
| `hardware` | Capture THIS machine's real `hardware-configuration.nix` into `hosts/<host>/`, then **commit + push** — commit, not just stage, because `nixos-rebuild` resolves a `git+file://` flake that only sees *committed* files. Sets git identity inline so it works on a fresh box |
| `new-host` | Scaffold `hosts/<name>/` (server-flavoured `default.nix` + CI-safe placeholder hardware config) and append the host to the CI matrix. One manual step remains: the `mkHost` entry in `flake.nix` (printed for you) |
| `hosts` | List host configs + which one this machine resolves to |
| `deploy` | Build locally, activate remotely: `HOST=server TARGET=user@host mise run deploy` |
| `dots-cutover` | One-time post-monorepo-merge: verify chezmoi resolves to `./dotfiles` here, then retire the orphaned standalone `~/.local/share/chezmoi` clone |
| `dirs` | Create the screenshot dirs the Hyprland binds write into |

## Maintenance

| Task | What it does |
|------|-------------|
| `bump` | `nix flake update` + full `verify` — never relock without dry-building every host |
| `gc` | Delete generations >14 days old + `nix store optimise` (also prunes `whatchanged`'s local history — git manifests are the durable record) |
| `rollback` | Switch back to the previous system generation |
| `generations` | List generations + dates (rollback targets) |
| `manifests` | Regenerate `manifests/<host>.txt` (all hosts, or `HOST=desktop`) without a full verify |
| `whatchanged` | Package history across kept generations; `PKG=<name>` finds STORE-PATH changes — catches same-version rebuilds version diffs miss (see [package-versioning.md](package-versioning.md)) |
| `suspects` | `BIN=<app> [FROM= TO=]` — which of a broken app's deps changed between generations (closure ∩ generation diff, with why-depends chains); step 2 of the [breakage runbook](package-versioning.md#runbook-a-bump-broke-something) |

## Conventions

- **Fresh-box-proof**: any task that commits sets `git -c user.name/-c user.email` inline
  (no "Please tell me who you are" on a box with no git config), and pushes with a soft-fail
  `|| echo` so missing remote creds never abort the local work.
- **Idempotent + guarded**: bootstrap tasks no-op when already done (`key-bootstrap` skips if a
  key exists, `secrets:init` exits if `secrets.yaml` is real) — safe to re-run, and safe for
  `apply`'s preflights to call unconditionally.
- **`task_output = "quiet"`**: mise's per-line command echo is suppressed (it printed every
  comment in long scripts); the tasks' own `>> …` progress lines still show. Debug one run with
  `mise run -o prefix <task>`.
