# Secrets scanning + a pre-commit leak gate

**Date:** 2026-07-14
**Status:** approved (design), pending implementation

## Goal

Install secrets-scanning tooling, and wire a leak gate into this repo so a secret — or a
private hostname — cannot reach the public `github.com/perfectra1n/nixos-configs`.

## Decisions taken

| Decision | Choice | Why |
|---|---|---|
| Scope | Tools **and** a repo leak gate | Tools alone don't stop a leak; the repo is public. |
| Decryption | **None.** Gate reads only tracked content | Gate stays offline + key-free; it can never itself spill plaintext, and it runs on a fresh checkout. |
| Hook manager | **lefthook**, mirroring `home-operations/kopiur` | Native hook manager; kopiur's shape (`.lefthook.toml`, `parallel`, `skip`, glob-scoped commands over `{staged_files}`) is the model. |
| Domain leaks | Custom gitleaks rules, public-host allowlist | Pattern scanners are structurally blind to a cleartext private hostname — the actual risk here. |

## The load-bearing finding: gitleaks' default stopwords eat `truenas.*`

gitleaks' default config applies a **global stopword list** to every rule by
case-insensitive *substring* match. `true` is a stopword. Therefore, with
`[extend] useDefault = true`, a finding of `truenas.<domain>` is **silently dropped**.

This repo's NAS is a TrueNAS box, which makes `truenas.<private-domain>` the single most
likely private hostname to leak — and the default config would swallow exactly that.

Verified empirically:

- `truenas.example.internal` with `useDefault = true` → **0 findings**
- same host, same rule, without `useDefault` → **fires**
- declaring our own `[allowlist]` **merges** with the default's stopwords rather than
  replacing them, so there is no way to keep `useDefault` and also trust the domain rules

**Consequence:** the scan runs as **two gitleaks passes**.

1. **Default rules** — no `-c` flag, so gitleaks uses its embedded defaults. Stopwords stay
   on, which is correct here: they cut real noise from `generic-api-key`.
2. **Domain rules** — `-c .gitleaks-domains.toml`, which does *not* extend the default, so
   no stopword can suppress a hostname.

A repo-root `.gitleaks.toml` is deliberately **not** created: gitleaks auto-loads that
filename, which would make pass 1 use it *instead of* the embedded defaults.

## Components

### 1. Packages

**`home/common.nix`** (home-manager; every host, including headless `server`) — gate + daily driver:

- `lefthook` — hook manager
- `gitleaks` — gate engine (fast, deterministic, offline)
- `trufflehog` — deeper scans with credential *verification*, on demand
- `git-filter-repo` — remediation, if something does land in history

**`modules/pentest.nix`** (system module; `desktop` + `laptop` only) — audit tooling pointed at
*other* people's code, matching the module's existing "Security tooling" charter:

- `noseyparker` — fast scanning of large git histories
- `ripsecrets` — low-false-positive fast scanner
- `trivy` — secrets + vulns + misconfig across fs/repo/images
- `gitxray` — GitHub-side recon (leaks in repo metadata, forks, actions)
- `zizmor` — GitHub Actions security linter (injection, over-broad permissions)

Excluded by YAGNI: `ggshield` (needs a GitGuardian account), `bfg-repo-cleaner` (redundant with
`git-filter-repo`), `semgrep`/`checkov`/`kics` (SAST/IaC, not secrets).

### 2. `.gitleaks-domains.toml` (new, repo root)

Two rules, no `[extend]`:

- **`private-infra-url-host`** — any `https?://` host not on a hand-curated public allowlist.
  Requiring `://` is what keeps it quiet: a bare-FQDN regex also matches ordinary identifiers
  (`subprocess.run`, `Path.home`, `libssl.so`, `home-manager.nixosModules.home`).
  `flake.lock` is path-allowlisted — it is *generated* from `flake.nix` (Renovate-tracked, all
  public upstreams), and the human-authored `flake.nix` is still scanned.
- **`private-tld-hostname`** — bare hostname on a private-use TLD (`internal`, `intranet`,
  `corp`, `priv`, `private`, `lan`, `localdomain`), for the no-scheme case. `home`, `local` and
  `arpa` are deliberately excluded — they collide with real identifiers.

The allowlist is **hand-curated on purpose**. Generating it from what is already in the tree
would rubber-stamp anything already committed, including a domain that had leaked. Adding a new
upstream source costs one line, and the prompt ("is this host public?") is the feature.

### 3. `.lefthook.toml` (new, repo root)

```toml
[pre-commit]
parallel = true
skip = ["merge", "rebase"]

[pre-commit.commands.gitleaks]                 # staged content, default rules
[pre-commit.commands.gitleaks-domains]         # staged content, domain rules
[pre-push.commands.gitleaks-history]           # full history, default rules
[pre-push.commands.gitleaks-domains-history]   # full history, domain rules
[pre-push.commands.trufflehog]                 # whole repo, backstop
```

Pre-commit kills a secret before it enters history; pre-push is the backstop before anything
becomes public.

### 4. Hook installation

mise's native `[hooks] enter = "lefthook install"`, plus a `mise run hooks` task as the explicit
escape hatch. `enter` fires when mise activates for this directory — which happens on every `cd`
here, since mise is shell-hooked via chezmoi — so a fresh clone arms its git hooks the moment you
step into it, with no command to remember. Measured at 0.00s once the hooks exist, so paying it
on every `cd` is free. Silent and fail-soft: on a box that hasn't rebuilt yet lefthook isn't on
PATH, and a hook that errored on every `cd` would be intolerable.

`postinstall = "lefthook install"` is also set, mirroring kopiur. It is a live trigger now that
`[tools]` exists (below): `mise install` on a fresh clone fetches lefthook and arms the hooks.
`enter` remains the stronger of the two — it needs no command at all — and `lefthook install` is
idempotent and free, so the overlap costs nothing.

### 5. mise `[tools]` — and why BOTH package managers is correct here

`mise.toml` also pins the three gate tools (`lefthook`, `gitleaks`, `trufflehog`) that
`home/common.nix` installs from Nix. This is deliberate duplication, and each copy does a job the
other cannot:

- **The Nix copy makes the gate work *everywhere*.** Git hooks run in a bare `sh` with no mise
  activation, so mise's install dir is not on PATH there. Verified: with only mise's tools, the
  pre-commit hook dies with `gitleaks: command not found` (exit 127 — it fails *closed*, but for
  the wrong reason). With the Nix copy on PATH and mise inactive, the hook correctly detects the
  leak and blocks. Without Nix, the gate would be broken in any non-activated context: an IDE, a
  GUI git client, a script, or the headless `server`.
- **The mise copy makes the gate work *immediately*,** with no rebuild, and gives kopiur parity
  (`mise install` → `postinstall` → hooks armed).

**The hazard is drift, and it is enforced away.** mise's install dir *shadows* `~/.nix-profile/bin`
on PATH (measured: positions 2–4 vs 9), so the mise pin is what an activated shell actually
executes — while `manifests/` advertises the nixpkgs version. Renovate will actively push them
apart: its built-in mise manager bumps `mise.toml` on its own schedule, while nixpkgs moves via
`flake-inputs.txt`. So `checks.x86_64-linux.mise-nixpkgs-versions` in `flake.nix` parses the
`[tools]` table with `builtins.fromTOML`, compares each pin to `pkgs.<name>.version`, and
`throw`s at eval time on any mismatch — failing `nix flake check`, and therefore CI, until the two
agree. Verified: aligned → passes; a simulated Renovate bump (`gitleaks` 8.30.1 → 8.31.0) → fails
with the offending tool and both versions named.

## Verification

Already run against the real repo with the pinned nixpkgs `gitleaks` 8.30.1:

| Check | Result |
|---|---|
| Pass 1 (default rules), 89 commits | **0 findings** |
| Pass 2 (domain rules), 89 commits | **0 findings** |
| Canary: AWS key, GitHub PAT, private Gitea URL, `truenas.*.internal` | **all 4 caught** |
| Canary: allowlisted `github.com` URL, `subprocess.run`, `vault.example.com` | **all 3 silent** |
| Runtime | gitleaks ~426 ms / 89 commits; trufflehog ~146 ms |

No `.gitleaks.toml` allowlist of the repo's own ciphertext is needed: the default ruleset is
already clean against the sops `secrets.yaml`, the `.age` blob, and `flake.lock`'s hashes.

Post-implementation: `git add -A && nix flake check --no-build` (flakes only see tracked files),
then a deliberate canary commit to confirm the hook actually blocks.

## Out of scope

- Decrypting sops/age values to grep for known plaintexts (explicitly declined).
- A CI job enforcing the same scan (can be added later; the gate is local-only for now).
- Formatters in lefthook — this repo has no configured formatter; not this change's problem.
