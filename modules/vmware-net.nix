{ config, lib, ... }:

# VMware vmnet subnets — pinned off the installer's random 192.168.x defaults.
#
# VMware picks a random 192.168.x.0/24 for vmnet1 (host-only) and vmnet8 (NAT) at first
# run. That is a safe bet against a /24 LAN and a GUARANTEED collision with this one,
# which hands out a /16: with 192.168.0.0/16 on the uplink, VMware's /24s sit INSIDE the
# LAN prefix and win longest-prefix match. Every LAN host whose DHCP lease lands in one
# of them is then black-holed into a VMware bridge — `ip route get <host>` answers
# `dev vmnet8` instead of the uplink. The vmnet adapters stay UP with no VM running, so
# this is permanent, not session-scoped, and it moves around as leases move, which reads
# as "some machines are randomly unreachable" rather than as a routing bug.
#
# 10.x is clear of both the LAN (192.168.0.0/16) and Docker's default pool (172.16.0.0/12,
# from which docker0/br-* already carve 172.17-172.19 here).
#
# Why environment.etc rather than vmware-netcfg: NixOS' vmware-host module seeds
# /etc/vmware/networking exactly once — vmware-networks-configuration.service carries
# `ConditionPathExists = "!/etc/vmware/networking"` — and never revisits it. Left alone the
# subnets are one-shot mutable state that a reinstall regenerates at random, i.e. this bug
# comes back silently. Owning the files makes the choice reproducible, and the Condition
# means the generator simply never runs. Trade-off: vmware-netcfg can no longer edit these
# (they become read-only store symlinks) — edit `hostOnly`/`nat` below instead.
#
# The installer's *_DHCP_CFG_HASH lines are deliberately omitted. They exist so
# vmware-netcfg can tell whether a human hand-edited the DO-NOT-MODIFY block; nothing
# consumes them at runtime, and that editor is out of the loop now anyway.
#
# dhcpd.leases lives in the same directory and stays a real writable file — NixOS only
# symlinks the leaves it manages, so vmnet-dhcpd can still write its lease database.
#
# ── Working with VMs on these nets ───────────────────────────────────────────────────
#
# New VM: nothing to do here. Pick "NAT" in the VMware wizard and the guest DHCPs an
# address out of 10.155.8.128-254, with 10.155.8.2 as both gateway and resolver.
# "Host-only" gets 10.155.1.128-254 and no gateway — that net has no route off the box,
# which is the point of it.
#
# Static address inside a guest: use .3-.127 on either net. Below .128 keeps it clear of
# the DHCP range; above .2 keeps it clear of the host adapter (.1) and vmnet-natd (.2).
#
# Reaching a VM: from THIS host, 10.155.8.x works directly. From another LAN machine it
# does not — vmnet8 is NAT, so the guest has no LAN presence of its own. Two ways out:
#   - Port-forward: add a line under [incomingtcp] in nat.conf below, e.g.
#     `8080 = 10.155.8.130:80`, then rebuild. That file is a read-only store symlink now,
#     so it has to be edited HERE — editing /etc/vmware/... will not stick.
#   - Bridged networking (vmnet0), which this module deliberately does not touch: the
#     guest gets a real address from the LAN router and is reachable like any other host.
#     That is the right mode when a VM needs to be a first-class LAN citizen.
#
# Changing a subnet: edit the `hostOnly` / `nat` bindings below — every file that encodes
# the subnet is templated from those two strings, which is the whole reason they are
# templated. The restartTriggers at the bottom then bounce vmware-networks on the next
# switch, and its ExecStop is `vmware-networks --stop`: that drops EVERY vmnet adapter and
# kills networking inside any running VM. Shut guests down before rebuilding.
#
# Whatever you pick, keep it clear of the two ranges named above — the LAN's /16 and
# Docker's /12 — or you have simply moved the collision rather than fixed it.
#
# Do not reach for vmware-netcfg. The four files it edits are read-only store symlinks; it
# will either fail outright or write something the next switch silently reverts.

let
  # Third octet base for each vmnet. .1 is always the host adapter; on vmnet8 .2 is
  # additionally the NAT gateway (vmnet-natd), which is why that file names both.
  hostOnly = "10.155.1"; # vmnet1, host-only
  nat = "10.155.8"; # vmnet8, NAT

  # VMware's own deterministic vmnet adapter MACs; the DHCP host stanzas pin the .1
  # address to them, so they have to keep matching what the vmnet module creates.
  hostOnlyMac = "00:50:56:C0:00:01";
  natMac = "00:50:56:C0:00:08";

  # vmnet-dhcpd wants ISC-2.0 syntax. `net` is the /24 base, `dns` the address handed to
  # guests as resolver (the NAT gateway on vmnet8, the host adapter on vmnet1). `routers`
  # is null on a host-only net, which has no gateway to advertise. Built as a line list
  # rather than one indented string so the optional stanzas leave no blank lines behind.
  dhcpdConf =
    {
      vmnet,
      net,
      mac,
      dns,
      routers ? null,
    }:
    lib.concatLines (
      [
        "# Configuration file for ISC 2.0 vmnet-dhcpd operating on ${vmnet}."
        "#"
        "# Generated by modules/vmware-net.nix (NixOS). Do not edit in place: this is a"
        "# read-only symlink into the Nix store. Change the subnet in that module instead."
        ""
        "allow unknown-clients;"
        "default-lease-time 1800;"
        "max-lease-time 7200;"
        ""
        "subnet ${net}.0 netmask 255.255.255.0 {"
        "\trange ${net}.128 ${net}.254;"
        "\toption broadcast-address ${net}.255;"
        "\toption domain-name-servers ${dns};"
        "\toption domain-name localdomain;"
        "\tdefault-lease-time 1800;"
        "\tmax-lease-time 7200;"
      ]
      ++ lib.optionals (routers != null) [
        "\toption netbios-name-servers ${routers};"
        "\toption routers ${routers};"
      ]
      ++ [
        "}"
        "host ${vmnet} {"
        "\thardware ethernet ${mac};"
        "\tfixed-address ${net}.1;"
        "\toption domain-name-servers 0.0.0.0;"
        "\toption domain-name \"\";"
      ]
      # Pins the host stanza's own lease to "no gateway", matching what VMware generates.
      ++ lib.optionals (routers != null) [ "\toption routers 0.0.0.0;" ]
      ++ [ "}" ]
    );
in
{
  environment.etc = {
    # Read by `vmware-networks --start`. VNET_1 = host-only, VNET_8 = NAT.
    "vmware/networking".text = ''
      VERSION=1,0
      answer VNET_1_DHCP yes
      answer VNET_1_HOSTONLY_NETMASK 255.255.255.0
      answer VNET_1_HOSTONLY_SUBNET ${hostOnly}.0
      answer VNET_1_VIRTUAL_ADAPTER yes
      answer VNET_8_DHCP yes
      answer VNET_8_HOSTONLY_NETMASK 255.255.255.0
      answer VNET_8_HOSTONLY_SUBNET ${nat}.0
      answer VNET_8_NAT yes
      answer VNET_8_VIRTUAL_ADAPTER yes
    '';

    "vmware/vmnet1/dhcpd/dhcpd.conf".text = dhcpdConf {
      vmnet = "vmnet1";
      net = hostOnly;
      mac = hostOnlyMac;
      dns = "${hostOnly}.1"; # host-only has no gateway; the host adapter answers
    };

    "vmware/vmnet8/dhcpd/dhcpd.conf".text = dhcpdConf {
      vmnet = "vmnet8";
      net = nat;
      mac = natMac;
      dns = "${nat}.2"; # vmnet-natd, not the host adapter
      routers = "${nat}.2";
    };

    # natIp6* stays disabled: guests get IPv4 NAT only. The prefix below is VMware's own
    # generated default, kept so the file round-trips; nothing reads it while the enable
    # flag is 0. Turning it on would put a second, unrouted RA source on the vmnet bridge
    # — the LAN collision this module exists to prevent, in its IPv6 form.
    "vmware/vmnet8/nat/nat.conf".text = ''
      # VMware NAT configuration file
      # Generated by modules/vmware-net.nix (NixOS) — edit that module, not this file.

      [host]
      useMacosVmnetVirtApi = 0
      ip = ${nat}.2
      netmask = 255.255.255.0
      device = /dev/vmnet8
      activeFTP = 1
      allowAnyOUI = 1
      hostIp = ${nat}.1
      # Guests' TCP sessions are reset whenever the vmnet uplink reports link-down. That
      # is why host-side netlink churn (every Docker veth create/destroy triggers a
      # `userif-N: sent link down event` pair from the vmnet module) shows up inside VMs
      # as dropped connections. Left at VMware's default; the real fix is fewer host
      # netlink events, not pretending the link never drops.
      resetConnectionOnLinkDown = 1
      resetConnectionOnDestLocalHost = 1
      natIp6Enable = 0
      natIp6Prefix = fd15:4ba5:5a2b:1008::/64

      [tcp]
      timeWaitTimeout = 30

      [udp]
      timeout = 60

      [netbios]
      nbnsTimeout = 2
      nbnsRetries = 3
      nbdsTimeout = 3

      [incomingtcp]

      [incomingudp]
    '';
  };

  # environment.etc changes alone are INERT here. vmware-networks.service is Type=forking
  # and reads /etc/vmware/networking exactly once, at ExecStart; its unit definition names
  # only ${pkgs.vmware-workstation}/bin/vmware-networks, so switch-to-configuration sees a
  # byte-identical unit and never restarts it. Rewriting the subnet above therefore lands on
  # disk while vmnet1/vmnet8 keep running the OLD one until the next reboot — which is how
  # the original 192.168.x collision survived its own fix and kept black-holing LAN hosts.
  # Hashing the four files into the unit makes the running adapters follow the config.
  #
  # Cost: ExecStop is `vmware-networks --stop`, so this drops every vmnet adapter and kills
  # networking inside any running VM. Only fires when one of these files actually changes.
  systemd.services.vmware-networks.restartTriggers = [
    config.environment.etc."vmware/networking".source
    config.environment.etc."vmware/vmnet1/dhcpd/dhcpd.conf".source
    config.environment.etc."vmware/vmnet8/dhcpd/dhcpd.conf".source
    config.environment.etc."vmware/vmnet8/nat/nat.conf".source
  ];
}
