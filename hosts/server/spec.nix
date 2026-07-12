# What `server` composes, on top of the base every host gets from mkHost (flake.nix).
# A plain spec consumed by mkHost — NOT a NixOS module, so no module imports another module.
# `graphical` is accepted-but-unused: every host has one signature, so `mise run new-host`
# scaffolds a single shape.
{ inputs, graphical }:
{
  extraModules = [ ../../modules/server.nix ];
}
