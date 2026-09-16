# claude-edge defaults. The tool itself is autoloaded (functions/claude-edge.fish + __ce_*.fish,
# completions/claude-edge.fish) so its ~500 lines cost nothing at startup — but the helpers read
# these vars directly, and a Tab on `claude-edge use` calls __ce_installed_versions before
# `claude-edge` has ever run, so the vars themselves must exist eagerly. To override, export
# CLAUDE_EDGE_DIR / CLAUDE_EDGE_BIN before the shell starts (config.fish is too late: conf.d runs first).
set -q CLAUDE_EDGE_DIR; or set -g CLAUDE_EDGE_DIR "$HOME/.claude-edge"
set -q CLAUDE_EDGE_BIN; or set -g CLAUDE_EDGE_BIN "$HOME/.local/bin/claude-edge"

set -g __CE_GCS "https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases"
