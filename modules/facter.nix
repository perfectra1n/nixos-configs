{ config, lib, inputs, hostName, ... }:

# Hardware detection via nixos-facter (m00n-inspired, on nixpkgs' built-in module).
#
# A per-host facter.json (generated on the machine with `sudo nixos-facter -o
# hosts/<host>/facter.json`) is a rich, accurate hardware report. nixpkgs' built-in
# `hardware.facter` module parses it into `config.hardware.facter.report` (the
# standalone nixos-facter-modules flake was upstreamed into nixpkgs). This module:
#   1. points facter at hosts/<host>/facter.json IF that file exists, so a fresh
#      checkout WITHOUT a report still evaluates (CI stays green); and
#   2. exposes convenience flags under `config.detected.*` derived from the report,
#      so other modules can auto-enable bits instead of hardcoding per host. Example:
#        services.foo.enable = lib.mkIf config.detected.nvidia true;
#
# NOTE: facter does NOT detect disk/partition layout — declare fileSystems +
# boot.loader in hosts/<host>/{default.nix,hardware-configuration.nix} as usual.

let
  reportPath = "${inputs.self}/hosts/${hostName}/facter.json";
  reportExists = builtins.pathExists reportPath;
  report = if reportExists then config.hardware.facter.report else { };

  has = path: attrs: lib.hasAttrByPath path attrs;
  graphicsCards = if has [ "hardware" "graphics_card" ] report then report.hardware.graphics_card else [ ];
  networkIfaces = if has [ "hardware" "network_interface" ] report then report.hardware.network_interface else [ ];
  formFactor = if has [ "hardware" "system" "form_factor" ] report then report.hardware.system.form_factor else null;

  gpuHasDriver = drv: builtins.any (gpu: (gpu ? driver) && gpu.driver == drv) graphicsCards;
in
{
  options.detected = {
    isLaptop = lib.mkOption {
      type = lib.types.bool;
      default = formFactor == "laptop";
      description = "Whether facter detected a laptop form factor.";
    };
    isDesktop = lib.mkOption {
      type = lib.types.bool;
      default = formFactor == "desktop";
      description = "Whether facter detected a desktop form factor.";
    };
    nvidia = lib.mkOption {
      type = lib.types.bool;
      default = gpuHasDriver "nvidia";
      description = "Whether facter detected an NVIDIA GPU.";
    };
    amd = lib.mkOption {
      type = lib.types.bool;
      default = gpuHasDriver "amdgpu";
      description = "Whether facter detected an AMD GPU.";
    };
    wireless = lib.mkOption {
      type = lib.types.bool;
      # 0x000a = wireless network controller sub_class
      default = builtins.any
        (iface: (iface ? sub_class) && (iface.sub_class ? hex) && iface.sub_class.hex == "000a")
        networkIfaces;
      description = "Whether facter detected a wireless network interface.";
    };
  };

  config = {
    # Only set the report path when the file is actually present, so a clean
    # checkout (no facter.json yet) still evaluates.
    hardware.facter.reportPath = lib.mkIf reportExists reportPath;
  };
}
