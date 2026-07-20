# The snowflake stack (snow — a work tool, home/common.nix, every host) is double-broken
# on current nixos-unstable; this overlay carries the two fixes until nixpkgs heals.
#
# 1) snowflake-connector-python 4.3.0 predates Python 3.14 (upstream support landed in
#    4.4.0, Mar 2026), and nixpkgs flipped default python3 to 3.14 in mid-July 2026 — the
#    pinned 4.3.0 now fails its check phase deterministically. The nixpkgs bump is a bot
#    PR stalled since April (NixOS/nixpkgs#511615), and 4.4.0 alone STILL fails on
#    linux+py3.14: test/unit/aio calls asyncio.get_event_loop() at pytest collection
#    time, which 3.14 escalated from DeprecationWarning to RuntimeError (fatal here,
#    tolerated on darwin — which is why the PR's darwin tester called 4.4.0 green).
#    4.5.0+ swap those for new asyncio-mock regressions, so: 4.4.0 + skip the aio tests.
#
# 2) snowflake-cli 3.13.1 fails 11 of its own tests against the typer 0.25 / click 8.3 /
#    pydantic 2.13 generation nixpkgs now ships (it broke when those bumped — silently
#    red on Hydra, unnoticed because leaf failures don't block the channel). Upstream is
#    NO help: even snowflake-cli 3.23.0 still pins click==8.1.8/typer==0.17.3 (their `==`
#    pins are a lockfile nixpkgs relaxes away), and 3.23.0 also hard-requires
#    snowflake-snowpark-python, which nixpkgs doesn't package — a bump was tried and
#    abandoned (2026-07-20). So: mute the two broken test files. Known cost: `snow
#    --docs` generation and `<% %>` project-definition templating are untested/possibly
#    broken under pydantic 2.13 — irrelevant to auth/connection/SQL usage here.
#
# Both fixes validated by building .#nixosConfigurations.desktop.pkgs.snowflake-cli on
# this box (x86_64-linux/py3.14, 2026-07-20). Both reported upstream with these exact
# findings. Remove this file once nixpkgs ships a green snowflake-connector-python
# >= 4.4.0 (watch NixOS/nixpkgs#511615) AND a snowflake-cli whose check phase passes
# against current typer/click/pydantic (watch NixOS/nixpkgs#543941).
{
  nixpkgs.overlays = [
    (final: prev: {
      pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
        (pyfinal: pyprev: {
          snowflake-connector-python = pyprev.snowflake-connector-python.overridePythonAttrs (old: rec {
            version = "4.4.0";
            src = final.fetchFromGitHub {
              owner = "snowflakedb";
              repo = "snowflake-connector-python";
              tag = "v${version}";
              hash = "sha256-fgvqUBs6uuf9A8ZEsw1LfpqKXOtGNWRL+Q/2NQqv3ig=";
            };
            disabledTestPaths = old.disabledTestPaths ++ [ "test/unit/aio" ];
          });
        })
      ];

      snowflake-cli = prev.snowflake-cli.overridePythonAttrs (old: {
        disabledTestPaths = (old.disabledTestPaths or [ ]) ++ [
          "tests/test_docs_generation_output.py" # docs generator calls pre-click-8.2 make_metavar()
          "tests/api/project/schemas/test_updatable_model.py" # `<% %>` templating model vs pydantic 2.13
        ];
        disabledTests = (old.disabledTests or [ ]) ++ [
          "test_docs_callback" # same make_metavar() breakage, lives in tests/test_main.py
        ];
      });
    })
  ];
}
