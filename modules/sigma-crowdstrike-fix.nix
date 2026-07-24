# sigma-cli (modules/pentest.nix, graphical hosts) fails to build because one of its twelve
# python deps carries a stale nixpkgs `pname` after an upstream rename.
#
# At v3.0.0 SigmaHQ renamed the project pySigma-pipeline-crowdstrike → pySigma-backend-crowdstrike
# (it grew a Logscale BACKEND, so it's no longer just a pipeline). nixpkgs bumped the version and
# the GitHub repo/tag but kept `pname = "pysigma-pipeline-crowdstrike"`, so the wheel installs as
# pysigma_backend_crowdstrike-3.0.0.dist-info while pythonMetadataCheckPhase looks up the OLD name
# via importlib.metadata.version("$pname") — PackageNotFoundError, build dies AFTER a green
# pythonImportsCheck. Nothing to do with the python 3.14 switch, despite the timing next to
# modules/snowflake-py314-fix.nix; the giveaway is that it's a NAME lookup failing, not an import.
#
# Fixing pname (rather than setting dontCheckPythonMetadata) keeps the hook's actual job — catching
# version drift between pyproject.toml and the derivation — alive, and it's what an upstream PR
# would do. Validated on this box (x86_64-linux/py3.14, 2026-07-24): sigma-cli 3.1.0 builds and
# `sigma list pipelines` shows crowdstrike_falcon + crowdstrike_fdr.
#
# Remove this file once nixpkgs corrects the pname. If they also rename the ATTRIBUTE, eval here
# breaks loudly — that's the intended signal, not a regression.
{
  nixpkgs.overlays = [
    (final: prev: {
      pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
        (pyfinal: pyprev: {
          pysigma-pipeline-crowdstrike = pyprev.pysigma-pipeline-crowdstrike.overridePythonAttrs (_: {
            pname = "pysigma-backend-crowdstrike";
          });
        })
      ];
    })
  ];
}
