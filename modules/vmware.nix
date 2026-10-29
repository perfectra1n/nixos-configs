{ ... }:

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
}
