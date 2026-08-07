"""claude-cred — swap the Claude Code login in ~/.claude/.credentials.json.

Python port of the fish implementation (design: docs/superpowers/specs/
2026-08-06-claude-cred-python-rewrite-design.md). The behavioral contract lives in
claude_cred_test.py; the WHY-comments here carry the incident lore that produced it.

~/.claude/.credentials.json holds TWO independent things: `claudeAiOauth` (the Claude login)
and `mcpOAuth` (per-MCP-server tokens). Only the former identifies the account, so every
write PATCHES .claudeAiOauth and leaves mcpOAuth untouched — a writer that rebuilds the
document instead of patching it silently nukes the MCP logins.

Identity model (since 2026-07-23): the account EMAIL, verified against Anthropic's own
oauth/profile endpoint, is the source of truth for which profile a token belongs to. The
`.active` pointer file survives only as an offline hint / prompt default — trusting it
blindly is how the 2026-07-22 incident cross-pollinated the profiles.
"""
import argparse
import getpass
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

# The same public client_id the Claude Code binary uses for its own token exchange.
CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
PROFILE_URL = "https://api.anthropic.com/api/oauth/profile"
TOKEN_URL = "https://console.anthropic.com/v1/oauth/token"
OAUTH_BETA = "oauth-2025-04-20"

# Non-empty but dead: Claude Code treats an EMPTY accessToken as "not logged in" and never
# reaches its refresh branch, so every path that can't supply a real token writes THIS
# instead. One source of truth — show/doctor/capture all key off it.
PLACEHOLDER = "sk-ant-oat01-PENDING-REFRESH-claude-cred"


class CredError(Exception):
    """Human-facing failure; main() prints it as `claude-cred: {msg}` and exits 1."""


class NetworkError(Exception):
    """Transport-level failure (unreachable, timeout) — distinct from an HTTP error status."""


# ── paths & modes ──────────────────────────────────────────────────────────────────────────


class Paths:
    def __init__(self, creds: Path):
        self.creds = creds
        self.base = creds.parent
        self.profiles = self.base / "cred-profiles"
        self.backups = self.base / "cred-backups"


def paths() -> Paths:
    # CLAUDE_CRED_FILE retargets EVERYTHING (creds + profiles + backups all hang off its
    # dirname), so the test suite can drive this against a fixture without touching the
    # real login.
    env = os.environ.get("CLAUDE_CRED_FILE")
    if env:
        return Paths(Path(env))
    return Paths(Path.home() / ".claude" / ".credentials.json")


def fixture_mode() -> bool:
    return bool(os.environ.get("CLAUDE_CRED_FILE"))


def offline() -> bool:
    # Fixture mode forces offline so tests are deterministic and exercise every
    # prompt/fallback path; CLAUDE_CRED_OFFLINE is the airplane-mode switch for live use.
    return fixture_mode() or bool(os.environ.get("CLAUDE_CRED_OFFLINE"))


# ── atomic, never-world-readable writes ────────────────────────────────────────────────────


def atomic_write(dest: Path, text: str) -> None:
    """0600 from birth, atomic rename, refuses invalid JSON.

    The temp file is created 0600 BEFORE any content lands in it, so the token is never
    world-readable, not even for an instant. os.replace within one directory is an atomic
    rename, so a crash mid-write can't leave a half-written credentials file behind.
    """
    try:
        json.loads(text)
    except ValueError:
        raise CredError(f"refusing to write invalid JSON to {dest}")
    tmp = dest.with_name(f"{dest.name}.tmp.{os.getpid()}")
    try:
        tmp.unlink(missing_ok=True)
        fd = os.open(tmp, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        try:
            os.write(fd, text.encode())
        finally:
            os.close(fd)
        os.replace(tmp, dest)
    except OSError as e:
        tmp.unlink(missing_ok=True)
        raise CredError(f"write to {dest} failed: {e}")


def atomic_write_json(dest: Path, obj) -> None:
    atomic_write(dest, json.dumps(obj, indent=2) + "\n")


def backup(p: Paths) -> Path:
    """Undo buffer, not an archive: 0600 verbatim copy, keep the last 10 .json files.

    Rescue files (.json.rescue) are deliberately outside the *.json glob — a rescue
    fragment holds the only copy of a rotated refresh token and must never be swept.
    """
    import time
    p.backups.mkdir(mode=0o700, exist_ok=True)
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    dest = p.backups / f"{stamp}.json"
    n = 0
    while dest.exists():  # same-second collision: suffix rather than overwrite
        n += 1
        dest = p.backups / f"{stamp}-{n}.json"
    data = p.creds.read_bytes()
    fd = os.open(dest, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    try:
        os.write(fd, data)
    finally:
        os.close(fd)
    stale = sorted(p.backups.glob("*.json"), key=lambda f: f.stat().st_mtime, reverse=True)[10:]
    for f in stale:
        f.unlink(missing_ok=True)
    return dest


# ── profile shapes: v1/v2/v3 bridge ────────────────────────────────────────────────────────
# v1 IS the bare oauth object; v2 wraps it in {version, email, …, claudeAiOauth}; v3 adds
# kind ("refresh" | "setup") and setup-kind stores a long-lived setupToken instead of an
# oauth object. Detection is structural — never trust a version field to describe a shape
# it sits inside.


def profile_kind(data: dict) -> str:
    if "setupToken" in data or data.get("kind") == "setup":
        return "setup"
    return "refresh"


def profile_oauth(data: dict):
    if profile_kind(data) == "setup":
        return None
    if "claudeAiOauth" in data:
        return data["claudeAiOauth"]
    return data


def profile_email(data: dict) -> str:
    if "claudeAiOauth" in data or "setupToken" in data:
        return data.get("email") or ""
    return ""  # v1 records nothing


def load_profile(path: Path) -> dict:
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError) as e:
        raise CredError(f"can't read profile {path.name}: {e}")


def find_profiles_by_email(p: Paths, email: str) -> list:
    if not email:
        return []
    out = []
    for f in sorted(p.profiles.glob("*.json")):
        try:
            if profile_email(json.loads(f.read_text())) == email:
                out.append(f.stem)
        except ValueError:
            continue  # corrupt profile: doctor's problem, not a crash
    return out


# ── active-profile pointer (offline hint / prompt default ONLY) ────────────────────────────


def get_active(p: Paths) -> str:
    try:
        return (p.profiles / ".active").read_text().strip()
    except OSError:
        return ""


def set_active(p: Paths, name: str) -> None:
    p.profiles.mkdir(mode=0o700, exist_ok=True)
    ptr = p.profiles / ".active"
    if name:
        ptr.write_text(name + "\n")
    else:
        ptr.unlink(missing_ok=True)


# ── prompts ────────────────────────────────────────────────────────────────────────────────


def assume_tty() -> bool:
    return bool(os.environ.get("CLAUDE_CRED_ASSUME_TTY"))


def prompt(prompt_str: str, prefill: str):
    """Every interactive question funnels through here so non-interactive callers can never
    hang: no TTY → None immediately, and the caller decides between skip-with-warning and
    hard error. Returns the trimmed answer ("" is a valid decline), None on no-TTY/EOF.
    CLAUDE_CRED_ASSUME_TTY lets the offline test suite pipe answers in."""
    if not sys.stdin.isatty() and not assume_tty():
        return None
    if sys.stdin.isatty():
        # Prefill the EDITABLE buffer: Enter accepts the suggestion, wiping it declines.
        # That's what lets "default offered" and "empty = skip" coexist without ambiguity.
        try:
            import readline
            readline.set_startup_hook(lambda: readline.insert_text(prefill))
            try:
                return input(prompt_str).strip()
            finally:
                readline.set_startup_hook()
        except EOFError:
            return None
        except ImportError:
            print(prompt_str, end="", file=sys.stderr, flush=True)
    # Piped answers (ASSUME_TTY test mode): no prompt echo, EOF → None.
    line = sys.stdin.readline()
    if line == "":
        return None
    return line.strip()


# ── HTTP transport (the ONE injectable seam — tests replace HTTP_REQUEST) ──────────────────


def _urllib_request(url: str, headers: dict, body, timeout: int):
    """Returns (http_status, response_body_text). Raises NetworkError when no HTTP answer
    exists at all. Tokens travel only inside this process — no curl argv, no /proc leak."""
    req = urllib.request.Request(url, data=body, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        raise NetworkError(str(e))


HTTP_REQUEST = _urllib_request


# ── identity + token exchange ──────────────────────────────────────────────────────────────


def identity(token: str):
    """Resolve a token to its account via Anthropic's oauth/profile endpoint (the same one
    the CC binary talks to). Returns (rc, info): 0 = verified (info dict) · 1 = token
    rejected (expired/revoked, or a placeholder we never send) · 2 = network trouble ·
    3 = offline mode."""
    if offline():
        return 3, None
    if not token or token == PLACEHOLDER:
        return 1, None
    headers = {"Authorization": f"Bearer {token}", "anthropic-beta": OAUTH_BETA}
    try:
        status, body = HTTP_REQUEST(PROFILE_URL, headers, None, 10)
    except NetworkError:
        return 2, None
    if status >= 400:
        return 1, None
    try:
        data = json.loads(body)
    except ValueError:
        return 2, None
    acct = data.get("account") or {}
    plan = "max" if acct.get("has_claude_max") else ("pro" if acct.get("has_claude_pro") else "")
    return 0, {
        "email": acct.get("email") or "",
        "uuid": acct.get("uuid") or "",
        "org": (data.get("organization") or {}).get("name") or "",
        "plan": plan,
    }


class ExchangeResult:
    """`dead` is the load-bearing bit: a dead token (400/401/403) means "reseed it" while a
    transient failure (429/network) means "retry later" — opposite user actions, and for
    exchange-at-use the difference between aborting a swap and falling back to the
    placeholder splice."""

    def __init__(self, ok, minted, reason, dead=False):
        self.ok = ok
        self.minted = minted
        self.reason = reason
        self.dead = dead


def oauth_refresh(token: str) -> ExchangeResult:
    """Mint fresh credentials from a refresh token — the same exchange, against the same
    public client_id, that the CC binary performs on launch. Unofficial endpoint: callers
    MUST tolerate failure and fall back to the placeholder mechanism."""
    if offline():
        return ExchangeResult(False, None, "offline mode — exchange skipped")
    payload = json.dumps({"grant_type": "refresh_token", "refresh_token": token,
                          "client_id": CLIENT_ID}).encode()
    try:
        status, body = HTTP_REQUEST(TOKEN_URL, {"Content-Type": "application/json"}, payload, 30)
    except NetworkError:
        return ExchangeResult(False, None, "endpoint unreachable (network)")
    try:
        data = json.loads(body)
    except ValueError:
        data = {}
    etype = (data.get("error") or {}).get("type") or ""

    if status == 200:
        # A 200 without the fields we need is still a failure — never write partial creds.
        if data.get("access_token") and (data.get("expires_in") or 0) > 0:
            return ExchangeResult(True, data, "")
        return ExchangeResult(
            False, None, "endpoint returned 200 but no usable tokens (response shape changed?)")
    if status == 429:
        return ExchangeResult(False, None, "rate limited (HTTP 429) — wait a few minutes and retry")
    if status in (400, 401, 403):
        extra = f" {etype}" if etype else ""
        return ExchangeResult(
            False, None,
            f"refresh token rejected (HTTP {status}{extra}) — it's dead; reseed from the source machine",
            dead=True)
    extra = f" ({etype})" if etype else ""
    return ExchangeResult(False, None, f"exchange failed (HTTP {status}{extra})")


# ── creds file access ──────────────────────────────────────────────────────────────────────


def require_creds(p: Paths) -> dict:
    if not p.creds.is_file():
        raise CredError(f"{p.creds} not found — run 'claude' and log in first")
    try:
        data = json.loads(p.creds.read_text())
    except ValueError:
        raise CredError(f"{p.creds} is not valid JSON — 'claude-cred undo' may recover it")
    if "claudeAiOauth" not in data:
        raise CredError(f"{p.creds} has no .claudeAiOauth section — not a Claude Code login")
    return data


def read_creds(p: Paths) -> dict:
    return json.loads(p.creds.read_text())


def patch_creds_oauth(p: Paths, new_oauth: dict) -> None:
    """The ONLY way credentials.json is modified: replace .claudeAiOauth, leave every other
    key (mcpOAuth!) exactly as found."""
    data = read_creds(p)
    data["claudeAiOauth"] = new_oauth
    atomic_write_json(p.creds, data)


def notice_running() -> None:
    # NOT a blocking guard: CC's credential store is built for concurrent sessions
    # (read-modify-write, compare-and-swap on invalid-grant, atomic renames — see the fish
    # version's disassembly notes). But a session already running keeps using the OLD
    # account's in-memory access token until it refreshes or restarts — worth saying.
    if fixture_mode():
        return
    try:
        out = subprocess.run(["pgrep", "-x", "claude"], capture_output=True, text=True)
    except OSError:
        return
    pids = [ln for ln in out.stdout.split() if ln]
    if pids:
        print(f"claude-cred: note — {len(pids)} Claude Code session(s) running.", file=sys.stderr)
        print("  They keep using the OLD account until you restart them.", file=sys.stderr)


def rescue(p: Paths, at: str, rt: str, expires_at: int) -> None:
    """The exchange succeeded but the creds write didn't: the ROTATED refresh token exists
    only in this process, and losing it can strand the account. Park it in a 0600 file.
    The extension is deliberately NOT .json: undo and the backup sweep glob *.json, and a
    rescue fragment (no mcpOAuth) must never be swept away — or restored over the real
    file by undo."""
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    dest = p.backups / f"rescue-{stamp}.json.rescue"
    try:
        p.backups.mkdir(mode=0o700, exist_ok=True)
        atomic_write_json(dest, {"claudeAiOauth": {
            "accessToken": at, "refreshToken": rt, "expiresAt": expires_at}})
        print("claude-cred: creds write FAILED after a successful token exchange.", file=sys.stderr)
        print(f"  The minted (rotated) tokens are parked in: {dest}", file=sys.stderr)
    except CredError:
        # Printing to the terminal is the very last resort — stderr is not shell history,
        # and losing the only copy of a rotated refresh token is worse than showing it.
        print("claude-cred: creds write AND rescue write failed. SAVE THIS NOW — rotated refresh token:",
              file=sys.stderr)
        print(f"  {rt}", file=sys.stderr)


# ── chezmoi round-trip ─────────────────────────────────────────────────────────────────────


def chezmoi_enabled() -> bool:
    # Fixture mode also disables the round-trip: chezmoi only manages paths under $HOME,
    # and a fixture in /tmp isn't one.
    return not fixture_mode() and shutil.which("chezmoi") is not None


def chezmoi_roundtrip(dest: Path, name: str) -> None:
    if not chezmoi_enabled():
        print(f"claude-cred: saved profile '{name}' (plaintext — chezmoi round-trip skipped)")
        return
    # re-add is chezmoi's own mechanism for updating an already-managed file; it preserves
    # the encrypted_ attribute, so we don't have to re-specify --encrypt.
    managed = subprocess.run(["chezmoi", "managed"], capture_output=True, text=True)
    if f".claude/cred-profiles/{name}.json" in managed.stdout:
        r = subprocess.run(["chezmoi", "re-add", str(dest)])
    else:
        r = subprocess.run(["chezmoi", "add", "--encrypt", str(dest)])
    if r.returncode != 0:
        raise CredError(f"chezmoi round-trip failed for '{name}'")
    print(f"claude-cred: saved profile '{name}' (age-encrypted into the chezmoi source)")

    # The repo is public and this writes a NEW token blob — the human decides when it lands
    # in history, so print the command instead of running it. A brand-new profile is also
    # untracked, and the flake's #1 gotcha is that flakes only see git-tracked files.
    # NB: `chezmoi source-path` is …/dotfiles (the .chezmoiroot redirect), NOT the git root.
    src = subprocess.run(["chezmoi", "source-path"], capture_output=True, text=True).stdout.strip()
    if not src:
        return
    repo = subprocess.run(["git", "-C", src, "rev-parse", "--show-toplevel"],
                          capture_output=True, text=True).stdout.strip()
    if not repo:
        return
    dirty = subprocess.run(["git", "-C", repo, "status", "--porcelain", "--", "dotfiles/dot_claude"],
                           capture_output=True, text=True).stdout.strip()
    if dirty:
        print("  Uncommitted (ciphertext — safe for the public repo):")
        print(f"    git -C {repo} add -A dotfiles/dot_claude")


def chezmoi_materialize(src: Path) -> None:
    # A profile can exist in the chezmoi source but not yet on this box (fresh machine, or
    # a profile saved elsewhere and pulled in via git). Materialize on demand, not error.
    if not src.is_file() and chezmoi_enabled():
        subprocess.run(["chezmoi", "apply", str(src)], capture_output=True)


# ── save / capture ─────────────────────────────────────────────────────────────────────────


def sanitize_name(email: str) -> str:
    return re.sub(r"[^A-Za-z0-9._-]", "", email.split("@")[0])


def validate_name(name: str) -> None:
    if not re.fullmatch(r"[A-Za-z0-9._-]+", name):
        raise CredError(f"invalid profile name '{name}'")


def overwrite_guard(dest: Path, name: str, email: str) -> None:
    """Anti-pollution guard: never overwrite a profile that RECORDS a different owner
    without the human confirming. (v1 profiles record nothing, so it can't fire on them.)"""
    if not email or not dest.is_file():
        return
    stored = profile_email(load_profile(dest))
    if not stored or stored == email:
        return
    answer = prompt(f"profile '{name}' holds {stored} but the live login is {email} — overwrite? [y/N] ", "")
    if answer is None:
        raise CredError(f"refusing to overwrite '{name}' ({stored}) with {email} non-interactively")
    if not answer.lower().startswith("y"):
        raise CredError(f"not overwriting '{name}'")


def save_profile(p: Paths, name: str, info, lookup: bool = True) -> str:
    """Snapshot the live login into a v3 refresh-kind profile. `info` is a resolved
    identity dict (callers that already fetched it pass it through, so a capture→save
    chain costs a single network round-trip); lookup=False skips resolution entirely
    (capture's known-unverifiable path)."""
    creds = read_creds(p)
    if info is None and lookup:
        rc, resolved = identity(creds["claudeAiOauth"].get("accessToken") or "")
        info = resolved if rc == 0 else None
    email = (info or {}).get("email") or ""
    uuid = (info or {}).get("uuid") or ""
    org = (info or {}).get("org") or ""

    if not name:
        if email:
            matches = find_profiles_by_email(p, email)
            if len(matches) == 1:
                # Verified email → exactly one profile: no prompt needed. Forking a second
                # profile of the same account requires an explicit name.
                name = matches[0]
                print(f"claude-cred: live login is {email} — saving to profile '{name}'")
            else:
                suggestion = matches[0] if matches else sanitize_name(email)
                answer = prompt(f"save live login ({email}) as? ", suggestion)
                if answer is None:
                    raise CredError("give a name: claude-cred save <name>")
                name = answer
        else:
            answer = prompt("save live login (unverified) as? ", get_active(p))
            if answer is None:
                raise CredError("no verifiable identity — give a name: claude-cred save <name>")
            name = answer
        if not name:
            raise CredError("no name given")
    validate_name(name)

    # 0700 so chezmoi records the directory as private_, matching private_dot_kube.
    p.profiles.mkdir(mode=0o700, exist_ok=True)
    dest = p.profiles / f"{name}.json"
    overwrite_guard(dest, name, email)

    # Identity is sticky: an offline re-save of a v2/v3 profile keeps its recorded owner
    # (doctor catches drift) — going backwards to "unknown" would destroy information.
    if not email and dest.is_file():
        stored = load_profile(dest)
        email = profile_email(stored)
        uuid = stored.get("accountUuid") or ""
        org = stored.get("organization") or ""

    # Profiles store the claudeAiOauth object plus identity metadata — never the whole
    # creds file, so a later restore can't roll mcpOAuth back to stale MCP tokens. Emails
    # live only here (age-encrypted in the repo) and in local 0600 files.
    atomic_write_json(dest, {
        "version": 3,
        "kind": "refresh",
        "email": email or None,
        "accountUuid": uuid or None,
        "organization": org or None,
        "savedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "claudeAiOauth": creds["claudeAiOauth"],
    })
    set_active(p, name)
    chezmoi_roundtrip(dest, name)
    return name


def capture_outgoing(p: Paths) -> str:
    """Capture the OUTGOING account before a swap overwrites it — refresh tokens rotate, so
    the live file may hold a NEWER token than the profile does, and losing it leaves a
    dead profile. Identity comes from the token itself (oauth/profile endpoint); .active
    is only ever offered as a prompt DEFAULT, never silently written to — trusting it
    blindly is the 2026-07-22 incident. Returns the resolved profile name, or ''."""
    at = read_creds(p)["claudeAiOauth"].get("accessToken") or ""
    if not at or at == PLACEHOLDER:
        return ""  # a set-refresh is pending; nothing identifiable is live to capture

    rc, info = identity(at)
    if rc == 0:
        email = info["email"]
        matches = find_profiles_by_email(p, email)
        if len(matches) == 1:
            # Verified: the token says whose it is, the profile agrees — safe to save silently.
            print(f"claude-cred: capturing outgoing login ({email}) into profile "
                  f"'{matches[0]}' (refresh tokens rotate)")
            name = matches[0]
        elif len(matches) > 1:
            # Two profiles claiming one email is user-made ambiguity; make them choose.
            default = get_active(p)
            if default not in matches:
                default = matches[0]
            name = prompt(f"save outgoing login ({email}) to which of {matches}? (empty = skip) ", default)
            if name is None:
                print(f"claude-cred: warning — outgoing login ({email}) NOT saved "
                      "(several profiles match, not a TTY)", file=sys.stderr)
                return ""
        else:
            name = prompt(f"save outgoing login ({email}) as? (empty = skip) ", sanitize_name(email))
            if name is None:
                print(f"claude-cred: warning — outgoing login ({email}) NOT saved "
                      "(no matching profile, not a TTY)", file=sys.stderr)
                return ""
        if not name:
            return ""
        return save_profile(p, name, info)

    # Can't verify (expired token / offline). .active is offered as a DEFAULT the human
    # confirms — the one thing the old code did silently, and the heart of the incident.
    name = prompt("save outgoing login (unverified) as? (empty = skip) ", get_active(p))
    if name is None:
        print("claude-cred: warning — outgoing login NOT saved (can't verify identity, not a TTY)",
              file=sys.stderr)
        return ""
    if not name:
        return ""
    return save_profile(p, name, None, lookup=False)


# ── token entry ────────────────────────────────────────────────────────────────────────────


def token_prompt(prompt_str: str):
    """Silent token entry: getpass on a real TTY (never echoed, never in history), a plain
    stdin line in ASSUME_TTY test mode, None when neither is available."""
    if sys.stdin.isatty():
        try:
            return getpass.getpass(prompt_str)
        except EOFError:
            return None
    if assume_tty():
        line = sys.stdin.readline()
        return None if line == "" else line
    return None


def warn_argv_token() -> None:
    print("claude-cred: WARNING — that token is now in your shell history.", file=sys.stderr)
    print("  Next time run the command with no token for a silent prompt.", file=sys.stderr)


# ── commands ───────────────────────────────────────────────────────────────────────────────


def minted_fields(minted: dict, injected_refresh: str):
    """Guarantee 13: the response's refresh_token is the ROTATED one — the injected token
    may be retired server-side the instant the exchange succeeds. OAuth also allows
    omitting refresh_token ("old one still valid"); only then is the injected token the
    right thing to keep."""
    at = minted["access_token"]
    rt = minted.get("refresh_token") or injected_refresh
    expires_at = (int(time.time()) + int(minted["expires_in"])) * 1000
    scopes = (minted.get("scope") or "").split()
    return at, rt, expires_at, scopes


def cmd_set_refresh(args) -> int:
    p = paths()
    require_creds(p)
    token = args.token
    if token:
        # An inline token is written verbatim into shell history, in plaintext, forever.
        # Supported for scripting, but say so out loud.
        warn_argv_token()
    else:
        token = token_prompt("New refresh token: ")
        if token is None:
            raise CredError("set-refresh needs a token argument when stdin is not a TTY")
    token = token.strip()
    if not token:
        raise CredError("no token given")

    # Hard validation BEFORE any side effect. The 2026-07-22 incident started exactly
    # here: an access token was accepted with only a warning, then the pre-write capture
    # scrambled the profiles before the bad token even landed.
    if token.startswith("sk-ant-oat01-"):
        raise CredError(
            "that's an ACCESS token (sk-ant-oat01-…), not a refresh token.\n"
            "  If it came from 'claude setup-token', run: claude-cred add-setup-token\n"
            "  Otherwise copy the refreshToken field (sk-ant-ort01-…) from the source\n"
            "  machine's ~/.claude/.credentials.json.")
    if not token.startswith("sk-ant-ort01-"):
        raise CredError("refusing — that doesn't look like a refresh token (sk-ant-ort01-…).")

    notice_running()
    capture_outgoing(p)
    bkp = backup(p)

    res = oauth_refresh(token)
    if res.ok:
        set_refresh_online(p, token, res.minted, bkp)
    else:
        set_refresh_fallback(p, token, bkp, res.reason)
    return 0


def set_refresh_online(p: Paths, injected: str, minted: dict, bkp: Path) -> None:
    at, rt, expires_at, scopes = minted_fields(minted, injected)
    rc_id, info = identity(at)

    # Full real credentials — no placeholder needed: CC finds an unexpired access token
    # and just works. refreshTokenExpiresAt belonged to the OLD account's clock; CC
    # repopulates it (and rateLimitTier) on its own next refresh.
    oauth = read_creds(p)["claudeAiOauth"]
    oauth.update(accessToken=at, refreshToken=rt, expiresAt=expires_at)
    oauth.pop("refreshTokenExpiresAt", None)
    if rc_id == 0 and info["plan"]:
        oauth["subscriptionType"] = info["plan"]
    if scopes:
        oauth["scopes"] = scopes
    try:
        patch_creds_oauth(p, oauth)
    except CredError:
        rescue(p, at, rt, expires_at)
        raise CredError("creds write failed — the minted tokens are parked (see above)")

    print(f"claude-cred: logged in — token exchanged for a live access token (backup: {bkp})")
    if rc_id == 0:
        try:
            # save with an empty name + a known identity: matches the email to an existing
            # profile, or prompts for a new name — the "tie the name to the email" moment.
            save_profile(p, "", info)
            return
        except CredError:
            set_active(p, "")
            print(f"claude-cred: logged in as {info['email']} — profile not saved; "
                  "run: claude-cred save <name>")
    else:
        # Exchange worked but the identity lookup blipped — rare, but don't guess a name.
        set_active(p, "")
        print("claude-cred: identity lookup failed right after login — run: claude-cred save <name>")


def set_refresh_fallback(p: Paths, injected: str, bkp: Path, reason: str) -> None:
    # The old access token must not survive (it stays VALID until expiry, so leaving it
    # means CC keeps talking to the API as the OLD account) — but it must NOT be blanked
    # either: CC reads an EMPTY accessToken as "no credentials at all" and never looks at
    # the refreshToken. Non-empty + expiresAt 0 is exactly the state that sends CC down
    # its refresh branch on next launch.
    oauth = read_creds(p)["claudeAiOauth"]
    oauth.update(accessToken=PLACEHOLDER, refreshToken=injected, expiresAt=0)
    oauth.pop("refreshTokenExpiresAt", None)
    patch_creds_oauth(p, oauth)
    set_active(p, "")  # the new token belongs to an account we can't name yet

    print(f"claude-cred: refresh token injected — {reason} (backup: {bkp})")
    print("  Start Claude Code to mint a fresh access token, then: claude-cred save")


def cmd_save(args) -> int:
    p = paths()
    require_creds(p)
    save_profile(p, args.name or "", None)
    return 0


def cmd_use(args) -> int:
    p = paths()
    require_creds(p)
    name = args.name
    src = p.profiles / f"{name}.json"
    chezmoi_materialize(src)
    if not src.is_file():
        raise CredError(f"no profile '{name}' (see: claude-cred list)")
    data = load_profile(src)

    if profile_kind(data) == "setup":
        print(f"claude-cred: '{name}' is a setup-token profile — it never touches credentials.json.")
        print(f"  Launch a session with it: claude-cred run {name}")
        return 0

    oauth = profile_oauth(data)
    if not oauth.get("refreshToken"):
        raise CredError(f"profile '{name}' has no refreshToken — it may be corrupt")

    # Offline, .active is the only oracle — keep the cheap early-return but say it's
    # unverified. Online, identity decides: a stale pointer must not block a real switch.
    if offline() and get_active(p) == name:
        print(f"claude-cred: '{name}' is already active (per .active — can't verify offline)")
        return 0

    notice_running()
    outgoing = capture_outgoing(p)
    if outgoing == name:
        # The live file holds this account's NEWEST (rotated) token; splicing the
        # profile's older copy back would be a downgrade. Capture already refreshed the
        # profile from live.
        print(f"claude-cred: '{name}' is already the live account (profile refreshed from live creds)")
        set_active(p, name)
        return 0
    bkp = backup(p)

    # Exchange-at-use: verify the profile's token by USING it, before touching the live
    # login — the swap becomes transactional instead of splice-and-hope.
    res = oauth_refresh(oauth["refreshToken"])
    if res.ok:
        at, rt, expires_at, scopes = minted_fields(res.minted, oauth["refreshToken"])
        new_oauth = dict(oauth)
        new_oauth.update(accessToken=at, refreshToken=rt, expiresAt=expires_at)
        new_oauth.pop("refreshTokenExpiresAt", None)
        if scopes:
            new_oauth["scopes"] = scopes
        try:
            patch_creds_oauth(p, new_oauth)
        except CredError:
            rescue(p, at, rt, expires_at)
            raise CredError("creds write failed — the minted tokens are parked (see above)")
        # Self-heal: the rotated refresh token goes back into the profile in the same
        # step, so the profile can never go stale from a successful switch.
        atomic_write_json(src, {
            "version": 3,
            "kind": "refresh",
            "email": profile_email(data) or None,
            "accountUuid": data.get("accountUuid") or None,
            "organization": data.get("organization") or None,
            "savedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "claudeAiOauth": new_oauth,
        })
        if chezmoi_enabled():
            subprocess.run(["chezmoi", "re-add", str(src)], capture_output=True)
        set_active(p, name)
        print(f"claude-cred: switched to '{name}' — live access token minted (backup: {bkp})")
        return 0

    if res.dead:
        # A broken profile is a crisp error at switch time, never a wedged session:
        # the live login is untouched.
        raise CredError(
            f"profile '{name}' holds a dead refresh token — {res.reason}\n"
            f"  The live login is untouched. Reseed the profile: claude-cred set-refresh")

    # Transient (network/429/offline): fall back to the splice so you're not stranded.
    # A saved profile normally carries a real-but-expired accessToken, which is fine:
    # non-empty + past expiry is exactly the state that sends CC down its refresh branch.
    # But an empty one reads as "not logged in" — normalize to the placeholder.
    new_oauth = dict(oauth)
    if not new_oauth.get("accessToken"):
        new_oauth["accessToken"] = PLACEHOLDER
        new_oauth["expiresAt"] = 0
    patch_creds_oauth(p, new_oauth)
    set_active(p, name)
    print(f"claude-cred: switched to '{name}' without verifying — {res.reason} (backup: {bkp})")
    print("  Claude Code will refresh the token on next launch.")
    return 0


def cmd_add_setup_token(args) -> int:
    p = paths()
    token = args.token
    if token:
        warn_argv_token()
    elif args.generate:
        token = generate_setup_token()
    else:
        token = token_prompt("Setup token (from 'claude setup-token'): ")
        if token is None:
            raise CredError("add-setup-token needs --token when stdin is not a TTY")
    token = token.strip()
    if not token:
        raise CredError("no token given")
    if token.startswith("sk-ant-ort01-"):
        raise CredError("that's a REFRESH token (sk-ant-ort01-…) — use: claude-cred set-refresh")
    if not token.startswith("sk-ant-oat01-"):
        raise CredError("refusing — that doesn't look like a setup token (sk-ant-oat01-…).")

    # A setup token IS a bearer token, so the profile can be born with verified identity —
    # the thing refresh-token profiles can never have without consuming the token.
    rc, info = identity(token)
    if rc == 1:
        raise CredError("token rejected by the API — expired or revoked, not saving it")
    email = info["email"] if rc == 0 else ""
    if rc != 0:
        print("claude-cred: can't verify the token right now (offline/network) — saving unverified",
              file=sys.stderr)

    name = args.name or ""
    if not name:
        answer = prompt(f"save setup token ({email or 'unverified'}) as? ",
                        sanitize_name(email) if email else "")
        if answer is None or not answer:
            raise CredError("give a name: claude-cred add-setup-token <name>")
        name = answer
    validate_name(name)

    p.profiles.mkdir(mode=0o700, exist_ok=True)
    dest = p.profiles / f"{name}.json"
    overwrite_guard(dest, name, email)
    atomic_write_json(dest, {
        "version": 3,
        "kind": "setup",
        "email": email or None,
        "accountUuid": (info or {}).get("uuid") or None if rc == 0 else None,
        "organization": (info or {}).get("org") or None if rc == 0 else None,
        "savedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "setupToken": token,
    })
    # NB: no set_active — .active tracks the credentials.json login, which this isn't.
    chezmoi_roundtrip(dest, name)
    print(f"  Launch a session with it: claude-cred run {name}")
    return 0


def generate_setup_token() -> str:
    """Drive 'claude setup-token' (interactive OAuth in the browser) and capture the token
    it prints. Its own UI goes to the terminal via stderr; we only harvest stdout."""
    if not shutil.which("claude"):
        raise CredError("'claude' not found on PATH — paste the token instead")
    r = subprocess.run(["claude", "setup-token"], stdout=subprocess.PIPE, text=True)
    m = re.findall(r"sk-ant-oat01-[A-Za-z0-9_-]+", r.stdout or "")
    if r.returncode != 0 or not m:
        raise CredError("'claude setup-token' didn't produce a token")
    return m[-1]


def cmd_run(args) -> int:
    p = paths()
    name = args.name
    src = p.profiles / f"{name}.json"
    chezmoi_materialize(src)
    if not src.is_file():
        raise CredError(f"no profile '{name}' (see: claude-cred list)")
    data = load_profile(src)
    if profile_kind(data) != "setup":
        raise CredError(f"'{name}' is a refresh profile — switch to it with: claude-cred use {name}")
    token = data.get("setupToken") or ""
    if not token:
        raise CredError(f"profile '{name}' has no setupToken — it may be corrupt")

    cmd = list(args.cmdline or [])
    if cmd and cmd[0] == "--":
        cmd = cmd[1:]
    if not cmd:
        cmd = ["claude"]

    env = dict(os.environ)
    env["CLAUDE_CODE_OAUTH_TOKEN"] = token
    # A live ANTHROPIC_API_KEY in the env silently outbids the OAuth token and bills the
    # API account instead — a launcher that loses to it would be worse than none.
    env.pop("ANTHROPIC_API_KEY", None)
    print(f"claude-cred: launching with setup-token profile '{name}'"
          + (f" ({profile_email(data)})" if profile_email(data) else ""), file=sys.stderr)
    return subprocess.call(cmd, env=env)


def cmd_undo(args) -> int:
    p = paths()
    baks = sorted(p.backups.glob("*.json"), key=lambda f: f.stat().st_mtime)
    if not baks:
        raise CredError("no backups to restore")
    notice_running()
    latest = baks[-1]
    # Backups are verbatim whole-file copies (mcpOAuth included) — this is the "oh no"
    # button, so it restores byte-for-byte rather than patching.
    atomic_write(p.creds, latest.read_text())
    print(f"claude-cred: restored {latest.name}")
    print("  NOTE the active-profile pointer is unchanged; check 'claude-cred show'")
    return 0


# ── display ────────────────────────────────────────────────────────────────────────────────


def fingerprint(s: str) -> str:
    if not s:
        return "(empty)"
    if len(s) <= 20:
        return f"(len {len(s)})"
    return f"{s[:14]}…{s[-4:]} (len {len(s)})"


def when_ms(ms) -> str:
    if ms in (None, ""):
        return "(absent)"
    if ms == 0:
        return "0 — forces a refresh on next launch"
    secs = int(ms) // 1000
    when = time.strftime("%Y-%m-%d %H:%M", time.localtime(secs))
    return f"{when} (EXPIRED)" if secs < time.time() else when


def account_line(oauth: dict) -> str:
    # Skip the network in the two common can't-answer states so `show` stays instant.
    at = oauth.get("accessToken") or ""
    if not at or at == PLACEHOLDER:
        return "(pending refresh — start Claude Code, then: claude-cred save)"
    exp = oauth.get("expiresAt")
    if exp and int(exp) < time.time() * 1000:
        return "(access token expired — restart Claude Code to refresh, then retry)"
    rc, info = identity(at)
    if rc == 0:
        line = info["email"]
        if info["org"]:
            line += f" — {info['org']}"
        if info["plan"]:
            line += f" ({info['plan']})"
        return line
    return {1: "(token rejected by the API — expired or revoked)",
            2: "(network unreachable — can't verify)",
            3: "(offline mode)"}[rc]


def profile_health(data: dict) -> str:
    if profile_kind(data) == "setup":
        return "" if data.get("setupToken") else "⚠ no setupToken"
    oauth = profile_oauth(data)
    if not oauth.get("refreshToken"):
        return "⚠ no refreshToken"
    if (oauth.get("accessToken") or "") in ("", PLACEHOLDER):
        return "pending refresh"
    return ""


def cmd_show(args) -> int:
    p = paths()
    data = require_creds(p)
    oauth = data["claudeAiOauth"]
    active = get_active(p) or "(unnamed — claude-cred save <name>)"
    print(f"profile:        {active}")
    print(f"account:        {account_line(oauth)}")
    print(f"accessToken:    {fingerprint(oauth.get('accessToken') or '')}")
    print(f"refreshToken:   {fingerprint(oauth.get('refreshToken') or '')}")
    print(f"expiresAt:      {when_ms(oauth.get('expiresAt'))}")
    print(f"refreshExpires: {when_ms(oauth.get('refreshTokenExpiresAt'))}")
    print(f"subscription:   {oauth.get('subscriptionType') or ''} / {oauth.get('rateLimitTier') or ''}")
    print(f"mcpOAuth:       {len(data.get('mcpOAuth') or {})} server(s) — untouched by this tool")
    return 0


def cmd_whoami(args) -> int:
    p = paths()
    data = require_creds(p)
    rc, info = identity(data["claudeAiOauth"].get("accessToken") or "")
    if rc == 0:
        print(info["email"])
        if info["org"]:
            print(f"org:  {info['org']}")
        if info["plan"]:
            print(f"plan: {info['plan']}")
        print(f"uuid: {info['uuid']}")
        return 0
    print({1: "claude-cred: live access token rejected — expired, revoked, or a pending refresh",
           2: "claude-cred: can't reach the Anthropic API (network)",
           3: "claude-cred: offline mode — identity lookup skipped"}[rc], file=sys.stderr)
    return rc


def cmd_list(args) -> int:
    p = paths()
    active = get_active(p)
    print("profiles:")
    files = sorted(p.profiles.glob("*.json"))
    if not files:
        print("  (none — 'claude-cred save <name>' to create one)")
    for f in files:
        try:
            data = load_profile(f)
        except CredError:
            print(f"    {f.stem:<12} ⚠ unreadable")
            continue
        email = profile_email(data) or "(no identity — re-save to record it)"
        marker = "* " if f.stem == active else "  "
        health = profile_health(data)
        line = f"  {marker}{f.stem:<12} {profile_kind(data):<8} {email}"
        if health:
            line += f"  [{health}]"
        print(line)
    print("backups:")
    baks = sorted(p.backups.glob("*.json"), key=lambda f: f.stat().st_mtime, reverse=True)[:5]
    if not baks:
        print("  (none)")
    for b in baks:
        print(f"    {b.name}")
    return 0


def cmd_doctor(args) -> int:
    # Strictly READ-ONLY: doctor never writes anything, so it's always safe to run. The
    # repairs it suggests are the human's to make.
    p = paths()
    data = require_creds(p)
    now_ms = time.time() * 1000
    active = get_active(p)

    live_email = ""
    rc, info = identity(data["claudeAiOauth"].get("accessToken") or "")
    if rc == 0:
        live_email = info["email"]
    print(f"live login:  {account_line(data['claudeAiOauth'])}")

    print("profiles:")
    live_match = ""
    files = sorted(p.profiles.glob("*.json"))
    if not files:
        print("  (none)")
    for f in files:
        name = f.stem
        try:
            pdata = load_profile(f)
        except CredError as e:
            print(f"  {name}: ⚠ {e}", file=sys.stderr)
            continue
        kind = profile_kind(pdata)
        fmt = "v1" if "claudeAiOauth" not in pdata and kind == "refresh" else \
              ("v2" if pdata.get("version") == 2 else "v3")
        email = profile_email(pdata)
        saved = pdata.get("savedAt") or ""
        print(f"  {name}: {fmt} {kind}  {email or '(no identity recorded)'}"
              + (f"  saved {saved}" if saved else ""))
        mode = os.stat(f).st_mode & 0o777
        if mode != 0o600:
            print(f"    ⚠ mode {oct(mode)[2:]} (expected 600)", file=sys.stderr)

        if kind == "setup":
            token = pdata.get("setupToken") or ""
            if not token:
                print("    ⚠ no setupToken — corrupt", file=sys.stderr)
            else:
                vrc, vinfo = identity(token)
                if vrc == 0:
                    if email and vinfo["email"] != email:
                        print(f"    ⚠ token actually belongs to {vinfo['email']} — "
                              f"metadata says {email}", file=sys.stderr)
                        email = vinfo["email"]
                    else:
                        print(f"    ✓ token verified: {vinfo['email']}")
                        email = vinfo["email"]
                elif vrc == 1:
                    print("    ⚠ setup token rejected by the API — expired or revoked", file=sys.stderr)
                else:
                    print("    (can't verify right now — offline/network)")
        else:
            oauth = profile_oauth(pdata)
            if not oauth.get("refreshToken"):
                print("    ⚠ no refreshToken — corrupt or mid-write", file=sys.stderr)
            # Live verification is only possible while the profile's own access token
            # still works — a refresh token can't be checked without USING it (rotation),
            # which doctor never does.
            pat = oauth.get("accessToken") or ""
            pexp = oauth.get("expiresAt") or 0
            if pat and pat != PLACEHOLDER and pexp > now_ms:
                vrc, vinfo = identity(pat)
                if vrc == 0:
                    if email and vinfo["email"] != email:
                        print(f"    ⚠ token actually belongs to {vinfo['email']} — "
                              f"metadata says {email}", file=sys.stderr)
                    else:
                        print(f"    ✓ token verified: {vinfo['email']}")
                    email = vinfo["email"]
                else:
                    print("    (stored access token no longer verifiable)")
            else:
                print("    (access token expired — identity from metadata only)")
        if live_email and email == live_email and kind == "refresh":
            live_match = name

    if live_email:
        if not live_match:
            print(f"⚠ live login ({live_email}) is saved in NO profile — run: claude-cred save",
                  file=sys.stderr)
        else:
            print(f"live login matches profile '{live_match}'")
            if active and active != live_match:
                print(f"⚠ .active says '{active}' but the live login matches '{live_match}' "
                      "— stale pointer", file=sys.stderr)
            elif not active:
                print("note: no .active pointer — the next save/use will set it")
    else:
        print("note: live identity unavailable — structural checks only")
    return 0


# ── entry point ────────────────────────────────────────────────────────────────────────────


def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(
        prog="claude-cred",
        description="Swap the Claude Code login; email-verified age-encrypted profiles.",
        epilog="env: CLAUDE_CRED_OFFLINE=1 skips all network use (prompts instead of verifying)")
    sub = ap.add_subparsers(dest="cmd")
    sub.add_parser("show", help="active account + verified identity, redacted (default)")
    sub.add_parser("whoami", help="live account email via the Anthropic profile endpoint")
    sr = sub.add_parser("set-refresh", help="log in from a refresh token; exchanges + names the profile")
    sr.add_argument("token", nargs="?", default="")
    sv = sub.add_parser("save", help="snapshot the live login as a profile (name auto-resolved by email)")
    sv.add_argument("name", nargs="?", default="")
    us = sub.add_parser("use", help="capture the outgoing account, verify the target's token, switch")
    us.add_argument("name")
    ast = sub.add_parser("add-setup-token", help="store a long-lived setup token as a profile")
    ast.add_argument("name", nargs="?", default="")
    ast.add_argument("--token", default="", help="inline token (lands in shell history — prompt is safer)")
    ast.add_argument("--generate", action="store_true", help="run 'claude setup-token' and capture it")
    rn = sub.add_parser("run", help="launch a command (default: claude) with a setup-token profile")
    rn.add_argument("name")
    # NOT named "cmd": that dest would clobber the subparsers' own dest="cmd".
    rn.add_argument("cmdline", nargs=argparse.REMAINDER, metavar="cmd")
    sub.add_parser("list", aliases=["ls"], help="profiles with kind/email/health, and recent backups")
    sub.add_parser("doctor", help="audit profiles vs the live login — read-only")
    sub.add_parser("undo", help="restore the most recent auto-backup, verbatim")
    return ap


def main(argv=None) -> int:
    ap = build_parser()
    try:
        args = ap.parse_args(argv)
    except SystemExit as e:
        return int(e.code or 0) and 1
    dispatch = {
        None: cmd_show, "show": cmd_show, "whoami": cmd_whoami,
        "set-refresh": cmd_set_refresh, "save": cmd_save, "use": cmd_use,
        "add-setup-token": cmd_add_setup_token, "run": cmd_run,
        "list": cmd_list, "ls": cmd_list, "doctor": cmd_doctor, "undo": cmd_undo,
    }
    try:
        return dispatch[args.cmd](args)
    except CredError as e:
        print(f"claude-cred: {e}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print()
        return 130


if __name__ == "__main__":
    sys.exit(main())
