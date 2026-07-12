# Does a given secret exist in secrets/secrets.yaml — WITHOUT decrypting anything?
#
# sops encrypts VALUES but leaves YAML KEYS in plaintext, so a raw read answers this at eval time
# with no age identity present. That is what keeps a fresh checkout CI-green, and it is why every
# secret-consuming module gates on key PRESENCE rather than on a decrypted value.
#
# Takes the raw TEXT rather than a path, so it is unit-testable against fixtures — ./secrets-test.nix.
#
# Keys are GROUP-QUALIFIED ("smb/main_smb_creds"), the same vocabulary `scripts/secrets-sync.py
# paths` emits. This is not cosmetic. Five modules used to substring-search the whole file for a
# bare key, and modules/smb-mounts.nix asked for "smb_creds" while the real key is "main_smb_creds"
# — it matched only by accident of `hasInfix`. An anchored bare-key test would have returned false
# and silently dropped the CIFS mount, with manifests/ and CI both staying green. Group-qualifying
# makes a wrong key a loud failure instead of a silent one.
{ lib }:
raw:
let
  ready = !(lib.hasInfix "replace me with" raw);

  # Walk the two-level `group:` / `    key: ENC[...]` structure, stopping at the `sops:` block sops
  # appends (age recipients, mac, lastmodified) — metadata, not secrets.
  # NB: there is no lib.takeWhile; findFirstIndex + take is the idiom.
  allLines = lib.splitString "\n" raw;
  body = lib.take
    (lib.lists.findFirstIndex (l: l == "sops:") (lib.length allLines) allLines)
    allLines;

  step = acc: line:
    let
      group = builtins.match "([a-z0-9_]+):" line; #             "git:"
      key = builtins.match "[[:space:]]+([a-z0-9_]+):.*" line; # "    github_token: ENC[...]"
    in
    if group != null then acc // { group = lib.head group; }
    else if key != null && acc.group != null
    then acc // { paths = acc.paths ++ [ "${acc.group}/${lib.head key}" ]; }
    else acc;

  walked = lib.foldl' step { group = null; paths = [ ]; } body;
in
{
  inherit ready;
  paths = walked.paths; # e.g. [ "nextcloud/rclone_conf" "smb/main_smb_creds" ... ]

  # Folds in `ready`, so call sites collapse to one condition instead of the old
  # `secretsReady && secretPresent` pair.
  has = path: ready && lib.elem path walked.paths;
}
