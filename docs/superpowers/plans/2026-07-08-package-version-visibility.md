# Package-Version Visibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
> After approval, first copy this plan to `docs/superpowers/plans/2026-07-08-package-version-visibility.md` (repo convention).

**Goal:** Make every package-level change to any host's closure visible — at switch time, in every Renovate PR diff, and retroactively across generations — so a regression like the xdg-desktop-portal-hyprland one is diagnosable in one command instead of a deep dive.

**Architecture:** Two granularities. (1) *Version-level, in git*: generated `manifests/<host>.txt` name-version inventories, refreshed by `mise run verify` + Renovate postUpgradeTasks, freshness-gated in CI — every bump PR's diff shows exactly which apps changed. (2) *Store-path-level, local*: an `nvd` diff printed on every activation, `system.configurationRevision` stamping each generation with its git commit, and a `whatchanged` tool that walks retained generations to find where a package's store path changed **even at the same version** (the xdph case: 1.3.12 → 1.3.12, path `ps4965…` → `w61i839…` at gen 88 — invisible to version diffs). Tooling ships as in-repo flake apps (`writeShellApplication` → shellcheck-gated, pinned deps, `nix run github:perfectra1n/nixos-configs#whatchanged` works anywhere). The wsl host is retired in the same change (user-approved).

**Tech Stack:** Nix flakes, writeShellApplication, nvd, Renovate postUpgradeTasks, GitHub Actions, mise.

## Global Constraints

- Flakes only see git-tracked files — `git add` every new file before any `nix` command touches the flake.
- Repo is public: manifests expose the package inventory (incl. pentest tooling) — **user accepted** (closure already derivable from flake.lock).
- Manifests must contain **no timestamps** and be byte-reproducible: CI regenerates and `git diff --exit-code`s them; Renovate re-runs must be idempotent.
- Scripts are `writeShellApplication` *bodies*: no shebang, no `set -euo pipefail` (both injected), and must pass shellcheck (no `for x in $(ls …)`, quote everything, guard `grep`-in-pipeline failures under pipefail).
- Module signature convention: `{ config, pkgs, lib, ... }` + `inputs` only if used; comments explain WHY, duck house style.
- mise is the operator interface; do NOT add fish aliases (chezmoi territory).
- Eval must never require a real secret/machine (CI-green on fresh checkout).
- Generations 87/88 (the xdph evidence) are subject to `mise run gc`'s 14-day retention — run the Task 4 live verification promptly.

---

### Task 1: Layer 1 — at-switch nvd diff + generation↔commit stamp

**Files:**
- Create: `modules/system-diff.nix`
- Modify: `flake.nix:87-90` (mkHost base modules list)
- Modify: `home/common.nix` (CLI tools section, near the other nix/ops tools)

**Interfaces:**
- Produces: every subsequent `nixos-rebuild switch|test|dry-activate` prints an nvd package diff; `system.configurationRevision` becomes readable per generation via `<gen-link>/sw/bin/nixos-version --configuration-revision` (consumed by Task 4's `whatchanged`).

- [ ] **Step 1: Write `modules/system-diff.nix`**

```nix
{ config, pkgs, lib, inputs, ... }:

# Rebuild visibility: a package-level diff (old running system → incoming config) printed at
# every activation, and each generation stamped with the git commit that built it. Applied to
# ALL hosts via mkHost. WHY: a flake.lock bump once rebuilt xdg-desktop-portal-hyprland at the
# SAME version (store path changed, version didn't) and regressed portal screenshots — diagnosis
# needs per-switch diffs plus a generation→commit mapping. See docs/package-versioning.md.
{
  # Readable later, per generation:
  #   /nix/var/nix/profiles/system-N-link/sw/bin/nixos-version --configuration-revision
  # (`nix run .#whatchanged` prints it per change). dirtyRev (nix ≥ 2.19) covers switches
  # from a dirty tree; the literal is the last-ditch fallback.
  system.configurationRevision = inputs.self.rev or inputs.self.dirtyRev or "dirty";

  # During activation /run/current-system still points at the OLD system and $systemConfig is
  # the incoming one — exactly the pair to diff. The guard skips the two activations with no
  # old system (boot, nixos-install). supportsDryActivation → `nixos-rebuild dry-activate`
  # previews the diff without switching. --nix-bin-dir because activation PATH is minimal and
  # nvd shells out to nix for closure queries; config.nix.package matches the daemon's nix.
  system.activationScripts.diff = {
    supportsDryActivation = true;
    text = ''
      if [ -e /run/current-system ]; then
        ${pkgs.nvd}/bin/nvd --nix-bin-dir=${config.nix.package}/bin diff /run/current-system "$systemConfig"
      fi
    '';
  };
}
```

- [ ] **Step 2: Wire it into every host in `flake.nix`**

In the mkHost factory's `modules` list, after `./modules/facter.nix` (line 89):

```nix
          modules = [
            ./modules/common.nix
            ./modules/facter.nix
            ./modules/system-diff.nix
            ./hosts/${hostName}
```

- [ ] **Step 3: Add `nvd` to `home/common.nix`**

One line in the CLI-tools `home.packages` list, matching the existing aligned-comment style:

```nix
    nvd                  # closure diff by package/version — modules/system-diff.nix prints it at switch; handy vs ./result too
```

- [ ] **Step 4: Track + verify eval**

Run: `git add modules/system-diff.nix flake.nix home/common.nix && nix flake check --no-build`
Expected: clean check (no eval errors).

Run: `nix build --dry-run ".#nixosConfigurations.desktop.config.system.build.toplevel"`
Expected: dry-run plan listing derivations to build (nvd + new toplevel), no errors.

- [ ] **Step 5: Commit**

```bash
git commit -m "feat(system-diff): nvd diff at every activation + configurationRevision stamp"
```

---

### Task 2: Retire the wsl host (user-approved: box no longer used)

**Files:**
- Delete: `hosts/wsl/` (entire directory)
- Modify: `flake.nix:2` (description), `flake.nix:12-15` (nixos-wsl input), `flake.nix:158-159` (wsl mkHost entry)
- Modify: `mise.toml:91` (verify's hardcoded host list — switch to `ls hosts` so future hosts are auto-covered)
- Modify: `.github/workflows/check.yaml:25` (matrix)
- Modify: `CLAUDE.md` (hosts list; the "Verify before claiming done" section: host loop AND the stale "`nix` is not installed in the WSL dev box" claim — this dev box is NixOS with nix)
- Modify: `docs/host-matrix.md`, `docs/packages.md` (remove W column/legend entries), `docs/architecture.md` if it lists wsl
- Regenerate: `flake-inputs.txt` (via `./scripts/gen-flake-input-pins.sh`) if it pins nixos-wsl; `flake.lock` (via `nix flake lock`)

**Interfaces:**
- Produces: `ls hosts` → exactly `desktop laptop server` — Task 3's manifest auto-discovery and mise verify both key off this.

- [ ] **Step 1: Remove the host and input**

```bash
git rm -r hosts/wsl
```

In `flake.nix`: description becomes `"NixOS + Home Manager — multi-host (desktop / laptop / server)"`; delete the `nixos-wsl` input block (lines 12-15) and the `wsl = mkHost "wsl" { };` entry + its comment (lines 158-159).

- [ ] **Step 2: `mise.toml` verify loop — derive hosts instead of hardcoding**

Replace line 91's `for h in desktop laptop server wsl; do` with:

```sh
for h in $(ls hosts); do
```

(Matches the generated-over-hardcoded preference; `new-host` scaffolds are covered automatically.)

- [ ] **Step 3: CI matrix**

`.github/workflows/check.yaml` line 25: `host: [desktop, laptop, server]` (the `new-host` task's sed `s/\(host: \[[^]]*\)\]/\1, $NAME]/` still matches — verified against the pattern).

- [ ] **Step 4: CLAUDE.md + docs**

- Hosts line: `Hosts: \`desktop\` (NVIDIA), \`laptop\` (AMD), \`server\` (headless).`
- Verify section: delete the sentence claiming nix is not installed on the WSL dev box (replace with "run these before committing:"), and the loop becomes `for h in desktop laptop server; do`.
- `docs/host-matrix.md` / `docs/packages.md`: drop the W host column/legend rows. `docs/architecture.md`: remove wsl/nixos-wsl mentions.

- [ ] **Step 5: Relock, regenerate pins, verify, commit**

```bash
grep -q nixos-wsl flake-inputs.txt && ./scripts/gen-flake-input-pins.sh || true
nix flake lock          # prunes the orphaned nixos-wsl entry from flake.lock
git add -A && nix flake check --no-build
for h in $(ls hosts); do nix build --dry-run ".#nixosConfigurations.$h.config.system.build.toplevel"; done
git commit -m "feat!: retire the wsl host (box no longer in use)"
```

Expected: check passes; exactly three dry-runs; `grep -ri wsl flake.nix mise.toml .github CLAUDE.md` returns nothing.

---

### Task 3: `gen-manifests` flake app + first committed manifests

**Files:**
- Create: `scripts/gen-manifests.sh` (writeShellApplication body — no shebang)
- Create: `manifests/desktop.txt`, `manifests/laptop.txt`, `manifests/server.txt` (generated)
- Modify: `flake.nix` (add `packages.x86_64-linux` to the outputs attrset, after `nixosConfigurations`)

**Interfaces:**
- Produces: `nix run .#gen-manifests [-- host ...]` — no/empty args = all dirs under `hosts/`; writes `manifests/<host>.txt`. Consumed by Task 5 (mise), Task 6 (Renovate), Task 7 (CI). Empty-string args are tolerated and skipped (mise passes `-- ${HOST:-}`).

- [ ] **Step 1: Write `scripts/gen-manifests.sh`**

```bash
# Body of the gen-manifests flake app (flake.nix packages.x86_64-linux.gen-manifests).
# writeShellApplication injects the shebang, `set -euo pipefail`, and a shellcheck gate —
# invoke via `nix run .#gen-manifests [-- host ...]`, not by executing this file.
#
# Regenerates manifests/<host>.txt: the committed name-version inventory of a host's closure.
# WHY: a flake.lock bump is a one-line hash change hiding hundreds of package updates (the
# real dependency set only exists after eval). Committing a sorted name-version list per host
# makes every Renovate PR / manual bump show exactly which packages changed — in the PR diff —
# and `git log -p manifests/` is a permanent, greppable per-package version history.
# Eval-only (`nix path-info --derivation` instantiates, never builds), so CI and Renovate run it.
#
# CAVEATS (docs/package-versioning.md):
#  - BUILD closure: a superset of what's installed (build-time deps included).
#  - Version-level only: a package rebuilt at the SAME version (the xdg-desktop-portal-hyprland
#    case) does NOT show here — `nix run .#whatchanged` and the switch-time nvd diff catch that.
#  - NO timestamps in output: CI regenerates and diffs this file; content must be reproducible.

if [ ! -f flake.nix ]; then
  echo "error: run from the repo root (flake.nix not found)" >&2
  exit 1
fi

hosts=()
for h in "$@"; do
  if [ -n "$h" ]; then hosts+=("$h"); fi     # skip empty args (mise passes -- ${HOST:-})
done
if [ "${#hosts[@]}" -eq 0 ]; then
  while IFS= read -r h; do hosts+=("$h"); done \
    < <(find hosts -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
fi

mkdir -p manifests
for host in "${hosts[@]}"; do
  echo ">> manifest: $host" >&2
  drv=$(nix path-info --derivation ".#nixosConfigurations.$host.config.system.build.toplevel")
  {
    echo "# GENERATED by \`nix run .#gen-manifests\` — do not edit by hand."
    echo "# Name-version inventory of this host's build closure; CI regenerates + diffs it."
    # Strip /nix/store/<hash>- and .drv; drop non-package noise: fetched archives, patches,
    # -source FODs, and loose single-file build scaffolding. Cosmetic only — the manifest is
    # a diff surface, not an authoritative inventory.
    nix-store --query --requisites "$drv" \
      | sed -E 's|^/nix/store/[a-z0-9]{32}-||; s|\.drv$||' \
      | grep -Ev '\.(tar(\.[a-z0-9]+)?|tgz|txz|zip|gz|xz|bz2|zst|patch|diff|crate|whl|gem)$' \
      | grep -Ev '(^|-)source$' \
      | grep -Ev '\.(sh|bash|nix|json|conf|toml|yaml|yml|py|pl|rb|lock|service|desktop|rules|xml|patch|c|h|cc|txt|pc|cfg|ini)$' \
      | sort -u
  } > "manifests/$host.txt"
done
echo ">> done: ${hosts[*]}" >&2
```

- [ ] **Step 2: Add the packages output to `flake.nix`**

Inside the outputs attrset, after the closing `};` of `nixosConfigurations` (line 160):

```nix
      # Ops tooling as flake apps: shellcheck-gated at build time, runtime deps pinned,
      # runnable from anywhere via `nix run github:perfectra1n/nixos-configs#<name>`.
      # Scripts are BODIES only — writeShellApplication injects the shebang + set -euo pipefail.
      packages.x86_64-linux =
        let pkgs = nixpkgs.legacyPackages.x86_64-linux; in
        {
          gen-manifests = pkgs.writeShellApplication {
            name = "gen-manifests";
            runtimeInputs = with pkgs; [ nix gnused gnugrep coreutils findutils ];
            text = builtins.readFile ./scripts/gen-manifests.sh;
          };
          whatchanged = pkgs.writeShellApplication {
            name = "whatchanged";
            runtimeInputs = with pkgs; [ nix gnused gnugrep coreutils ];
            text = builtins.readFile ./scripts/whatchanged.sh;
          };
        };
```

NOTE: this block references `./scripts/whatchanged.sh` which Task 4 creates. If executing tasks strictly in order, create an empty-bodied placeholder is NOT allowed (No Placeholders) — instead add only `gen-manifests` here and let Task 4 add the `whatchanged` attr. Keep the comment block with `gen-manifests`.

- [ ] **Step 3: Track, build (runs shellcheck), generate**

```bash
git add scripts/gen-manifests.sh flake.nix
nix build .#gen-manifests    # writeShellApplication runs shellcheck here — must succeed
nix run .#gen-manifests      # all three hosts; ~1-2 min of eval each
```

Expected: `manifests/{desktop,laptop,server}.txt` created; desktop ≈ several thousand lines.

- [ ] **Step 4: Verify content, idempotence, and the exact CI predicate**

```bash
grep xdg-desktop-portal-hyprland manifests/desktop.txt
git add manifests/
nix run .#gen-manifests -- desktop && git diff --exit-code -- manifests/desktop.txt
```

Expected: first command prints `xdg-desktop-portal-hyprland-1.3.12` (+ possible suffixed outputs); last command exits 0 (byte-identical regeneration).

- [ ] **Step 5: Commit**

```bash
git add manifests/ && git commit -m "feat(manifests): committed per-host name-version inventories via nix run .#gen-manifests"
```

---

### Task 4: `whatchanged` flake app + live verification against the xdph regression

**Files:**
- Create: `scripts/whatchanged.sh` (writeShellApplication body — no shebang)
- Modify: `flake.nix` (add the `whatchanged` attr to `packages.x86_64-linux` from Task 3's block)

**Interfaces:**
- Consumes: `system.configurationRevision` stamps from Task 1 (older generations report `unknown` — expected).
- Produces: `nix run .#whatchanged` (version diffs, all generation pairs) and `nix run .#whatchanged -- <pkg>` (store-path changes for one package across generations).

- [ ] **Step 1: Write `scripts/whatchanged.sh`**

```bash
# Body of the whatchanged flake app (flake.nix packages.x86_64-linux.whatchanged).
# writeShellApplication injects the shebang, `set -euo pipefail`, and shellcheck — invoke via
#   nix run .#whatchanged [-- <package-name>]
# and from any box: nix run github:perfectra1n/nixos-configs#whatchanged -- <pkg>
#
# Package history across THIS machine's kept system generations (runtime closures of built
# generations — unlike manifests/, which are eval-time build closures).
#   no arg → version-level diff for every consecutive generation pair
#   <pkg>  → generations where <pkg>'s STORE PATH set changed — catches same-version rebuilds:
#            xdg-desktop-portal-hyprland once regressed at an UNCHANGED 1.3.12 (store path
#            moved, rebuilt against a changed grim); version diffs were blind to it.
# Works unprivileged: profiles and the store are world-readable. Note: generations pruned by
# `mise run gc` (14d) are gone from history — git manifests are the durable record.

profile=/nix/var/nix/profiles/system
pkg="${1:-}"

if [ -z "$pkg" ]; then
  nix profile diff-closures --profile "$profile"
  exit 0
fi

shopt -s nullglob
# sort -V: numeric-aware, so system-100-link sorts after system-28-link (glob order doesn't)
mapfile -t links < <(printf '%s\n' "$profile"-*-link | sort -V)
if [ "${#links[@]}" -eq 0 ]; then
  echo "error: no system generations found under $profile" >&2
  exit 1
fi

indent() {
  if [ -z "$1" ]; then echo "    <absent>"; else sed 's/^/    /' <<<"$1"; fi
}

prevpaths="" prevgen="" seen=0 changes=0
for link in "${links[@]}"; do
  gen="${link#"$profile"-}"
  gen="${gen%-link}"
  # grep exits 1 when the package is absent from a generation — legitimate, not an error
  paths=$(nix-store --query --requisites "$link" 2>/dev/null | grep -E -- "-${pkg}(-[0-9][^/]*)?$" | sort) || paths=""
  if [ "$seen" -eq 1 ] && [ "$paths" != "$prevpaths" ]; then
    changes=$((changes + 1))
    date=$(stat -c %y "$link" | cut -d. -f1)   # symlink's OWN mtime = switch time (no -L)
    rev=$("$link/sw/bin/nixos-version" --configuration-revision 2>/dev/null) || rev="unknown"
    echo "gen $prevgen → $gen  (switched $date, config rev: ${rev:-unknown})"
    echo "  before:"; indent "$prevpaths"
    echo "  after:";  indent "$paths"
    echo
  fi
  prevpaths="$paths" prevgen="$gen" seen=1
done
if [ "$changes" -eq 0 ]; then
  echo "no store-path changes for '$pkg' across ${#links[@]} kept generations"
fi
```

- [ ] **Step 2: Add the `whatchanged` attr to the Task-3 `packages.x86_64-linux` block in `flake.nix`** (exact attrset shown in Task 3 Step 2).

- [ ] **Step 3: Track, build (shellcheck), run the acceptance test against the real regression**

```bash
git add scripts/whatchanged.sh flake.nix
nix build .#whatchanged
nix run .#whatchanged -- xdg-desktop-portal-hyprland
```

Expected output includes:

```
gen 87 → 88  (switched 2026-07-06 ..., config rev: unknown)
  before:
    /nix/store/ps4965fk0n4nsmx3ibgnmrk95wp1355i-xdg-desktop-portal-hyprland-1.3.12
  after:
    /nix/store/w61i839515cb30kwh1ib6dq6wlkv8z4j-xdg-desktop-portal-hyprland-1.3.12
```

(`config rev: unknown` is correct — gen 88 predates Task 1's stamp.)

Run: `nix run .#whatchanged` → per-generation-pair version diff tables (same data as `nix profile diff-closures`).

- [ ] **Step 4: Commit**

```bash
git commit -m "feat(whatchanged): store-path-level package forensics across system generations"
```

---

### Task 5: mise integration

**Files:**
- Modify: `mise.toml` — `tasks.verify` (lines 85-94), plus two new tasks placed next to `tasks.diff` (line 347)

**Interfaces:**
- Consumes: `nix run .#gen-manifests` / `.#whatchanged` (Tasks 3-4).
- Produces: `mise run verify` always leaves manifests fresh (this is the invariant Task 7's CI gate enforces); `mise run manifests` / `mise run whatchanged` as discoverable wrappers.

- [ ] **Step 1: Extend `tasks.verify`** — full replacement:

```toml
[tasks.verify]
description = "Eval the flake + dry-run-build every host + refresh manifests (run before committing)"
run = '''
set -eu
git add -A                               # flakes only see tracked files
nix flake check --no-build
for h in $(ls hosts); do
  nix build --dry-run ".#nixosConfigurations.$h.config.system.build.toplevel"
done
# Manifests ride the eval cache the dry-runs above just warmed, so this is cheap here.
# verify is the choke-point every change flows through (bump calls it too) — keeping the
# committed manifests in lockstep with the closure; CI fails if they drift (check.yaml).
nix run .#gen-manifests
git add manifests/
'''
```

- [ ] **Step 2: Add the wrapper tasks** (after `tasks.diff`, matching the env-var-arg convention):

```toml
[tasks.manifests]
description = "Regenerate manifests/<host>.txt name-version inventories (all hosts, or HOST=desktop)"
run = '''
set -eu
nix run .#gen-manifests -- ${HOST:-}
git add manifests/
'''

[tasks.whatchanged]
description = "Package history across kept generations. No arg: version diffs per generation pair. PKG=<name>: where <name>'s STORE PATH changed — catches same-version rebuilds (the xdph case)"
run = '''
set -eu
nix run .#whatchanged -- ${PKG:-}
'''
```

(`${HOST:-}` / `${PKG:-}` expand to an empty arg — both scripts explicitly tolerate/skip empty args.)

- [ ] **Step 3: Verify end-to-end**

Run: `mise run verify`
Expected: flake check + 3 dry-runs + `>> manifest: …` × 3; `git status` shows manifests staged, unchanged content (idempotent).

Run: `PKG=xdg-desktop-portal-hyprland mise run whatchanged`
Expected: same gen 87→88 output as Task 4.

- [ ] **Step 4: Commit**

```bash
git add mise.toml && git commit -m "feat(mise): manifests + whatchanged tasks; verify refreshes manifests"
```

---

### Task 6: Renovate integration (renovate.json + allowlist land atomically)

**Files:**
- Modify: `renovate.json:33-53` (both packageRules)
- Modify: `.github/workflows/renovate.yaml:60` (RENOVATE_ALLOWED_COMMANDS)

**Interfaces:**
- Consumes: `nix run .#gen-manifests` (Task 3); manifests already tracked (Task 3) so Renovate's fileFilters match existing files.
- Produces: every Renovate bump PR (flake inputs AND nvfetcher pins) carries the per-host manifest diff.

- [ ] **Step 1: `renovate.json` — both packageRules become:**

```json
  "packageRules": [
    {
      "matchManagers": ["custom.regex"],
      "matchFileNames": ["flake-inputs.txt"],
      "commitMessageTopic": "flake input {{depName}}",
      "postUpgradeTasks": {
        "commands": ["nix flake update {{{depName}}}", "nix run .#gen-manifests"],
        "fileFilters": ["flake.lock", "flake-inputs.txt", "manifests/**"],
        "executionMode": "update"
      }
    },
    {
      "matchManagers": ["custom.regex"],
      "matchFileNames": ["nvfetcher.toml"],
      "postUpgradeTasks": {
        "commands": ["nvfetcher", "nix run .#gen-manifests"],
        "fileFilters": ["nvfetcher.toml", "_sources/**", "manifests/**"],
        "executionMode": "branch"
      }
    }
  ]
```

(Commands run in array order — manifests regenerate AFTER the lock/_sources update, against the updated tree. Renovate only commits files matching fileFilters, hence `manifests/**` on both.)

- [ ] **Step 2: `renovate.yaml` line 60** (allowlist is regex-matched and mismatches are *silently skipped* — this must merge together with Step 1):

```yaml
          RENOVATE_ALLOWED_COMMANDS: '["^nvfetcher$", "^nix flake update [a-z0-9-]+$", "^nix run \\.#gen-manifests$"]'
```

Also extend the workflow's header comment (lines 4-13) with one line: postUpgradeTasks now also regenerate `manifests/` so bump PRs show the package-version diff.

- [ ] **Step 3: Verify config syntax + commit**

```bash
nix shell nixpkgs#renovate --command renovate-config-validator renovate.json
git add renovate.json .github/workflows/renovate.yaml
git commit -m "feat(renovate): regenerate package manifests in every bump PR"
```

Expected: validator reports zero errors.

- [ ] **Step 4 (post-merge, first real run): trigger Actions → Renovate → Run workflow (logLevel=debug)**

Expected: log shows the postUpgradeTask executing; any resulting bump PR's changed-files list includes `manifests/*.txt`. Runtime note: 3 host evals ≈ 3-6 min per PR branch — inside Renovate's 15-min default executionTimeout; if it ever times out, raise `RENOVATE_EXECUTION_TIMEOUT` or parallelize the host loop in gen-manifests.sh.

---

### Task 7: CI manifest-freshness gate

**Files:**
- Modify: `.github/workflows/check.yaml` (new step after Build-plan; header comment)

**Interfaces:**
- Consumes: committed manifests (Task 3) + `nix run .#gen-manifests -- <host>` single-host mode.
- Produces: any PR/push whose closure diverges from its committed manifests fails with an actionable error.

- [ ] **Step 1: Add the step after `Build-plan`:**

```yaml
      - name: Manifest freshness (${{ matrix.host }})
        # gen-manifests reuses the eval the dry-run above already did (same installable →
        # warm eval cache + instantiated drvs). A diff means the closure changed without
        # regenerating manifests/ — `mise run verify` does it automatically.
        run: |
          nix run .#gen-manifests -- ${{ matrix.host }}
          git diff --exit-code -- "manifests/${{ matrix.host }}.txt" || {
            echo "::error::manifests/${{ matrix.host }}.txt is stale — run 'mise run verify' on a Nix machine and commit the result"
            exit 1
          }
```

Extend the header comment (lines 4-7): "…and verifies the committed manifests/ inventories match the evaluated closure."

- [ ] **Step 2: Verify the exact predicate locally, then commit**

```bash
nix run .#gen-manifests -- desktop && git diff --exit-code -- manifests/desktop.txt   # exit 0
sed -i 's/^# GENERATED/# generated/' manifests/desktop.txt
git diff --exit-code -- manifests/desktop.txt; echo "exit: $?"                        # exit 1 (gate fires)
git checkout -- manifests/desktop.txt
git add .github/workflows/check.yaml
git commit -m "ci: fail when committed manifests drift from the evaluated closure"
```

- [ ] **Step 3 (post-push): confirm the matrix job passes on main for all 3 hosts.**

---

### Task 8: Docs + CLAUDE.md

**Files:**
- Create: `docs/package-versioning.md`
- Create: `docs/superpowers/plans/2026-07-08-package-version-visibility.md` (copy of this plan — repo convention)
- Modify: `docs/README.md` (index row), `docs/operations.md` (task tables), `CLAUDE.md` (layout block)

**Interfaces:** none — documentation of Tasks 1-7.

- [ ] **Step 1: Write `docs/package-versioning.md`** covering, in this order:
  1. The xdph case study with real data (gen 87→88, version 1.3.12 unchanged, store path `ps4965…` → `w61i839…`, root cause: rebuilt against a changed grim baked into its wrapper PATH) — and the punchline: *version-level diffing alone cannot catch this class*.
  2. The two granularities table: version-level (`manifests/` in git; refreshed by verify/Renovate; gated by CI; `git log -p manifests/desktop.txt` = per-package history) vs store-path-level (nvd at every switch; `nix run .#whatchanged -- <pkg>` over kept generations; `configurationRevision` maps generations → commits; pruned by gc after 14d — git is the durable record).
  3. Tooling: flake apps, `nix run github:perfectra1n/nixos-configs#whatchanged` from any box; scripts are writeShellApplication bodies (no shebang — shellcheck + pinned deps at build).
  4. Caveats: manifests are the BUILD closure (eval-only superset); noise filters are cosmetic; public-repo inventory exposure accepted (already derivable from flake.lock).
- [ ] **Step 2: `docs/README.md`**: add the package-versioning.md row. `docs/operations.md`: add `manifests` + `whatchanged` to the task tables; note verify now refreshes manifests and CI gates freshness.
- [ ] **Step 3: `CLAUDE.md` layout block**, next to `_sources/`:

```
manifests/           # generated per-host name-version inventories (nix run .#gen-manifests, auto via mise verify) — don't hand-edit
```

- [ ] **Step 4: Commit**

```bash
git add docs/ CLAUDE.md && git commit -m "docs: package-versioning — two-granularity visibility model"
```

---

### Task 9: Live verification on this desktop (Vesemir)

**Files:** none (verification only)

- [ ] **Step 1: Preview the switch-time diff without switching**

Run: `sudo nixos-rebuild dry-activate --flake .#desktop`
Expected: an nvd table (nvd + the new tooling appearing, versions column) printed during activation.

- [ ] **Step 2: Real switch + provenance check**

```bash
sudo nixos-rebuild switch --flake .#desktop
nixos-version --configuration-revision      # expect the commit hash (or <hash>-dirty)
```

- [ ] **Step 3: Past-generation readback + forensics still green**

```bash
gen=$(readlink /run/current-system | grep -oE '[0-9]+' | tail -1); true  # or: sudo nixos-rebuild list-generations
/nix/var/nix/profiles/system-$(sudo nixos-rebuild list-generations | awk '/current/ {print $1}')-link/sw/bin/nixos-version --configuration-revision
nix run .#whatchanged -- xdg-desktop-portal-hyprland   # gen 87→88 evidence still reported
```

- [ ] **Step 4: Push and watch CI**

```bash
git push
gh run watch   # all 3 matrix jobs green, incl. the new freshness step
```

---

## Gaps found and closed during planning (why the plan looks the way it does)

1. **xdph never changed version** — forced the two-granularity design; a manifests-only solution would re-fail the exact case that motivated this.
2. **`mise run manifests` without HOST passes an empty arg** (`-- ${HOST:-}`) — gen-manifests explicitly skips empty args.
3. **shellcheck gate** (writeShellApplication): no `for x in $(ls …)` (→ `find`/`mapfile` + `sort -V`), `grep` in pipelines fails under pipefail when a package is absent from a generation (→ `|| paths=""`), glob-no-match (→ `shopt -s nullglob` + explicit empty check).
4. **`stat -L` trap**: the dereferenced generation has epoch mtime; the symlink's own mtime is the switch time.
5. **`ls -v` vs glob order**: system-100 sorts before system-28 in glob order; `sort -V` fixes generation ordering.
6. **Renovate allowlist silently skips non-matching commands** — renovate.json + renovate.yaml must merge atomically; regex `^nix run \\.#gen-manifests$` escaped for JSON-in-single-quoted-YAML.
7. **Timestamps would permanently break the CI gate and Renovate idempotence** — manifests carry static headers only.
8. **Manifests must be regenerated AFTER Task 1 and Task 2** (nvd/module change every closure; wsl must be gone so auto-discovery skips it) — task ordering encodes this.
9. **CI gate + committed manifests must land in the same change**, or the first CI run after the gate is red.
10. **verify's hardcoded host list** would silently diverge from `hosts/` — switched to `ls hosts`; `new-host`'s check.yaml sed still matches the shrunk matrix.
11. **`nix run` requires tracked files** — every task `git add`s before the first nix invocation.
12. **Build-closure vs runtime-closure asymmetry** (manifests are eval-time build closures; whatchanged reads runtime closures of built generations) — documented in both script headers and docs.
13. **Generation retention**: gc prunes at 14d — the gen-87/88 acceptance test must run promptly (Task 4), and docs state git manifests are the durable record.
14. **`config.nix.package` (not `pkgs.nix`) for nvd's --nix-bin-dir** — matches the daemon's nix.
15. **Pre-stamp generations report `unknown` revision** — whatchanged falls back gracefully instead of erroring.

## Post-execution housekeeping (not code)

- Memory updates: WSL box retired + wsl host removed; packaging decision (in-repo flake apps over standalone binary — revisit only if wanted cross-repo); amend the `dev-box-has-nix` memory (the stale CLAUDE.md caveat is now deleted).
