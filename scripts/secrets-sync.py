#!/usr/bin/env python3
"""Single source of truth for Bitwarden -> the repo's TWO secret channels.

Each row of a MANIFEST below maps a destination key to a Bitwarden item + how to extract its
value. Adding a Bitwarden-backed secret is ONE manifest row; nothing else changes.

  - SOPS_MANIFEST     -> system secrets in secrets/secrets.yaml (sops-nix, decrypts to /run/secrets)
  - FISHENV_MANIFEST  -> shell env vars in the age-encrypted secrets.fish (chezmoi), consumed as
                         ${VAR} by ~/.config/claude/mcp.json etc.

Subcommands (driven by the mise tasks, not run by hand):
  set           surgical `sops set` per key into secrets.yaml          (sops channel only)
  emit          plaintext YAML on stdout for a fresh-box secrets:init  (sops channel only)
  paths         `path<TAB>bw_item` for every sops row — no vault, read-only
  inventory     BOTH manifests as `channel<TAB>key<TAB>bw_item<TAB>kind` — no vault, read-only
  fishenv       refresh the age-encrypted secrets.fish env vars        (fish channel only)
  fishenv-emit  DRY RUN: print the would-be new secrets.fish plaintext, no encrypt, no write
  sync-all      refresh BOTH channels in a SINGLE vault unlock         (used by secrets:pull)
  selftest      in-process unit checks for the fish merge — no vault, no files

Why Python (not the old bash): the fish channel does text surgery on a decrypted file with exact
quoting + idempotency requirements that are error-prone in awk/sed. Here merge_fishenv() is a pure,
unit-tested function, and os.replace() gives a real atomic swap. The sops half is a faithful port.
"""
from __future__ import annotations

import base64
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

# == MANIFESTS ==  (dest_key, bw_item, kind, selector)
#   kind=field      -> value is the named custom field `selector` on the item, taken VERBATIM
#   kind=host       -> value is the item's Website field (else first login URI), stripped to a bare
#                      host so it slots into https://user:TOKEN@HOST (selector ignored)
#   kind=basicauth  -> value is base64("<user>:<field value>") — docker's auths.<reg>.auth blob.
#                      selector is "<user>:<field name>", split on the FIRST colon. <user>="@"
#                      resolves the username FROM the item (login Username, else a "User Name" field).
#   kind=note       -> value is the item's secure-note body VERBATIM — for MULTILINE file contents
#                      (smb creds) that a single-line custom field can't carry.
#   kind=mcpbase    -> the named field `selector` (an MCP URL) with a trailing "/mcp" removed — for
#                      plugins that append /mcp themselves (e.g. memini's bundled .mcp.json). Lets one
#                      stored mcp_url feed both a full-URL client and a base-URL one, no second field.

# System secrets -> secrets/secrets.yaml. EVERY key is Bitwarden-backed — `mise run secrets:pull`
# refreshes all of them; `secrets:edit` is only for out-of-band experiments.
SOPS_MANIFEST = [
    ("chezmoi/gitea_token",    "Main Gitea",                  "field",     "Personal Access Token 1"),
    # nextcloud/rclone_conf was dropped 2026-07-19: the rclone config moved to chezmoi
    # (dot_config/rclone/create_encrypted_private_rclone.conf.age) because Google Drive's OAuth
    # refresh needs a WRITABLE config, which a read-only sops secret can never be. The Bitwarden
    # note itself is left alone as a backup; it just no longer feeds secrets.yaml.
    ("smb/main_smb_creds",     "Main SMB Credentials",        "note",      ""),
    ("git/github_token",       "Github",                      "field",     "Updated Super Token (API key)"),
    ("git/main_gitea_token",   "Main Gitea",                  "field",     "Personal Access Token 1"),
    ("git/main_gitea_host",    "Main Gitea",                  "host",      ""),
    ("git/duck_gitea_token",   "Duck Gitea",                  "field",     "API Key (Main)"),
    ("git/duck_gitea_host",    "Duck Gitea",                  "host",      ""),
    ("docker/main_gitea_auth", "Main Gitea",                  "basicauth", "perf3ct:Personal Access Token 1"),
    ("docker/duck_gitea_auth", "Duck Gitea",                  "basicauth", "perf3ct:API Key (Main)"),
    ("docker/ghcr_auth",       "Github",                      "basicauth", "perfectra1n:Updated Super Token (API key)"),
    ("docker/dockerhub_auth",  "Dockerhub / hub.docker.com",  "basicauth", "@:Access Token"),
    # LAN attic binary cache (modules/nix-cache.nix). The URL carries ?priority=10 on purpose:
    # Nix orders substituters by priority, not config order, and 10 beats cache.nixos.org's 40.
    ("nix/cache_substituter_url", "Nix Binary Cache",         "field",     "substituter_url"),
    ("nix/attic_endpoint",        "Nix Binary Cache",         "field",     "endpoint"),
    ("nix/attic_push_token",      "Nix Binary Cache",         "field",     "push_token"),
]

# Shell env vars -> the age-encrypted secrets.fish. Mostly `field` (full URLs/tokens taken
# verbatim; `host` would wrongly strip a URL to a bare host) — the one `host` row is
# MAIN_GITEA_HOST, where a bare host is exactly what the fish functions splice into URLs.
# The two Trilium servers share one gateway url+bearer — that's just equal values stored in each
# item's own fields, no special-casing. EVERY var is Bitwarden-backed (`mise run secrets:pull`);
# merge_fishenv() would still preserve any future hand-set line it doesn't recognize.
FISHENV_MANIFEST = [
    ("TRILIUM_PERSONAL_MCP_URL",     "Trilium Personal MCP", "field", "mcp_url"),
    ("TRILIUM_PERSONAL_MCP_BEARER",  "Trilium Personal MCP", "field", "mcp_bearer"),
    ("TRILIUM_PERSONAL_URL",         "Trilium Personal MCP", "field", "trilium_url"),
    ("TRILIUM_PERSONAL_ETAPI_TOKEN", "Trilium Personal MCP", "field", "etapi_token"),
    ("TRILIUM_ATVIK_MCP_URL",        "Trilium Atvik MCP",    "field", "mcp_url"),
    ("TRILIUM_ATVIK_MCP_BEARER",     "Trilium Atvik MCP",    "field", "mcp_bearer"),
    ("TRILIUM_ATVIK_URL",            "Trilium Atvik MCP",    "field", "trilium_url"),
    ("TRILIUM_ATVIK_ETAPI_TOKEN",    "Trilium Atvik MCP",    "field", "etapi_token"),
    ("KUBESEARCH_MCP_URL",           "Kubesearch MCP",       "field", "mcp_url"),
    ("KUBESEARCH_MCP_BEARER",        "Kubesearch MCP",       "field", "mcp_bearer"),
    ("PROTONDB_MCP_URL",             "ProtonDB MCP",         "field", "mcp_url"),
    ("PROTONDB_MCP_BEARER",          "ProtonDB MCP",         "field", "mcp_bearer"),
    # konflate's MCP is unauthenticated by design — it's reachable only via envoy-internal
    # (the public route 404s /mcp), so there is no bearer row. The URL is vault-backed
    # anyway because it carries the internal hostname, which stays out of this public repo.
    ("KONFLATE_MCP_URL",             "Konflate MCP",         "field", "mcp_url"),
    # memini is PLUGIN-ONLY (no manual server in mcp.json): the memini@memini plugin bundles its own
    # MCP server + hooks + skills, all reading config from the SHELL ENV. It wants the base URL WITHOUT
    # /mcp (it re-appends /mcp itself) + MEMINI_API_KEY. Both derive from the one "Memini MCP" item —
    # the key is the mcp_bearer field verbatim, the base is mcp_url with the trailing /mcp stripped
    # (mcpbase kind). MEMINI_NAMESPACE (=default) lives in the PUBLIC fish conf.d, not here: not a secret.
    ("MEMINI_BASE_URL",              "Memini MCP",           "mcpbase", "mcp_url"),
    ("MEMINI_API_KEY",               "Memini MCP",           "field",   "jon_dev"),
    # Private domains — kept out of the (public) repo; fish functions reference these vars.
    ("MAIN_GITEA_HOST",              "Main Gitea",           "host",  ""),
    ("HOMELAB_SSH_DOMAIN",           "Homelab Domains",      "field", "ssh_domain"),
    ("RESTIC_S3_ENDPOINT",           "Homelab Domains",      "field", "restic_s3_endpoint"),
    # API keys — one Bitwarden item each (created 2026-07 when these moved off hand-set).
    ("ANTHROPIC_API_KEY_2",          "Anthropic API Key 2",      "field", "api_key"),
    ("AWS_BEARER_TOKEN_BEDROCK",     "AWS Bedrock Bearer Token", "field", "token"),
    ("CF_TURNSTILE_SECRET_KEY",      "Cloudflare Turnstile",     "field", "secret_key"),
    ("CIRCLE_TOKEN",                 "CircleCI",                 "field", "token"),
    # CLIProxyAPI (CPA) gateways behind `claude --cpa <name>`. BOTH halves are secret: the base
    # URLs carry private hostnames, which never land in this public repo. The <PROFILE>_CPA_*
    # naming is load-bearing — the fish wrapper upper-cases whatever profile you typed to derive
    # the var names, so adding a gateway is one vault item + two rows HERE and no fish edit.
    ("ATVIK_CPA_BASE_URL",           "Atvik CPA",                "field", "base_url"),
    ("ATVIK_CPA_TOKEN",              "Atvik CPA",                "field", "token"),
    ("HOME_CPA_BASE_URL",            "Home CPA",                 "field", "base_url"),
    ("HOME_CPA_TOKEN",               "Home CPA",                 "field", "token"),
]

REPO_ROOT = Path(__file__).resolve().parent.parent
SECRETS_YAML = REPO_ROOT / "secrets" / "secrets.yaml"
AGE_KEY = Path.home() / ".config" / "age" / "age.agekey"
# FISHENV_AGE overrides the source path for dry-run tests against a throwaway copy.
FISHENV_AGE = Path(
    os.environ.get("FISHENV_AGE")
    or REPO_ROOT / "dotfiles" / "dot_config" / "fish" / "fishconfig.d" / "encrypted_private_secrets.fish.age"
)


def die(msg: str) -> "NoReturn":  # noqa: F821 - typing only
    raise SystemExit(f">> {msg}")


def out(args, *, env=None, stdin=None) -> str:
    """Run a command, return stdout text, fail loudly. stderr stays on the tty (for prompts)."""
    r = subprocess.run(args, stdout=subprocess.PIPE, input=stdin, text=True,
                       env=({**os.environ, **env} if env else None))
    if r.returncode != 0:
        die(f"command failed: {' '.join(args)}")
    return r.stdout


# == Bitwarden ==
_ITEM_CACHE: dict[str, dict] = {}


def bw_unlock() -> str:
    """Return a usable BW_SESSION. Reuse an already-unlocked session from the env if present
    (so a caller that exports BW_SESSION isn't re-prompted), else login/unlock interactively."""
    existing = os.environ.get("BW_SESSION")
    status = json.loads(out(["bw", "status"]))["status"]
    if existing and status == "unlocked":
        session = existing
    elif status == "unauthenticated":
        session = out(["bw", "login", "--raw"]).strip()   # prompt on tty, token on stdout
    else:
        session = out(["bw", "unlock", "--raw"]).strip()
    if not session:
        die("bw unlock failed (no session)")
    # Pull server-side edits/renames first — a stale cache silently misses items.
    subprocess.run(["bw", "sync"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                   env={**os.environ, "BW_SESSION": session})
    return session


def bw_lock() -> None:
    subprocess.run(["bw", "lock"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def bwitem(name: str, session: str) -> dict:
    """Resolve to the ONE item whose name matches EXACTLY (case-insensitive); cache it.
    `bw get item` fuzzy-matches name+URIs+notes, so we list+filter to avoid false hits."""
    if name in _ITEM_CACHE:
        return _ITEM_CACHE[name]
    items = json.loads(out(["bw", "list", "items", "--search", name], env={"BW_SESSION": session}))
    exact = [it for it in items if (it.get("name") or "").lower() == name.lower()]
    if len(exact) != 1:
        die(f'expected exactly one item named "{name}", got {len(exact)}')
    _ITEM_CACHE[name] = exact[0]
    return exact[0]


def field_of(item: dict, fname: str):
    for f in item.get("fields") or []:
        if f.get("name") == fname:
            return f.get("value")
    return None


def username_of(item: dict) -> str:
    u = (item.get("login") or {}).get("username") or ""
    if u:
        return u
    for f in item.get("fields") or []:
        if f.get("name") in ("User Name", "Username"):
            return f.get("value") or ""
    return ""


def note_of(item: dict) -> str:
    """Secure-note body, verbatim. Only trailing-newline-normalize: BW's editor strips the final
    newline, but the rendered files (rclone conf, smb creds) want POSIX-style text."""
    val = item.get("notes") or ""
    if val and not val.endswith("\n"):
        val += "\n"
    return val


def host_of(item: dict) -> str:
    val = None
    for f in item.get("fields") or []:
        if f.get("name") == "Website":
            val = f.get("value")
            break
    if not val:
        uris = (item.get("login") or {}).get("uris") or []
        if uris:
            val = uris[0].get("uri")
    val = re.sub(r"/.*$", "", re.sub(r"^[a-z]+://", "", val or ""))
    return val


def strip_mcp(v: str) -> str:
    """Drop a trailing /mcp (optionally slash-terminated) from an MCP URL, for clients that
    re-append it. Origin-only URLs pass through untouched."""
    return re.sub(r"/mcp/?$", "", v)


def resolve_rows(manifest, session) -> list[tuple[str, str]]:
    """Resolve every manifest row to (key, value). ASSUMES the vault is already unlocked, so both
    channels share one unlock + one warm _ITEM_CACHE. Fails loudly on the first empty/null value."""
    resolved = []
    for key, item_name, kind, sel in manifest:
        item = bwitem(item_name, session)
        if kind == "field":
            value = field_of(item, sel)
        elif kind == "host":
            value = host_of(item)
        elif kind == "note":
            value = note_of(item)
        elif kind == "mcpbase":
            v = field_of(item, sel)
            value = strip_mcp(v) if v else v
        elif kind == "basicauth":
            bauser, _, fld = sel.partition(":")
            btok = field_of(item, fld)
            if bauser == "@":
                bauser = username_of(item)
            if not bauser or bauser == "null":
                die(f"empty username for {key} (item '{item_name}') — set the login Username or a 'User Name' field")
            if not btok or btok == "null":
                die(f"empty token for {key} (item '{item_name}', field '{fld}')")
            value = base64.b64encode(f"{bauser}:{btok}".encode()).decode()
        else:
            die(f"unknown kind '{kind}' for {key}")
        if value is None or value == "" or value == "null":
            die(f"empty value for {key} (item '{item_name}', {kind} '{sel}') — check the Bitwarden item/field")
        resolved.append((key, value))
    return resolved


# == sops channel ==
def apply_sops(rows) -> None:
    if not SECRETS_YAML.exists():
        die(f"{SECRETS_YAML} missing")
    for path, value in rows:
        grp, _, key = path.partition("/")
        # JSON-encode the value (== jq -Rs .) so a quote/backslash can't break the path expression.
        subprocess.run(["sops", "set", str(SECRETS_YAML), f'["{grp}"]["{key}"]', json.dumps(value)],
                       check=True)
        print(f">> set {path}", file=sys.stderr)


def emit_yaml(rows) -> str:
    """Assemble resolved rows as plaintext YAML grouped by first path segment, for secrets:init."""
    groups: dict[str, list[tuple[str, str]]] = {}
    for path, value in sorted(rows):
        grp, _, key = path.partition("/")
        groups.setdefault(grp, []).append((key, value))
    lines = []
    for grp, kvs in groups.items():
        lines.append(f"{grp}:")
        for key, value in kvs:
            esc = value.replace("\\", "\\\\").replace('"', '\\"')
            lines.append(f'    {key}: "{esc}"')
    return "\n".join(lines)


# == fish env channel ==
def quote_fish(v: str) -> str:
    """Wrap a value as a fish single-quoted string. Inside single quotes fish only honours \\\\ and
    \\' — everything else is literal — so those are the only two escapes needed."""
    return "'" + v.replace("\\", "\\\\").replace("'", "\\'") + "'"


def merge_fishenv(old_text: str, rows) -> str:
    """Surgically rewrite ONLY the managed `set -gx VAR 'value'` lines, leaving every other line
    (hand-set vars, comments, blanks) byte-identical — the env-var analogue of a per-key `sops set`.
    Match by EXACT var name (never a prefix: TRILIUM_PERSONAL_URL is a prefix of *_MCP_URL). Unseen
    managed vars append at EOF under a one-time header, in manifest order. Idempotent: re-running
    with unchanged values reproduces byte-identical lines, so callers can no-op on `old == new`.

    We emit `set -gx` (global-exported, per-session), NOT `set -Ux`: these secrets are re-provisioned
    from THIS file on every rotation, so a UNIVERSAL var (persisted in fish_variables, shared across
    all live sessions) turns rotation into a footgun — the stale value sticks in the universal store
    and in already-running sessions until you `set -eU` it, and `chezmoi apply` + a new shell silently
    fail to update. A global var is re-read from this file by each new shell, so pull→apply→new-shell
    just works. We still MATCH legacy `-Ux` lines so the first pull after this change migrates them."""
    managed = dict(rows)
    order = [k for k, _ in rows]
    seen: set[str] = set()

    had_trailing_nl = old_text.endswith("\n")
    body = old_text[:-1] if had_trailing_nl else old_text
    result_lines = []
    for line in body.split("\n"):
        parts = line.split()
        if len(parts) >= 3 and parts[0] == "set" and parts[1] in ("-gx", "-Ux") and parts[2] in managed:
            result_lines.append(f"set -gx {parts[2]} {quote_fish(managed[parts[2]])}")
            seen.add(parts[2])
        else:
            result_lines.append(line)

    missing = [k for k in order if k not in seen]
    if missing:
        if result_lines and result_lines[-1].strip() != "":
            result_lines.append("")
        result_lines.append("# --- secrets-sync managed (fishenv manifest) ---")
        for k in missing:
            result_lines.append(f"set -gx {k} {quote_fish(managed[k])}")

    text = "\n".join(result_lines)
    if had_trailing_nl:
        text += "\n"
    return text


def chezmoi_decrypt(path: Path) -> str:
    r = subprocess.run(["chezmoi", "decrypt", str(path)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if r.returncode != 0:
        die(f"chezmoi decrypt failed: {r.stderr.decode(errors='replace').strip()}")
    return r.stdout.decode()


def chezmoi_encrypt(src: Path) -> bytes:
    r = subprocess.run(["chezmoi", "encrypt", str(src)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if r.returncode != 0:
        die(f"chezmoi encrypt failed: {r.stderr.decode(errors='replace').strip()}")
    return r.stdout


def apply_fish(rows) -> None:
    """Materialize the fish channel idempotently. age ciphertext is NON-deterministic, so the
    no-op test is at the PLAINTEXT layer; the real .age is only ever touched by a single atomic
    os.replace() of an already round-trip-verified ciphertext."""
    if not AGE_KEY.exists():
        die("no age key at ~/.config/age/age.agekey — run 'mise run secrets:key-bootstrap'")
    if not FISHENV_AGE.exists():
        die(f"{FISHENV_AGE} missing")

    old = chezmoi_decrypt(FISHENV_AGE)
    new = merge_fishenv(old, rows)
    if new == old:
        print(">> fishenv: no change", file=sys.stderr)
        return

    # Repo-local temp dir so the final os.replace() is an atomic rename, not a cross-device copy.
    workdir = Path(tempfile.mkdtemp(prefix=".fishenv.", dir=REPO_ROOT))
    try:
        new_fish = workdir / "new.fish"
        new_age = workdir / "new.age"
        new_fish.write_text(new)
        new_age.write_bytes(chezmoi_encrypt(new_fish))
        if chezmoi_decrypt(new_age) != new:
            die("fishenv: re-encrypt failed round-trip verify — aborting, .age untouched")
        os.replace(new_age, FISHENV_AGE)
        print(f">> fishenv: updated {FISHENV_AGE.name}", file=sys.stderr)
    finally:
        for p in workdir.glob("*"):
            p.unlink()
        workdir.rmdir()


def require_sops_env() -> None:
    if not os.environ.get("SOPS_AGE_KEY_FILE"):
        die("export SOPS_AGE_KEY_FILE (the age identity) first")


# == subcommands ==
def cmd_set():
    require_sops_env()
    session = bw_unlock()
    rows = resolve_rows(SOPS_MANIFEST, session)
    bw_lock()
    apply_sops(rows)


def cmd_emit():
    session = bw_unlock()
    rows = resolve_rows(SOPS_MANIFEST, session)
    bw_lock()
    print(emit_yaml(rows))


def cmd_paths():
    for path, item, _kind, _sel in SOPS_MANIFEST:
        print(f"{path}\t{item}")


def cmd_inventory():
    """Full Bitwarden-backed inventory across BOTH channels — the manifests ARE the docs.
    (`paths` stays sops-only: two mise tasks parse its 2-column format.)"""
    for path, item, kind, _sel in SOPS_MANIFEST:
        print(f"sops\t{path}\t{item}\t{kind}")
    for var, item, kind, _sel in FISHENV_MANIFEST:
        print(f"fishenv\t{var}\t{item}\t{kind}")


# ── What's actually IN secrets.yaml (vs. what the manifest says SHOULD be) ──────────────────
# The manifest above is the intent; the YAML is the reality. Drift is the set difference, and
# `mise run apply` gates on it. This used to be a hand-rolled YAML parser in POSIX sh (a `while
# read` loop with a `case` statement, a `sed -E` and an `awk`), plus a second copy of the same
# idea inline in the apply preflight.
#
# NO YAML LIBRARY ON PURPOSE. This script has a plain `#!/usr/bin/env python3` shebang, and the
# python3 on PATH is home-manager's withPackages(pip requests evtx) — it has no `yaml` module. A
# module-scope `import yaml` would kill EVERY subcommand, including `paths`, which mise's apply
# calls BEFORE the first nixos-rebuild. That would brick the bootstrap on a fresh box.
#
# We can get away without one: sops encrypts VALUES but leaves KEYS in plaintext, and the file is
# a fixed two-level shape. This mirrors lib/secrets.nix exactly — the two MUST agree, which
# cmd_selftest asserts against the real file.

def yaml_paths() -> list[str]:
    """group/key paths present in secrets.yaml. Needs no age identity — keys are plaintext."""
    found: list[str] = []
    group: str | None = None
    for line in SECRETS_YAML.read_text().splitlines():
        # Everything from `sops:` on is sops' own metadata (age recipients, mac, lastmodified).
        if line == "sops:":
            break
        if m := re.fullmatch(r"([a-z0-9_]+):", line):
            group = m.group(1)
        elif group and (m := re.fullmatch(r"\s+([a-z0-9_]+):.*", line)):
            found.append(f"{group}/{m.group(1)}")
    return found


def cmd_yaml_paths():
    for path in yaml_paths():
        print(path)


def cmd_missing():
    """Manifest paths NOT yet in secrets.yaml — the rows `secrets:pull` still owes you.
    Empty output + exit 0 when in sync, so callers can just test for a non-empty string."""
    present = set(yaml_paths())
    for path, _item, _kind, _sel in SOPS_MANIFEST:
        if path not in present:
            print(path)


def cmd_list():
    """Every key in secrets.yaml, marked manifest-managed (secrets:pull) vs hand-set
    (secrets:edit). Read-only — decrypts nothing."""
    managed = {path: item for path, item, _kind, _sel in SOPS_MANIFEST}
    for path in yaml_paths():
        item = managed.get(path)
        print(f"  {path:<26} [manifest: {item}]" if item else f"  {path:<26} [hand-set]")


def cmd_fishenv():
    session = bw_unlock()
    rows = resolve_rows(FISHENV_MANIFEST, session)
    bw_lock()
    apply_fish(rows)


def cmd_fishenv_emit():
    if not FISHENV_AGE.exists():
        die(f"{FISHENV_AGE} missing")
    session = bw_unlock()
    rows = resolve_rows(FISHENV_MANIFEST, session)
    bw_lock()
    sys.stdout.write(merge_fishenv(chezmoi_decrypt(FISHENV_AGE), rows))


def cmd_sync_all():
    require_sops_env()
    if not SECRETS_YAML.exists():
        die(f"{SECRETS_YAML} missing")
    if not AGE_KEY.exists():
        die("no age key at ~/.config/age/age.agekey")
    session = bw_unlock()
    sops_rows = resolve_rows(SOPS_MANIFEST, session)
    fish_rows = resolve_rows(FISHENV_MANIFEST, session)
    bw_lock()
    apply_sops(sops_rows)
    apply_fish(fish_rows)


# ── The age IDENTITY that decrypts everything else ─────────────────────────────────────────────
# Ported from ~50 lines of shell in mise.toml, which reimplemented bw_unlock/bwitem/field_of via
# `bw status | jq`, `bw get item | jq -r '.fields[]|select(...)'` etc. Beyond deleting the
# duplication, folding it in here means a fresh box unlocks the vault ONCE instead of twice: the
# shell version ended with `bw lock`, and then secrets-sync.py immediately called bw_unlock() again.
# Sharing the session and the warm _ITEM_CACHE saves a master-password prompt.

SOPS_KEY = Path("/var/lib/sops-nix/key.txt")          # system: sops-nix, root-owned
CHEZMOI_KEY = Path.home() / ".config/age/age.agekey"  # user: chezmoi


def bw_set_server() -> None:
    """Point the CLI at our Vaultwarden, if it isn't already.

    Subtle and load-bearing: `bw config server` is REJECTED while authenticated ("logout required
    before server config update"), so changing the endpoint means logging out FIRST — but only when
    it actually differs. An already-correct server must be a silent no-op with no logout, or every
    bootstrap would gratuitously drop an existing session.
    """
    current = (json.loads(out(["bw", "status"])).get("serverUrl") or "")
    want = os.environ.get("BW_SERVER", "")
    if not want and not current:
        want = input("Bitwarden server URL: ").strip()
    if want and want != current:
        subprocess.run(["bw", "logout"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        out(["bw", "config", "server", want])


def cmd_key_bootstrap():
    """Fresh install: pull the ONE age key from Bitwarden into both identities.

    ITEM=<name> to override the item, FORCE=1 to overwrite. Idempotent: a no-op (exit 0, no vault
    prompt) when either key already exists, because clobbering a key is how you lose access to
    every secret encrypted to the old one.
    """
    item_name = os.environ.get("ITEM", "AGE SOPS Key")

    if not os.environ.get("FORCE") and (SOPS_KEY.exists() or CHEZMOI_KEY.exists()):
        print(f">> key already present ({SOPS_KEY} / {CHEZMOI_KEY}) — skipping. FORCE=1 to overwrite.")
        return

    bw_set_server()
    session = bw_unlock()
    try:
        key = field_of(bwitem(item_name, session), "secret key")
    finally:
        bw_lock()
    if not key:
        die(f'field "secret key" not found in item "{item_name}"')

    # Stage at 0600 via umask so the key is never briefly world-readable, then install to both.
    os.umask(0o077)
    with tempfile.NamedTemporaryFile("w", delete=False) as tmp:
        tmp.write(key.rstrip("\n") + "\n")
        staged = tmp.name
    try:
        out(["sudo", "install", "-Dm600", staged, str(SOPS_KEY)])
        out(["install", "-Dm600", staged, str(CHEZMOI_KEY)])
    finally:
        os.unlink(staged)

    print(f">> installed {SOPS_KEY} + {CHEZMOI_KEY} — now: mise run apply")


def cmd_selftest():
    # note kind: body verbatim, but normalized to end in exactly one newline (BW strips it)
    assert note_of({"notes": "[section]\nkey = val"}) == "[section]\nkey = val\n"
    assert note_of({"notes": "user=x\npass=y\n"}) == "user=x\npass=y\n"
    assert note_of({"notes": None}) == ""
    # quoting: backslash first, then single-quote, both escaped for a fish single-quoted string
    assert quote_fish("plain") == "'plain'"
    assert quote_fish("a'b\\c") == "'a\\'b\\\\c'", quote_fish("a'b\\c")
    # url/token values (the real shape) pass through untouched inside quotes
    assert quote_fish("https://h/x") == "'https://h/x'"
    # mcpbase kind: strip a trailing /mcp (the plugin re-appends it); origin-only is untouched
    assert strip_mcp("https://memini.h/mcp") == "https://memini.h"
    assert strip_mcp("https://memini.h/mcp/") == "https://memini.h"
    assert strip_mcp("https://memini.h") == "https://memini.h"

    old = (
        "# header comment\n"
        "set -Ux KEEP_ME plainvalue\n"          # hand-set, UNQUOTED — must survive verbatim
        "\n"
        "# --- managed ---\n"
        "set -Ux FOO 'oldval'\n"
    )
    new = merge_fishenv(old, [("FOO", "newval"), ("BAR", "https://x/y")])
    assert "set -Ux KEEP_ME plainvalue" in new, "hand-set var clobbered"
    # Managed vars are emitted as -gx (see merge_fishenv's docstring on why universal vars turn a
    # rotation into a footgun). A legacy -Ux line for a MANAGED var is migrated to -gx on the next
    # pull — which is exactly what FOO exercises here.
    assert "set -gx FOO 'newval'" in new, "managed var not updated (or not migrated -Ux -> -gx)"
    assert "set -gx BAR 'https://x/y'" in new, "new managed var not appended"
    assert "# header comment" in new, "comment lost"
    # idempotency: same values is a fixed point
    assert merge_fishenv(new, [("FOO", "newval"), ("BAR", "https://x/y")]) == new, "merge not idempotent"
    # no-op: an already-migrated line with an unchanged value reproduces byte-identical text
    base = "set -gx X 'v'\n"
    assert merge_fishenv(base, [("X", "v")]) == base, "unchanged value should be a no-op"
    # legacy migration: a -Ux line for a MANAGED var is rewritten, even when the value is unchanged
    assert merge_fishenv("set -Ux X 'v'\n", [("X", "v")]) == "set -gx X 'v'\n", "legacy -Ux not migrated"
    # exact-name match: a prefix var must NOT be rewritten by a longer managed name
    pre = "set -Ux TRILIUM_PERSONAL_URL 'keep'\n"
    assert merge_fishenv(pre, [("TRILIUM_PERSONAL_MCP_URL", "other")]).startswith(
        "set -Ux TRILIUM_PERSONAL_URL 'keep'"), "prefix collision rewrote the wrong var"

    # yaml_paths must agree with lib/secrets.nix — the Nix modules gate on the same vocabulary, so
    # a divergence means the eval-time gate and the ops tooling disagree about what exists.
    # The group qualifier is the point: modules/smb-mounts.nix used to ask for the bare "smb_creds"
    # while the real key is "main_smb_creds", and matched only by accident of substring search.
    paths = yaml_paths()
    assert "smb/main_smb_creds" in paths, "the real SMB key must be found, group-qualified"
    assert "smb/smb_creds" not in paths, "a bare substring must NOT masquerade as a key"
    assert not any(p.startswith("sops/") for p in paths), "the sops: metadata block is not a secret"
    assert len(paths) == len(set(paths)), "duplicate paths"
    manifest = {p for p, _i, _k, _s in SOPS_MANIFEST}
    assert manifest <= set(paths), f"manifest keys absent from secrets.yaml: {manifest - set(paths)}"
    print("selftest: OK")


COMMANDS = {
    "set": cmd_set,
    "emit": cmd_emit,
    "paths": cmd_paths,
    "yaml-paths": cmd_yaml_paths,
    "missing": cmd_missing,
    "list": cmd_list,
    "inventory": cmd_inventory,
    "fishenv": cmd_fishenv,
    "fishenv-emit": cmd_fishenv_emit,
    "sync-all": cmd_sync_all,
    "key-bootstrap": cmd_key_bootstrap,
    "selftest": cmd_selftest,
}


def main(argv):
    cmd = argv[1] if len(argv) > 1 else "set"
    fn = COMMANDS.get(cmd)
    if not fn:
        die(f"usage: {Path(argv[0]).name} {{{'|'.join(COMMANDS)}}}")
    fn()


if __name__ == "__main__":
    main(sys.argv)
