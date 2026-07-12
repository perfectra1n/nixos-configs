# commit-push "<message>" <file>... — the commit/push tail four mise tasks used to repeat verbatim
# (hardware, secrets:pull, secrets:pull-env, secrets:init).
#
# BODY ONLY: writeShellApplication (flake.nix) injects the shebang + `set -euo pipefail`, gates it
# on shellcheck at build time, and pins runtimeInputs — same treatment as gen-manifests/whatchanged.
#
# The author identity is set INLINE rather than relying on git config, because the first caller on a
# brand-new box runs before any git config exists ("Please tell me who you are" would abort the
# hardware capture). GIT_NAME / GIT_EMAIL override.
#
# Nothing to commit is SUCCESS, not failure: every caller is idempotent (re-pulling unchanged
# secrets, re-capturing identical hardware), so a no-op must exit 0 or `set -e` would kill the task.
# A failed push is also non-fatal — the commit is already safe locally; you just need creds.

msg="${1:?usage: commit-push \"<message>\" <file>...}"
shift
[ "$#" -gt 0 ] || { echo ">> commit-push: no files given" >&2; exit 2; }

git add -- "$@"

if git -c user.name="${GIT_NAME:-perfectra1n}" \
       -c user.email="${GIT_EMAIL:-jonfuller2012@gmail.com}" \
       commit -m "$msg" -- "$@"; then
  git push || echo ">> committed locally, but push failed — set up the remote/creds, then: git push"
else
  echo ">> nothing to commit (already current)"
fi
