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

  # No nixpkgs.config.cudaCapabilities pin: it existed solely for the blender cudaSupport
  # build (dropped 2026-07, home/gui.nix — the recurring uncached local rebuild wasn't worth
  # it; this host's blender is now the prebuilt blender-bin flake). Nothing on this host
  # builds CUDA kernels via nixpkgs now; NV Broadcast's CUDA is prebuilt pip wheels
  # (modules/nvbroadcast.nix). If a cudaSupport package ever returns, bring the pin back:
  # RTX 5090 = Blackwell, capability "12.0".

  # UEFI boot — adjust to match the real machine's firmware (see hosts/server for BIOS).
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # 4TB 990 PRO — bulk data (Steam library at /data/steam + repos). One-time formatted
  # ext4 (uniform with root; xfs/btrfs perf is a wash on NVMe for Steam+git, and ext4
  # keeps shrink/repartition open). nofail: a dead DATA drive must not drop boot to
  # emergency mode — the box still boots, just without /data. The Steam library is added
  # in Steam's own UI (libraryfolders.vdf is Steam-owned), so the flake's job ends here.
  fileSystems."/data" = {
    device = "/dev/disk/by-uuid/7e81b681-268c-47e6-99dc-93b2535c59c4";
    fsType = "ext4";
    options = [ "nofail" ];
  };

  # ~/repos lives on /data but must APPEAR at its canonical home path — chezmoi's
  # sourceDir (modules/dotfiles.nix) bakes /home/<user>/repos/nixos-configs, and a bind
  # mount (unlike a symlink) is invisible to path-resolving tools. systemd orders this
  # after /data automatically (RequiresMountsFor on the bind source).
  fileSystems."/home/${username}/repos" = {
    device = "/data/repos";
    fsType = "none";
    options = [ "bind" "nofail" ];
  };

  # Belt-and-braces: recreate the /data skeleton if it's ever lost (fresh disk, restore) —
  # the repos bind and Steam both need their dirs to exist before they can populate them.
  systemd.tmpfiles.rules = [
    "d /data/repos 0755 ${username} users -"
    "d /data/steam 0755 ${username} users -"
  ];

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
    #
    # MATCH BY `desc:`, NEVER BY PORT NAME. This box has TWO DRM cards — the RTX 5090 (nvidia)
    # and the Ryzen's Raphael iGPU (amdgpu) — sharing one DP-x name pool, and the split is not
    # stable across cold boots: the Alienware has been DP-6, then DP-1, now DP-4, while the
    # iGPU's own (permanently disconnected) outputs hold whichever names are left. A port-name
    # rule that loses that race silently binds to a DEAD iGPU connector, so both real panels
    # match no rule and fall back to Hyprland defaults (60Hz, scale 1, no transform, auto-placed
    # left-to-right) — the layout looks "smashed" and hdr-toggle.sh pushes HDR at a phantom
    # output. `desc:` matches the EDID make/model/serial, which no probe order can renumber.
    # Strings come from the `description` field of `hyprctl monitors all`; re-check only when a
    # panel is actually replaced — re-cabling and port swaps no longer matter.
    #
    # hyprsome still cares about ports: it namespaces workspaces by Hyprland monitor *id*
    # (id 0 -> ws 1-10, id 1 -> ws 11-20), and at COLD BOOT ids follow DRM connector order, so
    # the lowest-numbered CONNECTED port wins id 0. Keep the Alienware on the lower of the two
    # good nvidia DPs so it stays id 0 = hyprsome's primary and new windows/games default to it
    # instead of the portrait Dell. NOTE: the Dell would NOT link on the 5090's remaining DP
    # (dead/marginal). Live hotplug can assign ids out of connector order — only a cold boot is
    # canonical.
    #
    # Alienware scale 1.5: at scale 1 a 31.5" 4K panel renders the full 3840x2160 logically,
    # so the UI (incl. DMS) is microscopic — DMS honours the Hyprland scale, the scale was
    # just wrong. 1.5 -> logical 2560x1440, which divides the mode into whole px (3840/1.5,
    # 2160/1.5 both integer) so Hyprland won't nudge + warn. Drop back to 1.25 (-> 3072x1728)
    # if the UI is now too big. The Dell stays scale 1; 1440p portrait at this size is already
    # comfortable.
    #
    # HDR10 on the AW3225QF (QD-OLED) only — unlocks the panel's high peak luminance that SDR
    # firmware-caps at ~250 nits. The Dell stays SDR.
    #   bitdepth, 10    = 10-bit output (required for HDR)
    #   cm, hdr         = wide gamut + PQ/ST2084 transfer (HDR10; no Dolby Vision on Wayland)
    #   sdrbrightness   = brightness multiplier for SDR content in HDR mode — the dimness knob
    #   sdrsaturation   = SDR saturation in HDR mode (raise slightly if colors look pale)
    # Tune sdrbrightness live (no rebuild): hyprctl keyword monitor "<full Alienware line>".
    # sdrbrightness 12.5 ~ near-peak SDR white; sdrsaturation 1.2 counters SDR-in-HDR washout.
    # Tuned by eye — drop sdrbrightness if too bright/fatiguing. Do NOT add the old
    # xx_color_management_v4 / ENABLE_HDR_WSI / cm_auto_hdr env vars — cm-v4 is stable now
    # and they break it.
    "hypr/monitors.conf".text = ''
      monitor = desc:Dell Inc. AW3225QF 5K46YZ3, 3840x2160@240, 0x0, 1.5, bitdepth, 10, cm, hdr, sdrbrightness, 12.5, sdrsaturation, 1.2
      monitor = desc:Dell Inc. S2719DGF 8H2YBY2, 2560x1440@144, -1440x-560, 1, transform, 1
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

