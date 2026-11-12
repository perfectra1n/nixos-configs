# gog (gogcli) — the default Google account when -a isn't given. "personal" is an alias from
# ~/.config/gogcli/config.json (the account_aliases map), so no email lands in this public file;
# pick another account per call with `gog -a business ...` / `-a personal-alt`.
# GOG_KEYRING_PASSWORD (which unlocks the file keyring) is a secret, so it lives in 00-secrets.fish instead.
set -gx GOG_ACCOUNT personal
