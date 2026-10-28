{ config, pkgs, lib, ... }:

# Playwright + Chromium for a HEADLESS host (kanbot-1): its Claude Code sessions drive a browser —
# e2e tests, screenshots, scraping — the same way a session on the desktop does. The desktop gets
# its Playwright from modules/desktop-apps.nix, but that module is the GUI app set; this is the
# headless subset, kept as its own concern so a server can opt in without Slack and Steam.
#
# System-level, not home-manager, on purpose: kanbot sessions run under the runner's USER unit, whose
# PATH is forced to include /run/current-system/sw/bin (modules/kanbot-runner.nix), and they pick up
# environment.sessionVariables through the login shell each session's tmux pane starts — the same
# route rust-build-cache.nix's SCCACHE_* variables take.
let
  # `playwright install` downloads FHS binaries that don't start on NixOS. These are nixpkgs-built
  # at the revisions playwright-driver pins, and Playwright refuses a browser whose revision isn't
  # its own — so they only match the nixpkgs `playwright` (same rev). A repo that pins a DIFFERENT
  # @playwright/test in its package.json will still look for its own revision and fail to launch.
  browsers = pkgs.playwright-driver.browsers;
in
{
  environment.systemPackages = with pkgs; [
    playwright-test # the `playwright` CLI (test, codegen, screenshot) + @playwright/test, wrapped to find `browsers`
    chromium        # plain Chromium for scripts that just want `chromium --headless` (e.g. fish md2pdf)
  ];

  environment.sessionVariables = {
    PLAYWRIGHT_BROWSERS_PATH = "${browsers}";
    PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD = "1";
    PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS = "true";
  };

  # @playwright/mcp (the Claude Code plugin) defaults to the `chrome` channel, which ignores
  # PLAYWRIGHT_BROWSERS_PATH and hardcodes Chrome's FHS path /opt/google/chrome/chrome. Same shim
  # as modules/desktop-apps.nix, but onto Chromium — this box carries no Google Chrome.
  systemd.tmpfiles.rules = [
    "d /opt/google 0755 root root - -"
    "d /opt/google/chrome 0755 root root - -"
    "L+ /opt/google/chrome/chrome - - - - ${pkgs.chromium}/bin/chromium"
  ];

  # A headless install has no fonts, so every page renders and screenshots as tofu boxes.
  fonts.enableDefaultPackages = true;
}
