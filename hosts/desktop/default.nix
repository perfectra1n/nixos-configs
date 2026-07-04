{ config, pkgs, lib, username, ... }:

# Bare-metal desktop (NVIDIA). Composes (from flake.nix): common + facter +
# desktop-base + hyprland + gaming + nvidia + pentest + desktop-apps + the chaotic
# module. Plus this host's hardware + identity below.
{
  imports = [ ./hardware-configuration.nix ];

  networking.hostName = "desktop";

  # CachyOS kernel (chaotic-nyx) — built-in sched_ext + gaming tuning, pairs with the scx
  # scheduler in modules/gaming.nix. The chaotic module (+ its binary cache) comes from
  # inputs.chaotic.nixosModules.default, added to this host's extraModules in flake.nix; do
  # NOT make chaotic follow nixpkgs (flake.nix comment) or this forces a local kernel build.
  # Use the -gcc variant, NOT the default linuxPackages_cachyos (= cachyos-lto, Clang+ThinLTO):
  # out-of-tree modules (vmware vmmon/vmnet, nvidia, v4l2loopback) inherit the kernel's stdenv,
  # so an LTO kernel builds them under pkgsLLVM — which drags in a Clang-built gnugrep-3.12 whose
  # gnulib float-h test is broken under Clang (FLT_IS_IEC_60559 undeclared; gnulib fix not yet in
  # nixpkgs). The -gcc kernel builds modules with GCC, all cached upstream. CachyOS itself defaults
  # to GCC for this reason; the ~1% LTO delta isn't worth a local kernel+toolchain rebuild here.
  boot.kernelPackages = pkgs.linuxPackages_cachyos-gcc;

  # Pin CUDA builds to THIS GPU's compute capability (RTX 5090 = Blackwell, sm_120 / cap 12.0).
  # Only the CUDA-accelerated obs-backgroundremoval (modules/desktop-apps.nix, NVIDIA-gated) uses
  # CUDA here, and onnxruntime derives its target arch from config.cudaCapabilities — left at the
  # nixpkgs default it would compile every supported arch (7.5…12.1), a far longer build for code
  # this machine can't run. nixpkgs' default cudaPackages is 12.9, which supports 12.0. Host-local
  # (the AMD laptop sharing desktop-apps.nix builds no CUDA and never reads this).
  nixpkgs.config.cudaCapabilities = [ "12.0" ];

  # UEFI boot — adjust to match the real machine's firmware (see hosts/server for BIOS).
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # VMware Workstation host (builds vmmon/vmnet kernel modules against the running kernel —
  # here the CachyOS one). unfree. Provides `vmware` + the networking/USB-arbitrator services.
  virtualisation.vmware.host.enable = true;

  # Bluetooth radio + GUI manager (no settings app on a WM-only desktop).
  hardware.bluetooth.enable = true;
  hardware.bluetooth.powerOnBoot = true;
  services.blueman.enable = true;

  # Astro A50: present ONLY "A50 Pro 1". The base station exposes two USB output endpoints
  # (its game/chat split), which PipeWire surfaces as two sinks — "A50 Pro" (pro-output-0,
  # 16-bit) and "A50 Pro 1" (pro-output-1, 24-bit). With both live, apps scatter across them
  # (CS2 in particular grabbed A50 Pro). Disable pro-output-0 so A50 Pro 1 is the only A50 sink
  # and everything converges on it — the Linux equivalent of disabling the device in Windows.
  # VERIFY the node name matches your unit: `wpctl status` (a mismatch just makes this a no-op).
  # After a wireplumber restart/relogin, `wpctl status` should list only "A50 Pro 1".
  services.pipewire.wireplumber.extraConfig."51-a50-single-output" = {
    "monitor.alsa.rules" = [
      {
        matches = [ { "node.name" = "alsa_output.usb-Logitech_A50-00.pro-output-0"; } ];
        actions.update-props."node.disabled" = true;
      }
    ];
  };

  # Pin the DeepFilter denoiser (modules/noise-suppression.nix) to the Scarlett's XLR mic
  # ("Input 1 Mic"), so it stays the input even when deepfilter_source itself is the default
  # source (a null target would otherwise loop back on itself). Device-serial-specific →
  # lives here per-host, not in the shared module. The laptop leaves this null (no Scarlett).
  services.deepfilterNoiseSuppression.captureTarget =
    "alsa_input.usb-Focusrite_Scarlett_Solo_USB_Y7H767R15C5B05-00.HiFi__Mic1__source";

  # Autologin straight into Hyprland at boot. greetd's initial_session fires once with no
  # greeter; the tuigreet default_session (modules/hyprland.nix) still handles later logins
  # (e.g. after logout). Single-user box convenience — anyone with physical access lands in
  # the session. Matches the greeter's `--cmd start-hyprland` so the session env is exported
  # identically (the wrapper programs.hyprland.enable installs).
  services.greetd.settings.initial_session = {
    command = "start-hyprland";
    user = username;
  };

  # Hyprland per-host fragments the chezmoi hyprland.conf `source`s (alongside gpu.conf
  # from modules/nvidia.nix and autostart.conf from modules/desktop-apps.nix). Kept here,
  # not in chezmoi, so the shared dotfile stays host-agnostic and each box owns its layout.
  # Both attrs live under ONE ${username} binding — Nix can't merge a dynamic key across
  # separate bindings in a module (see the note in modules/desktop-apps.nix).
  home-manager.users.${username}.xdg.configFile = {
    # Two-panel layout. Alienware AW3225QF (4K 240Hz) is the MAIN display, pinned to the
    # origin 0x0 — Hyprland gravitates default focus, new windows, and layer surfaces to the
    # monitor at 0,0, so origin = "primary" here. Dell S2719DGF (1440p) sits physically to its
    # LEFT in PORTRAIT: `transform, 1` rotates it 90° clockwise (top edge → right), which makes
    # its rotated footprint 1440 wide × 2560 tall, so a negative x of -1440 abuts the Alienware's
    # left edge with no gap/overlap. If the Dell comes out upside-down, swap transform 1 → 3.
    # The Dell's y=-560 vertically CENTERS the two. NOTE the Alienware's scale 1.5 makes its
    # EFFECTIVE height 1440 (2160/1.5), not 2160 — so its midpoint is y=720, not 1080. The Dell
    # portrait is 2560 tall (scale 1), so to put its midpoint at 720: y = 720 - 2560/2 = -560.
    # It overhangs ~560px above and below the Alienware. Cursor crosses straight across instead
    # of jumping. Nudge -416 up/down to taste (more negative = Dell moves UP).
    # Names/modes from `hyprctl monitors all`; re-check after any cable/port swap.
    #
    # CONNECTOR CHOICE: the Alienware is on DP-1 on purpose. hyprsome namespaces workspaces by
    # Hyprland monitor *id* (id 0 -> ws 1-10, id 1 -> ws 11-20), and at COLD BOOT ids follow DRM
    # connector order, so the lowest-numbered connected port wins id 0. Putting the MAIN display
    # on DP-1 (the lowest port) makes it monitor id 0 = hyprsome's primary, so new windows/games
    # default to it instead of the portrait Dell. Keep the Alienware on the lowest DP if you
    # re-cable. NOTE: the Dell would NOT link on DP-3 (dead/marginal); DP-1+DP-2 are the good
    # ports. Live hotplug can assign ids out of connector order — only a cold boot is canonical.
    #
    # DP-1 scale 1.5: at scale 1 a 31.5" 4K panel renders the full 3840x2160 logically,
    # so the UI (incl. DMS) is microscopic — DMS honours the Hyprland scale, the scale was
    # just wrong. 1.5 -> logical 2560x1440, which divides the mode into whole px (3840/1.5,
    # 2160/1.5 both integer) so Hyprland won't nudge + warn. Drop back to 1.25 (-> 3072x1728)
    # if the UI is now too big. DP-2 stays scale 1; 1440p portrait at this size is already comfortable.
    #
    # HDR10 on the AW3225QF (QD-OLED) only — unlocks the panel's high peak luminance that SDR
    # firmware-caps at ~250 nits. The Dell stays SDR.
    #   bitdepth, 10    = 10-bit output (required for HDR)
    #   cm, hdr         = wide gamut + PQ/ST2084 transfer (HDR10; no Dolby Vision on Wayland)
    #   sdrbrightness   = brightness multiplier for SDR content in HDR mode — the dimness knob
    #   sdrsaturation   = SDR saturation in HDR mode (raise slightly if colors look pale)
    # Tune sdrbrightness live (no rebuild): hyprctl keyword monitor "<full DP-1 line>".
    # sdrbrightness 12.5 ~ near-peak SDR white; sdrsaturation 1.2 counters SDR-in-HDR washout.
    # Tuned by eye — drop sdrbrightness if too bright/fatiguing. Do NOT add the old
    # xx_color_management_v4 / ENABLE_HDR_WSI / cm_auto_hdr env vars — cm-v4 is stable now
    # and they break it.
    "hypr/monitors.conf".text = ''
      monitor = DP-1, 3840x2160@240, 0x0, 1.5, bitdepth, 10, cm, hdr, sdrbrightness, 12.5, sdrsaturation, 1.2
      monitor = DP-2, 2560x1440@144, -1440x-560, 1, transform, 1
    '';
    # Mouse feel (host-specific). sensitivity 0 = no accel change; flat = raw 1:1 movement.
    "hypr/input.conf".text = ''
      input {
        sensitivity = 0
        accel_profile = flat
      }
    '';
  };
}

