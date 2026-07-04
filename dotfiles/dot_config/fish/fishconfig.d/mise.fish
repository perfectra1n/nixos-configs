# mise (https://mise.jdx.dev) — runtime/tool version manager.
# Auto-sourced by fish before config.fish. No global tools are configured, so
# this stays dormant and only activates per-project when a .mise.toml /
# .tool-versions is present; pyenv & nvm still handle node/python everywhere
# else (their blocks in config.fish run after this and keep PATH precedence).
if type -q mise
    if status is-interactive
        mise activate fish | source
    else
        mise activate fish --shims | source
    end
end
