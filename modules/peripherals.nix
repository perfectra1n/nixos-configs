{ config, pkgs, lib, username, ... }:

# Physical peripheral support for the bare-metal desktops (desktop, laptop): gaming mice,
# RGB lighting, and QMK/VIA keyboards. All vendor-agnostic — no per-device kernel modules
# (OpenRazer etc.) because there's no Razer hardware here; add one only if that changes.
#
# Replaces Solaar (was in desktop-apps.nix) with libratbag/Piper, which writes DPI + button
# remaps to the mouse's ONBOARD memory — so settings survive reboots/compositors and nothing
# needs to autostart to reapply them, unlike Solaar's tray daemon.
let
  # libratbag's pinned fork-branch source comes from nvfetcher (version + src + hash), bumped by
  # Renovate — same single-source-of-truth as the CLIs in modules/common.nix.
  sources = pkgs.callPackage ../_sources/generated.nix { };
in
{
  # Gaming mice — ratbagd is the daemon, Piper (below) its GTK frontend: DPI stages, button
  # remaps, LEDs, onboard profiles. Speaks libratbag, covering Logitech/SteelSeries/Roccat/etc.
  services.ratbagd.enable = true;

  # ── 1:1 wheel scrolling: disable libinput high-resolution scroll on all mice ──
  # Modern mice (the G502 X PLUS above included) emit REL_WHEEL_HI_RES — the v120 model where one
  # physical detent = 120 units delivered as several fractional events. Apps that consume that
  # smooth stream (GTK4, Chromium, XWayland) scroll imprecisely. This quirk masks the hi-res axis
  # so libinput falls back to the legacy REL_WHEEL the kernel still emits alongside it → exactly
  # one event per physical detent. Chosen over Solaar's HID++ hi-res toggle for the same reasons
  # Solaar lost to libratbag: no daemon (static file), MatchUdevType=mouse covers wired AND
  # wireless by device class (and excludes touchpads), and it never touches the HID++ 0x2121 wheel
  # mode, avoiding the mode-change event Solaar swallows as an "ignored first scroll". Needs
  # libinput >= 1.30 (the quirk regressed in 1.29; we pin 1.31+). A parse error SILENTLY disables
  # ALL quirks. ⚠ libinput reads quirk files only at context creation (Hyprland startup), never on
  # hotplug — a rebuild changing this needs a RELOG to take effect, not a mouse re-plug. Verify a
  # fresh context matches: `sudo libinput quirks list /dev/input/eventN` (expect the AttrEventCode
  # line).
  environment.etc."libinput/local-overrides.quirks".text = ''
    [Disable hi-res wheel on all mice]
    MatchUdevType=mouse
    AttrEventCode=-REL_WHEEL_HI_RES;-REL_HWHEEL_HI_RES;
  '';

  # RGB lighting across vendors (mouse, RAM, mobo, fans). The module installs the udev rules,
  # loads i2c-dev for SMBus controllers, and runs the OpenRGB server; the GUI is the package.
  services.hardware.openrgb.enable = true;

  # Logitech wireless receivers (Unifying/Bolt): keep the udev rules so libratbag/ratbagd can
  # reach the receiver — but enableGraphical=false, since Piper replaces Solaar's GUI. Flip
  # enableGraphical back on only if you need Unifying *pairing* or battery %, which libratbag
  # doesn't expose (DMS shows battery via UPower regardless).
  hardware.logitech.wireless = {
    enable = true;
    enableGraphical = false;
  };

  # QMK/VIA keyboards (e.g. Keychron Q10). Vial (below) is the open VIA fork — remap keys,
  # layers, and macros from a desktop app. qmk-udev-rules grants hidraw access (also what VIA
  # over WebHID in Chrome needs).
  #   plugdev: qmk's catch-all hidraw rule does GROUP="plugdev", which NixOS doesn't create by
  #   default — udev then DROPS the whole rule ("Failed to resolve group 'plugdev'") and no
  #   uaccess tag is applied. Create the group + add the user so the rule loads.
  services.udev.packages = [ pkgs.qmk-udev-rules ];
  users.groups.plugdev = { };
  users.users.${username}.extraGroups = [ "plugdev" ];

  environment.systemPackages = with pkgs; [
    piper   # GTK frontend to ratbagd/libratbag — gaming-mouse DPI/buttons/LEDs/profiles
    vial    # VIA-compatible QMK keyboard configurator (Keychron Q10)
    openrgb # RGB control GUI (the openrgb service runs the server; this is the front-end)
  ];

  # Build libratbag from our fork instead of nixpkgs' 0.18 release. Two reasons:
  #  1. v0.18 predates the G502 X PLUS support (onboard-profile format 0x05, wireless PID
  #     046d:4099) merged upstream after the tag — without it ratbagd aborts the probe
  #     ("Profile layout not supported: 0x05" → "No devices available").
  #  2. Even on master the G502 X PLUS DPI/buttons don't apply: it reports a 1-indexed active
  #     profile, but its device file could only carry ONE quirk (the LED one), so the
  #     INDEX_OFFSET fix was missing and libratbag edited the wrong profile. Our fork branch
  #     makes hidpp20 quirks a combinable bitmask and tags the X PLUS with both quirks
  #     (submitted upstream as a PR). Repoint owner→"libratbag" once that PR + a release land.
  # ratbagd lives inside this package, so the override updates the daemon too; Piper talks to it
  # over the unchanged DBus API v2.
  nixpkgs.overlays = [
    (final: prev: {
      libratbag = prev.libratbag.overrideAttrs (old: {
        version = "0.18-unstable-${builtins.substring 0 7 sources.libratbag.version}";
        src = sources.libratbag.src;
      });
    })
  ];
}
