"""Guarantee suite for claude_cred.py — the behavioral contract from
docs/superpowers/specs/2026-08-06-claude-cred-python-rewrite-design.md as executable law.

Zero network: the HTTP transport is a single injectable function (cc.HTTP_REQUEST) and every
test that would touch it installs a fake. Zero real credentials: CLAUDE_CRED_FILE retargets
creds + profiles + backups into a per-test tmpdir (fixture mode also forces offline and
disables the chezmoi round-trip, same as the fish version).
"""
import io
import json
import os
import stat
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import claude_cred as cc  # noqa: E402


def read_json(p):
    return json.loads(Path(p).read_text())


def mode_of(p):
    return stat.S_IMODE(os.stat(p).st_mode)


LIVE_OAUTH = {
    "accessToken": "sk-ant-oat01-LIVE-TOKEN-aaaa",
    "refreshToken": "sk-ant-ort01-LIVE-REFRESH-aaaa",
    "expiresAt": 4102444800000,  # year 2100 — "unexpired" for tests
    "scopes": ["user:inference"],
    "subscriptionType": "max",
}
# mcpOAuth must survive every write path byte-for-byte — including key order, which json.dumps
# preserves from the parsed dict, so a round-trip comparison of the parsed value is sufficient.
MCP_OAUTH = {"datadog": {"accessToken": "mcp-dd", "expiresAt": 1}, "memini": {"accessToken": "mcp-mm"}}


class Fixture(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.base = Path(self.tmp.name)
        self.creds = self.base / ".credentials.json"
        self.profiles = self.base / "cred-profiles"
        self.backups = self.base / "cred-backups"
        self.creds.write_text(json.dumps({"claudeAiOauth": dict(LIVE_OAUTH), "mcpOAuth": MCP_OAUTH}))
        os.chmod(self.creds, 0o600)
        os.environ["CLAUDE_CRED_FILE"] = str(self.creds)
        os.environ.pop("CLAUDE_CRED_ASSUME_TTY", None)
        os.environ.pop("CLAUDE_CRED_OFFLINE", None)
        self._real_http = cc.HTTP_REQUEST
        self._real_stdin = sys.stdin
        self._real_offline = cc.offline
        cc.HTTP_REQUEST = self.forbid_http  # every network touch must be deliberate

    def tearDown(self):
        cc.HTTP_REQUEST = self._real_http
        cc.offline = self._real_offline
        sys.stdin = self._real_stdin
        os.environ.pop("CLAUDE_CRED_FILE", None)
        os.environ.pop("CLAUDE_CRED_ASSUME_TTY", None)
        self.tmp.cleanup()

    def forbid_http(self, url, headers, body, timeout):
        raise AssertionError(f"unexpected HTTP call to {url}")

    def go_online(self, responder):
        """Lift the fixture-mode offline forcing and install a canned transport."""
        cc.offline = lambda: False
        cc.HTTP_REQUEST = responder

    def write_profile(self, name, data):
        self.profiles.mkdir(mode=0o700, exist_ok=True)
        p = self.profiles / f"{name}.json"
        p.write_text(json.dumps(data))
        os.chmod(p, 0o600)
        return p


class TestPaths(Fixture):
    def test_fixture_mode_retargets_everything_off_creds_dirname(self):
        p = cc.paths()
        self.assertEqual(p.creds, self.creds)
        self.assertEqual(p.profiles, self.profiles)
        self.assertEqual(p.backups, self.backups)

    def test_fixture_mode_forces_offline(self):
        self.assertTrue(cc.offline())


class TestAtomicWrite(Fixture):
    def test_refuses_invalid_json_and_leaves_dest_untouched(self):
        before = self.creds.read_bytes()
        with self.assertRaises(cc.CredError):
            cc.atomic_write(self.creds, "{not json")
        self.assertEqual(self.creds.read_bytes(), before)
        self.assertEqual([], list(self.base.glob("*.tmp.*")))  # no droppings

    def test_written_file_is_0600(self):
        dest = self.base / "out.json"
        cc.atomic_write(dest, json.dumps({"a": 1}))
        self.assertEqual(mode_of(dest), 0o600)
        self.assertEqual(read_json(dest), {"a": 1})


class TestBackup(Fixture):
    def test_backup_is_0600_copy_and_prunes_to_ten(self):
        self.backups.mkdir(mode=0o700)
        for i in range(12):
            f = self.backups / f"2026010{i % 10}T00000{i}Z.json"
            f.write_text("{}")
            os.utime(f, (i, i))
        rescue = self.backups / "rescue-x.json.rescue"
        rescue.write_text("{}")
        dest = cc.backup(cc.paths())
        self.assertEqual(mode_of(dest), 0o600)
        self.assertEqual(read_json(dest)["mcpOAuth"], MCP_OAUTH)
        remaining = sorted(self.backups.glob("*.json"))
        self.assertEqual(len(remaining), 10)  # 12 old + 1 new, pruned to 10
        self.assertIn(Path(dest), remaining)  # newest survives the prune
        self.assertTrue(rescue.exists())  # rescue files are NEVER swept


class TestProfileShapes(Fixture):
    def test_v1_bare_oauth_is_refresh_kind(self):
        data = dict(LIVE_OAUTH)
        self.assertEqual(cc.profile_kind(data), "refresh")
        self.assertEqual(cc.profile_oauth(data)["refreshToken"], LIVE_OAUTH["refreshToken"])
        self.assertEqual(cc.profile_email(data), "")

    def test_v2_wrapped_is_refresh_kind_with_email(self):
        data = {"version": 2, "email": "a@b.c", "claudeAiOauth": dict(LIVE_OAUTH)}
        self.assertEqual(cc.profile_kind(data), "refresh")
        self.assertEqual(cc.profile_email(data), "a@b.c")
        self.assertEqual(cc.profile_oauth(data)["accessToken"], LIVE_OAUTH["accessToken"])

    def test_v3_setup_kind_detected_structurally_not_by_version_field(self):
        # A lying version field must not matter: detection is structural.
        data = {"version": 99, "kind": "setup", "email": "a@b.c", "setupToken": "sk-ant-oat01-S"}
        self.assertEqual(cc.profile_kind(data), "setup")
        self.assertIsNone(cc.profile_oauth(data))

    def test_find_profiles_by_email(self):
        self.write_profile("one", {"version": 2, "email": "a@b.c", "claudeAiOauth": dict(LIVE_OAUTH)})
        self.write_profile("two", {"version": 2, "email": "x@y.z", "claudeAiOauth": dict(LIVE_OAUTH)})
        self.write_profile("bare", dict(LIVE_OAUTH))  # v1: no recorded email, never matches
        self.assertEqual(cc.find_profiles_by_email(cc.paths(), "a@b.c"), ["one"])
        self.assertEqual(cc.find_profiles_by_email(cc.paths(), ""), [])


class TestActivePointer(Fixture):
    def test_set_get_clear(self):
        p = cc.paths()
        self.assertEqual(cc.get_active(p), "")
        cc.set_active(p, "work")
        self.assertEqual(cc.get_active(p), "work")
        cc.set_active(p, "")
        self.assertEqual(cc.get_active(p), "")


class TestPrompt(Fixture):
    def test_non_tty_returns_none_immediately(self):
        sys.stdin = io.StringIO("never read\n")  # StringIO.isatty() is False
        self.assertIsNone(cc.prompt("q? ", "default"))

    def test_assume_tty_reads_line(self):
        os.environ["CLAUDE_CRED_ASSUME_TTY"] = "1"
        sys.stdin = io.StringIO("  answer  \n")
        self.assertEqual(cc.prompt("q? ", ""), "answer")

    def test_assume_tty_eof_returns_none(self):
        os.environ["CLAUDE_CRED_ASSUME_TTY"] = "1"
        sys.stdin = io.StringIO("")
        self.assertIsNone(cc.prompt("q? ", ""))


PROFILE_OK = json.dumps({
    "account": {"email": "a@b.c", "uuid": "u-1", "has_claude_max": True, "has_claude_pro": False},
    "organization": {"name": "Org"},
})
MINTED_OK = json.dumps({
    "access_token": "sk-ant-oat01-FRESH",
    "refresh_token": "sk-ant-ort01-ROTATED",
    "expires_in": 3600,
    "scope": "user:inference user:profile",
})


class TestIdentity(Fixture):
    def test_offline_is_rc3_without_any_http(self):
        rc, info = cc.identity("sk-ant-oat01-x")
        self.assertEqual(rc, 3)

    def test_placeholder_and_empty_are_rc1_without_any_http(self):
        cc.offline = lambda: False  # online, but the transport still forbids calls
        self.assertEqual(cc.identity(cc.PLACEHOLDER)[0], 1)
        self.assertEqual(cc.identity("")[0], 1)

    def test_ok_parses_email_uuid_org_plan_and_sends_bearer(self):
        seen = {}

        def responder(url, headers, body, timeout):
            seen.update(url=url, headers=headers, body=body)
            return 200, PROFILE_OK
        self.go_online(responder)
        rc, info = cc.identity("sk-ant-oat01-x")
        self.assertEqual(rc, 0)
        self.assertEqual(info, {"email": "a@b.c", "uuid": "u-1", "org": "Org", "plan": "max"})
        self.assertEqual(seen["url"], cc.PROFILE_URL)
        self.assertEqual(seen["headers"]["Authorization"], "Bearer sk-ant-oat01-x")
        self.assertEqual(seen["headers"]["anthropic-beta"], cc.OAUTH_BETA)

    def test_http_4xx_is_rc1_rejected(self):
        self.go_online(lambda *a: (401, "{}"))
        self.assertEqual(cc.identity("sk-ant-oat01-x")[0], 1)

    def test_network_error_is_rc2(self):
        def responder(*a):
            raise cc.NetworkError("unreachable")
        self.go_online(responder)
        self.assertEqual(cc.identity("sk-ant-oat01-x")[0], 2)


class TestOauthRefresh(Fixture):
    def test_offline_skips_exchange(self):
        res = cc.oauth_refresh("sk-ant-ort01-x")
        self.assertFalse(res.ok)
        self.assertFalse(res.dead)
        self.assertIn("offline", res.reason)

    def test_success_posts_grant_and_returns_minted(self):
        seen = {}

        def responder(url, headers, body, timeout):
            seen.update(url=url, headers=headers, body=body)
            return 200, MINTED_OK
        self.go_online(responder)
        res = cc.oauth_refresh("sk-ant-ort01-x")
        self.assertTrue(res.ok)
        self.assertEqual(res.minted["access_token"], "sk-ant-oat01-FRESH")
        self.assertEqual(seen["url"], cc.TOKEN_URL)
        sent = json.loads(seen["body"])
        self.assertEqual(sent, {"grant_type": "refresh_token",
                                "refresh_token": "sk-ant-ort01-x",
                                "client_id": cc.CLIENT_ID})
        self.assertEqual(seen["headers"]["Content-Type"], "application/json")

    def test_200_without_usable_fields_is_failure_never_partial(self):
        # Guarantee 14: a 200 missing access_token/expires_in must never yield ok.
        self.go_online(lambda *a: (200, json.dumps({"access_token": "", "expires_in": 0})))
        res = cc.oauth_refresh("sk-ant-ort01-x")
        self.assertFalse(res.ok)
        self.assertFalse(res.dead)
        self.assertIn("no usable tokens", res.reason)

    def test_429_is_transient_not_dead(self):
        self.go_online(lambda *a: (429, "{}"))
        res = cc.oauth_refresh("sk-ant-ort01-x")
        self.assertFalse(res.ok)
        self.assertFalse(res.dead)
        self.assertIn("rate limited", res.reason)

    def test_400_invalid_grant_is_dead(self):
        self.go_online(lambda *a: (400, json.dumps({"error": {"type": "invalid_grant"}})))
        res = cc.oauth_refresh("sk-ant-ort01-x")
        self.assertFalse(res.ok)
        self.assertTrue(res.dead)
        self.assertIn("invalid_grant", res.reason)
        self.assertIn("dead", res.reason)

    def test_network_error_is_transient(self):
        def responder(*a):
            raise cc.NetworkError("unreachable")
        self.go_online(responder)
        res = cc.oauth_refresh("sk-ant-ort01-x")
        self.assertFalse(res.ok)
        self.assertFalse(res.dead)
        self.assertIn("unreachable", res.reason)


def identity_body(email, uuid="u-x", org="Org", max_plan=True):
    return json.dumps({
        "account": {"email": email, "uuid": uuid, "has_claude_max": max_plan,
                    "has_claude_pro": False},
        "organization": {"name": org},
    })


class CommandFixture(Fixture):
    """Adds main()-level helpers: captured stdout/stderr, piped prompt answers, an HTTP
    router keyed by endpoint + bearer token."""

    def run_cmd(self, argv, stdin_lines=None):
        from contextlib import redirect_stdout, redirect_stderr
        if stdin_lines is not None:
            os.environ["CLAUDE_CRED_ASSUME_TTY"] = "1"
            sys.stdin = io.StringIO("".join(line + "\n" for line in stdin_lines))
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            rc = cc.main(argv)
        return rc, out.getvalue(), err.getvalue()

    def router(self, tokens_to_identity, exchange=(200, MINTED_OK)):
        """profile endpoint: bearer → identity body (unknown → 401). token endpoint: canned."""
        def responder(url, headers, body, timeout):
            if url == cc.PROFILE_URL:
                tok = headers["Authorization"].split()[-1]
                if tok in tokens_to_identity:
                    return 200, tokens_to_identity[tok]
                return 401, "{}"
            if url == cc.TOKEN_URL:
                return exchange
            raise AssertionError(f"unexpected url {url}")
        return responder


class TestSetRefreshGuards(CommandFixture):
    def test_rejects_access_or_setup_token_with_hint_before_any_side_effect(self):
        rc, out, err = self.run_cmd(["set-refresh", "sk-ant-oat01-NOT-A-REFRESH"])
        self.assertEqual(rc, 1)
        self.assertIn("add-setup-token", err)
        self.assertFalse(self.backups.exists())  # no side effects before the guard

    def test_rejects_garbage_token(self):
        rc, out, err = self.run_cmd(["set-refresh", "hunter2"])
        self.assertEqual(rc, 1)
        self.assertIn("sk-ant-ort01", err)

    def test_non_tty_without_arg_errors_instead_of_hanging(self):
        sys.stdin = io.StringIO("")
        rc, out, err = self.run_cmd(["set-refresh"])
        self.assertEqual(rc, 1)
        self.assertIn("token argument", err)


class TestSetRefreshOnline(CommandFixture):
    def setUp(self):
        super().setUp()
        # Live login is alice, already saved in a matching profile → capture is silent.
        self.write_profile("alice", {"version": 2, "email": "alice@x",
                                     "claudeAiOauth": dict(LIVE_OAUTH)})
        self.go_online(self.router({
            LIVE_OAUTH["accessToken"]: identity_body("alice@x"),
            "sk-ant-oat01-FRESH": identity_body("bob@y", uuid="u-bob"),
        }))

    def test_success_writes_live_tokens_saves_profiles_preserves_mcp(self):
        rc, out, err = self.run_cmd(["set-refresh", "sk-ant-ort01-INJECTED"],
                                    stdin_lines=["bob"])  # name prompt for the new identity
        self.assertEqual(rc, 0)
        creds = read_json(self.creds)
        oauth = creds["claudeAiOauth"]
        self.assertEqual(oauth["accessToken"], "sk-ant-oat01-FRESH")
        self.assertEqual(oauth["refreshToken"], "sk-ant-ort01-ROTATED")  # rotated one wins
        self.assertNotIn("refreshTokenExpiresAt", oauth)  # old account's clock
        self.assertGreater(oauth["expiresAt"], 4102444800000 % 10**13 and 10**12)
        self.assertEqual(creds["mcpOAuth"], MCP_OAUTH)  # guarantee 1
        # Outgoing alice captured (rotation!) and new bob profile born verified.
        alice = read_json(self.profiles / "alice.json")
        self.assertEqual(cc.profile_oauth(alice)["refreshToken"], LIVE_OAUTH["refreshToken"])
        bob = read_json(self.profiles / "bob.json")
        self.assertEqual(bob["email"], "bob@y")
        self.assertEqual(cc.profile_oauth(bob)["refreshToken"], "sk-ant-ort01-ROTATED")
        self.assertEqual(cc.get_active(cc.paths()), "bob")

    def test_exchange_omitting_refresh_token_keeps_injected_one(self):
        # Guarantee 13: OAuth allows omitting refresh_token ("old one still valid").
        minted = json.dumps({"access_token": "sk-ant-oat01-FRESH", "expires_in": 3600})
        cc.HTTP_REQUEST = self.router(
            {LIVE_OAUTH["accessToken"]: identity_body("alice@x"),
             "sk-ant-oat01-FRESH": identity_body("bob@y")},
            exchange=(200, minted))
        rc, out, err = self.run_cmd(["set-refresh", "sk-ant-ort01-INJECTED"],
                                    stdin_lines=["bob"])
        self.assertEqual(rc, 0)
        self.assertEqual(read_json(self.creds)["claudeAiOauth"]["refreshToken"],
                         "sk-ant-ort01-INJECTED")

    def test_dead_or_transient_exchange_falls_back_to_placeholder(self):
        cc.HTTP_REQUEST = self.router(
            {LIVE_OAUTH["accessToken"]: identity_body("alice@x")},
            exchange=(429, "{}"))
        rc, out, err = self.run_cmd(["set-refresh", "sk-ant-ort01-INJECTED"])
        self.assertEqual(rc, 0)
        oauth = read_json(self.creds)["claudeAiOauth"]
        self.assertEqual(oauth["accessToken"], cc.PLACEHOLDER)  # guarantee 2
        self.assertEqual(oauth["expiresAt"], 0)
        self.assertEqual(oauth["refreshToken"], "sk-ant-ort01-INJECTED")
        self.assertNotIn("refreshTokenExpiresAt", oauth)
        self.assertEqual(read_json(self.creds)["mcpOAuth"], MCP_OAUTH)
        self.assertIn("rate limited", out + err)
        self.assertEqual(cc.get_active(cc.paths()), "")  # unknown account: no active


class TestSaveGuards(CommandFixture):
    def test_overwrite_guard_refuses_non_interactively(self):
        # Guarantee 6: profile records carol, live login is alice, no TTY → refuse.
        self.write_profile("work", {"version": 2, "email": "carol@z",
                                    "claudeAiOauth": {"refreshToken": "sk-ant-ort01-C"}})
        self.go_online(self.router({LIVE_OAUTH["accessToken"]: identity_body("alice@x")}))
        before = (self.profiles / "work.json").read_bytes()
        sys.stdin = io.StringIO("")
        rc, out, err = self.run_cmd(["save", "work"])
        self.assertEqual(rc, 1)
        self.assertIn("refusing", err)
        self.assertEqual((self.profiles / "work.json").read_bytes(), before)

    def test_offline_resave_keeps_recorded_identity(self):
        # Guarantee 7: identity is sticky — offline re-save must not destroy the owner.
        self.write_profile("work", {"version": 2, "email": "carol@z", "accountUuid": "u-c",
                                    "organization": "OrgC",
                                    "claudeAiOauth": {"refreshToken": "sk-ant-ort01-C"}})
        rc, out, err = self.run_cmd(["save", "work"])  # fixture mode = offline
        self.assertEqual(rc, 0)
        data = read_json(self.profiles / "work.json")
        self.assertEqual(data["email"], "carol@z")
        self.assertEqual(data["accountUuid"], "u-c")
        self.assertEqual(data["organization"], "OrgC")
        self.assertEqual(data["kind"], "refresh")
        self.assertEqual(cc.profile_oauth(data)["accessToken"], LIVE_OAUTH["accessToken"])

    def test_non_tty_save_without_name_errors(self):
        sys.stdin = io.StringIO("")
        rc, out, err = self.run_cmd(["save"])
        self.assertEqual(rc, 1)
        self.assertIn("save <name>", err)

    def test_invalid_profile_name_rejected(self):
        rc, out, err = self.run_cmd(["save", "../evil"])
        self.assertEqual(rc, 1)
        self.assertIn("invalid profile name", err)


class TestUse(CommandFixture):
    def bob_profile(self, access="sk-ant-oat01-OLD-bob"):
        oauth = {"accessToken": access, "refreshToken": "sk-ant-ort01-BOB",
                 "expiresAt": 1, "subscriptionType": "pro"}
        return self.write_profile("bob", {"version": 3, "kind": "refresh", "email": "bob@y",
                                          "claudeAiOauth": oauth})

    def test_dead_token_aborts_and_leaves_creds_byte_identical(self):
        # Guarantee 4 (abort): the heart of exchange-at-use.
        self.bob_profile()
        self.go_online(self.router(
            {LIVE_OAUTH["accessToken"]: identity_body("alice@x")},
            exchange=(400, json.dumps({"error": {"type": "invalid_grant"}}))))
        self.write_profile("alice", {"version": 2, "email": "alice@x",
                                     "claudeAiOauth": dict(LIVE_OAUTH)})
        before = self.creds.read_bytes()
        rc, out, err = self.run_cmd(["use", "bob"])
        self.assertEqual(rc, 1)
        self.assertEqual(self.creds.read_bytes(), before)
        self.assertIn("reseed", err)

    def test_success_writes_live_tokens_and_heals_profile(self):
        # Guarantee 4 (success): rotated refresh token lands in BOTH creds and profile.
        self.bob_profile()
        self.write_profile("alice", {"version": 2, "email": "alice@x",
                                     "claudeAiOauth": dict(LIVE_OAUTH)})
        self.go_online(self.router({LIVE_OAUTH["accessToken"]: identity_body("alice@x")}))
        rc, out, err = self.run_cmd(["use", "bob"])
        self.assertEqual(rc, 0)
        creds = read_json(self.creds)
        oauth = creds["claudeAiOauth"]
        self.assertEqual(oauth["accessToken"], "sk-ant-oat01-FRESH")
        self.assertEqual(oauth["refreshToken"], "sk-ant-ort01-ROTATED")
        self.assertEqual(oauth["subscriptionType"], "pro")  # bob's own, from his profile
        self.assertEqual(creds["mcpOAuth"], MCP_OAUTH)
        bob = read_json(self.profiles / "bob.json")
        self.assertEqual(cc.profile_oauth(bob)["refreshToken"], "sk-ant-ort01-ROTATED")
        self.assertEqual(cc.get_active(cc.paths()), "bob")

    def test_transient_failure_splices_profile_verbatim(self):
        self.bob_profile()
        self.write_profile("alice", {"version": 2, "email": "alice@x",
                                     "claudeAiOauth": dict(LIVE_OAUTH)})

        def responder(url, headers, body, timeout):
            if url == cc.PROFILE_URL:
                return 200, identity_body("alice@x")
            raise cc.NetworkError("unreachable")
        self.go_online(responder)
        rc, out, err = self.run_cmd(["use", "bob"])
        self.assertEqual(rc, 0)
        oauth = read_json(self.creds)["claudeAiOauth"]
        self.assertEqual(oauth["accessToken"], "sk-ant-oat01-OLD-bob")  # stale-but-real is fine
        self.assertEqual(oauth["refreshToken"], "sk-ant-ort01-BOB")
        self.assertIn("unreachable", out + err)
        self.assertEqual(cc.get_active(cc.paths()), "bob")

    def test_offline_splice_normalizes_empty_access_token_to_placeholder(self):
        # Guarantee 2: an empty accessToken reads as "not logged in" to CC — never write one.
        self.bob_profile(access="")
        rc, out, err = self.run_cmd(["use", "bob"], stdin_lines=[""])  # decline outgoing save
        self.assertEqual(rc, 0)
        oauth = read_json(self.creds)["claudeAiOauth"]
        self.assertEqual(oauth["accessToken"], cc.PLACEHOLDER)
        self.assertEqual(oauth["expiresAt"], 0)

    def test_use_on_setup_profile_never_touches_creds(self):
        self.write_profile("ci", {"version": 3, "kind": "setup", "email": "ci@x",
                                  "setupToken": "sk-ant-oat01-SETUP"})
        before = self.creds.read_bytes()
        rc, out, err = self.run_cmd(["use", "ci"])
        self.assertEqual(rc, 0)
        self.assertEqual(self.creds.read_bytes(), before)
        self.assertIn("claude-cred run ci", out)

    def test_missing_profile_errors_with_list_hint(self):
        rc, out, err = self.run_cmd(["use", "nope"])
        self.assertEqual(rc, 1)
        self.assertIn("list", err)

    def test_profile_without_refresh_token_is_corrupt(self):
        self.write_profile("bad", {"version": 3, "kind": "refresh",
                                   "claudeAiOauth": {"accessToken": "x"}})
        rc, out, err = self.run_cmd(["use", "bad"])
        self.assertEqual(rc, 1)
        self.assertIn("corrupt", err)

    def test_switching_to_the_live_account_short_circuits(self):
        self.write_profile("alice", {"version": 2, "email": "alice@x",
                                     "claudeAiOauth": {"refreshToken": "sk-ant-ort01-STALE"}})
        self.go_online(self.router({LIVE_OAUTH["accessToken"]: identity_body("alice@x")}))
        before = self.creds.read_bytes()
        rc, out, err = self.run_cmd(["use", "alice"])
        self.assertEqual(rc, 0)
        self.assertEqual(self.creds.read_bytes(), before)  # live file already newest
        # ...but the profile got refreshed from live (rotation capture).
        alice = read_json(self.profiles / "alice.json")
        self.assertEqual(cc.profile_oauth(alice)["refreshToken"], LIVE_OAUTH["refreshToken"])


class TestAddSetupToken(CommandFixture):
    def test_rejects_refresh_token_with_set_refresh_hint(self):
        rc, out, err = self.run_cmd(["add-setup-token", "ci", "--token", "sk-ant-ort01-R"])
        self.assertEqual(rc, 1)
        self.assertIn("set-refresh", err)

    def test_rejects_garbage(self):
        rc, out, err = self.run_cmd(["add-setup-token", "ci", "--token", "hunter2"])
        self.assertEqual(rc, 1)

    def test_online_token_is_verified_and_profile_born_with_identity(self):
        self.go_online(self.router({"sk-ant-oat01-SETUP": identity_body("carol@z", uuid="u-c")}))
        rc, out, err = self.run_cmd(["add-setup-token", "ci", "--token", "sk-ant-oat01-SETUP"])
        self.assertEqual(rc, 0)
        data = read_json(self.profiles / "ci.json")
        self.assertEqual(data["kind"], "setup")
        self.assertEqual(data["email"], "carol@z")
        self.assertEqual(data["setupToken"], "sk-ant-oat01-SETUP")
        self.assertEqual(mode_of(self.profiles / "ci.json"), 0o600)

    def test_online_rejected_token_is_an_error_not_a_profile(self):
        self.go_online(self.router({}))  # 401 for everything
        rc, out, err = self.run_cmd(["add-setup-token", "ci", "--token", "sk-ant-oat01-DEAD"])
        self.assertEqual(rc, 1)
        self.assertFalse((self.profiles / "ci.json").exists())

    def test_offline_saves_unverified_with_warning(self):
        rc, out, err = self.run_cmd(["add-setup-token", "ci", "--token", "sk-ant-oat01-SETUP"])
        self.assertEqual(rc, 0)
        self.assertIn("unverified", out + err)
        self.assertIsNone(read_json(self.profiles / "ci.json")["email"])

    def test_inline_token_warns_about_shell_history(self):
        rc, out, err = self.run_cmd(["add-setup-token", "ci", "--token", "sk-ant-oat01-SETUP"])
        self.assertIn("history", err)


class TestRun(CommandFixture):
    def test_child_gets_setup_token_and_loses_api_key(self):
        # Guarantee 12: ANTHROPIC_API_KEY hijacks CC auth — the launcher must strip it.
        self.write_profile("ci", {"version": 3, "kind": "setup", "email": "ci@x",
                                  "setupToken": "sk-ant-oat01-SETUP"})
        os.environ["ANTHROPIC_API_KEY"] = "sk-ant-api-SHOULD-NOT-LEAK"
        try:
            dump = self.base / "env.json"
            rc, out, err = self.run_cmd([
                "run", "ci", "--", sys.executable, "-c",
                "import json,os,sys;json.dump({k:os.environ.get(k) for k in "
                "['CLAUDE_CODE_OAUTH_TOKEN','ANTHROPIC_API_KEY']},"
                f"open({str(dump)!r},'w'))",
            ])
            self.assertEqual(rc, 0)
            env = read_json(dump)
            self.assertEqual(env["CLAUDE_CODE_OAUTH_TOKEN"], "sk-ant-oat01-SETUP")
            self.assertIsNone(env["ANTHROPIC_API_KEY"])
        finally:
            os.environ.pop("ANTHROPIC_API_KEY", None)

    def test_run_on_refresh_profile_points_at_use(self):
        self.write_profile("bob", {"version": 2, "email": "bob@y",
                                   "claudeAiOauth": {"refreshToken": "sk-ant-ort01-B"}})
        rc, out, err = self.run_cmd(["run", "bob"])
        self.assertEqual(rc, 1)
        self.assertIn("use", err)


class TestUndo(CommandFixture):
    def test_restores_newest_backup_verbatim(self):
        self.backups.mkdir(mode=0o700)
        older = self.backups / "20260101T000000Z.json"
        older.write_text(json.dumps({"claudeAiOauth": {"accessToken": "old"}}))
        os.utime(older, (1, 1))
        newest_text = json.dumps({"claudeAiOauth": {"accessToken": "newer"},
                                  "mcpOAuth": {"other": {"t": 1}}})
        newest = self.backups / "20260201T000000Z.json"
        newest.write_text(newest_text)
        rc, out, err = self.run_cmd(["undo"])
        self.assertEqual(rc, 0)
        self.assertEqual(self.creds.read_text(), newest_text)  # verbatim, mcpOAuth included

    def test_no_backups_is_an_error(self):
        rc, out, err = self.run_cmd(["undo"])
        self.assertEqual(rc, 1)


class TestDisplay(CommandFixture):
    def test_list_shows_kind_email_active_marker(self):
        self.write_profile("alice", {"version": 2, "email": "alice@x",
                                     "claudeAiOauth": dict(LIVE_OAUTH)})
        self.write_profile("ci", {"version": 3, "kind": "setup", "email": "ci@x",
                                  "setupToken": "sk-ant-oat01-S"})
        cc.set_active(cc.paths(), "alice")
        rc, out, err = self.run_cmd(["list"])
        self.assertEqual(rc, 0)
        self.assertIn("alice", out)
        self.assertIn("alice@x", out)
        self.assertIn("setup", out)
        self.assertIn("* alice", out)  # active marker

    def test_show_names_pending_refresh_state(self):
        data = read_json(self.creds)
        data["claudeAiOauth"]["accessToken"] = cc.PLACEHOLDER
        data["claudeAiOauth"]["expiresAt"] = 0
        self.creds.write_text(json.dumps(data))
        rc, out, err = self.run_cmd(["show"])
        self.assertEqual(rc, 0)
        self.assertIn("pending refresh", out)
        self.assertIn("untouched", out)  # the mcpOAuth line

    def test_doctor_is_read_only(self):
        self.write_profile("alice", {"version": 2, "email": "alice@x",
                                     "claudeAiOauth": dict(LIVE_OAUTH)})
        before_creds = self.creds.read_bytes()
        before_profile = (self.profiles / "alice.json").read_bytes()
        rc, out, err = self.run_cmd(["doctor"])
        self.assertEqual(rc, 0)
        self.assertEqual(self.creds.read_bytes(), before_creds)
        self.assertEqual((self.profiles / "alice.json").read_bytes(), before_profile)
        self.assertIn("alice", out)

    def test_creds_missing_is_a_clear_error(self):
        self.creds.unlink()
        rc, out, err = self.run_cmd(["show"])
        self.assertEqual(rc, 1)
        self.assertIn("log in first", err)


if __name__ == "__main__":
    unittest.main()
