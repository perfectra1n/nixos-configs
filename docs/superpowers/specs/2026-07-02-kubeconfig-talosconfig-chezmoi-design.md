# Encrypted kubeconfig + talosconfig via chezmoi

**Date:** 2026-07-02 · **Status:** approved

## Problem

The cluster-admin kubeconfig lives only at `~/repos/homelab-ops/kubeconfig` (gitignored
there — backed up nowhere), and the Talos admin config at `~/.talos/config` is likewise
unmanaged and world-readable. Both should be encrypted at rest in this repo and deployed
by `chezmoi apply`, like the existing fish secret.

## Design

Mechanism: chezmoi's **native age encryption** (`chezmoi add --encrypt`), the same
pattern as `dot_config/fish/fishconfig.d/encrypted_private_secrets.fish.age`. Not literal
sops — chezmoi only supports age/gpg — but it uses the identical age key as sops-nix
(`~/.config/age/age.agekey`), so the security model is the same: ciphertext in git,
decrypt at apply.

1. **Talosconfig** → `dotfiles/dot_talos/encrypted_private_config.age`, deployed to
   `~/.talos/config` (0600). No ignore changes needed.
2. **Kubeconfig** → `dotfiles/private_dot_kube/encrypted_private_config.age`, deployed
   to `~/.kube/config` (0600, dir 0700) — kubectl's default path, zero env-var wiring.
   The blanket `.kube` entry in `.chezmoiignore` becomes a DMS-style carve-out
   (`.kube/**` + `!.kube` + `!.kube/config`) so the cache stays ignored.
3. **homelab-ops symlink** — native chezmoi symlink,
   `dotfiles/repos/homelab-ops/symlink_kubeconfig.tmpl` → `~/.kube/config` (declarative:
   shows in `chezmoi managed`/`diff`, drift corrected on apply; a run_ script was
   considered and rejected as imperative). Guarded by a templated `.chezmoiignore` block
   (`stat` on `repos/homelab-ops/.git`) because a pre-clone symlink leaves a non-empty
   dir that breaks `git clone`; the ignore re-evaluates every apply, so the link appears
   once the repo exists.
4. **Host scope:** all hosts (no hostname guard).
5. **Snapshot policy:** live-writable snapshots (DMS convention) — kubectl/talosctl keep
   mutating the deployed files; re-capture intentional changes (context edits, the
   ~1-year Talos client-cert refresh from `talosctl kubeconfig`) with plain
   `chezmoi re-add`, which preserves the `encrypted_` attribute and re-encrypts
   (verified on v2.70.5; `add --encrypt` is only needed on first add). Never
   `readonly_`.

## Error handling / verification

Missing age key ⇒ `chezmoi apply` fails loudly at decrypt (existing behavior). Verify:
`chezmoi cat` round-trips both files, `chezmoi apply` is a no-op afterwards, the
homelab-ops symlink exists, and `kubectl get nodes` works from the default path.
