# Unit tests for lib/secrets.nix. Pure eval — no build, no age key, no real secrets.
#
# Wired into flake.nix's `checks` so `nix flake check --no-build` runs them. The assertions have
# to fire at EVAL time (the check `throw`s), because --no-build only evaluates checks — a
# runCommand-based test would be silently skipped by exactly the command we run to verify.
{ lib }:
let
  mk = import ./secrets.nix { inherit lib; };

  # A miniature secrets.yaml: two groups, then the `sops:` metadata block sops appends.
  real = mk ''
    smb:
        main_smb_creds: ENC[AES256_GCM,data:xx,type:str]
    git:
        github_token: ENC[AES256_GCM,data:yy,type:str]
    sops:
        age:
            - recipient: age1cmyzv35
  '';

  placeholder = mk "git:\n    github_token: replace me with a real token\n";
in
[
  { name = "finds a group-qualified key"; expected = true; actual = real.has "smb/main_smb_creds"; }

  # THE REASON THIS LIB EXISTS. modules/smb-mounts.nix used to test `hasInfix "smb_creds"` against
  # the whole file, which matched the real key `main_smb_creds` purely by accident of substring
  # matching. An anchored matcher must NOT match it. If it did, `declareSecret` would flip false and
  # a rebuild would silently drop fileSystems."/mnt/main_smb" and the sops secret — while cifs-utils
  # (declared unconditionally in that module's mkMerge) keeps manifests/ clean and CI green.
  { name = "REGRESSION GUARD: bare substring must NOT match"; expected = false; actual = real.has "smb/smb_creds"; }

  { name = "right key, wrong group does not match"; expected = false; actual = real.has "git/main_smb_creds"; }
  { name = "ignores the trailing sops: metadata block"; expected = false; actual = real.has "sops/age"; }
  { name = "enumerates every group/key"; expected = [ "smb/main_smb_creds" "git/github_token" ]; actual = real.paths; }
  { name = "placeholder file is not ready"; expected = false; actual = placeholder.ready; }
  { name = "placeholder gates every key off"; expected = false; actual = placeholder.has "git/github_token"; }
]
