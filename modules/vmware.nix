{ lib, ... }:

# VMware Workstation host. unfree. Builds vmmon/vmnet against the running kernel (CachyOS on
# both graphical hosts) and provides `vmware` + the networking/USB-arbitrator services.
#
# A module rather than a line in each host's default.nix because desktop AND laptop run it,
# and it is never wanted without its partner vmware-net.nix — list the two together in a
# host's spec.nix. The USB arbitrator is the reason the laptop has it: it hands a USB device
# (the Canon R40 scanner, which SANE's canon_dr doesn't know) straight to a Windows guest so
# the vendor driver runs it.
{
  virtualisation.vmware.host.enable = true;

  # Sign vmmon/vmnet ourselves. nixpkgs (NixOS/nixpkgs#571181) now signs every module with
  # the deterministic `kmodigest` during kbuild's modules_install, and the module aggregator
  # concatenates each external module's `<mod>.ko.cer` into modules.cer — `cat`ting a missing
  # one fails the whole system build ("cat: misc/vmmon.ko.cer: No such file or directory").
  # vmware-modules installs via its own Makefile copy, so it ships unsigned and cert-less.
  # It reached us through chaotic: the CachyOS kernel set is built from CHAOTIC's nixpkgs pin,
  # which is why this extends that set rather than overlaying our pkgs.linuxPackages.
  # postFixup, not postInstall: stdenv's strip runs in fixup and rewriting the ELF drops an
  # appended signature (kbuild strips first, then signs — same order here). kmodigest comes
  # from the kernel set's own nixpkgs so it matches the tool that signed the kernel's modules.
  # mkAfter so this overlay runs after chaotic's, which defines linuxPackages_cachyos-gcc.
  # DROP once NixOS/nixpkgs#578004 (kernelModuleInstallHook, converts vmware-modules) lands
  # in chaotic's pin — check `tail -c 28` of vmmon.ko for "~Module signature appended~".
  nixpkgs.overlays = lib.mkAfter [
    (final: prev: {
      linuxPackages_cachyos-gcc = prev.linuxPackages_cachyos-gcc.extend (kfinal: kprev: {
        vmware = kprev.vmware.overrideAttrs (old: {
          nativeBuildInputs = (old.nativeBuildInputs or [ ])
            ++ [ (kprev.callPackage ({ kmodigest }: kmodigest) { }) ];
          postFixup = (old.postFixup or "") + ''
            for ko in "$out"/lib/modules/*/misc/*.ko; do kmodigest "$ko"; done
          '';
        });
      });
    })
  ];
}
