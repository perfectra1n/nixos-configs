{ config, pkgs, lib, username, ... }:

# Laptop (AMD). Composes (from flake.nix): common + facter + desktop-base +
# hyprland + gaming + amd + laptop + desktop-apps + the chaotic module. Plus this
# host's hardware below.
{
  imports = [ ./hardware-configuration.nix ];

  networking.hostName = "laptop";

  # CachyOS kernel (chaotic-nyx) — built-in sched_ext + gaming tuning, pairs with the scx
  # scheduler in modules/gaming.nix. The chaotic module (+ its binary cache) comes from
  # inputs.chaotic.nixosModules.default, added to this host's extraModules in flake.nix; do
  # NOT make chaotic follow nixpkgs (flake.nix comment) or this forces a local kernel build.
  # Use the -gcc variant, NOT the default linuxPackages_cachyos (= cachyos-lto, Clang+ThinLTO):
  # out-of-tree modules (here v4l2loopback via modules/desktop-apps.nix) inherit the kernel's
  # stdenv, so an LTO kernel builds them under pkgsLLVM — which drags in a Clang-built gnugrep-3.12
  # whose gnulib float-h test is broken under Clang (FLT_IS_IEC_60559 undeclared; fix not yet in
  # nixpkgs). The -gcc kernel builds modules with GCC, all cached upstream. See hosts/desktop.
  boot.kernelPackages = pkgs.linuxPackages_cachyos-gcc;

  # eDP panel flicker on idle/static content (BOE panel @165): the flicker engages only when
  # nothing is redrawing and clears the instant something animates (cursor, workspace switch).
  # That signature = an amdgpu idle/self-refresh feature, NOT VRR (disabling misc:vrr didn't
  # help) and not link training. amdgpu.dcdebugmask is a bitmask read at module load disabling
  # DC features. Bits: PSR 0x10, MPO 0x40, PSR-SU 0x200, Replay 0x400, IPS 0x800. Disabling the
  # whole idle/self-refresh family (0xE10 = IPS|PSR|PSR-SU|Replay) killed the flicker, and IPS
  # alone (0x800) did NOT — so IPS isn't the offender. Drop it to reclaim IPS power saving:
  # 0x610 = PSR|PSR-SU|Replay. To find the single culprit and re-enable the rest, test one bit
  # at a time at the systemd-boot menu (press `e`): 0x10 (PSR), 0x200 (PSR-SU), 0x400 (Replay).
  boot.kernelParams = [ "amdgpu.dcdebugmask=0x610" ];

  # UEFI boot — virtually all modern laptops.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Bluetooth radio + GUI manager.
  hardware.bluetooth.enable = true;
  hardware.bluetooth.powerOnBoot = true;
  services.blueman.enable = true;

  # Fingerprint reader. fprintd brings up the net.reactivated.Fprint D-Bus daemon and puts
  # fprintd-enroll / fprintd-list on PATH. It is the ONLY system-level piece the DMS lock
  # screen needs: DMS authenticates fingerprints through its own bundled PAM stack
  # (a pure client of this daemon), so no /etc/pam.d or security.pam changes are required for
  # unlock itself. If the sensor is a closed Touch-OEM (TOD) device, also set the matching
  # libfprint-2-tod1 driver; the common open-driver readers (e.g. Goodix goodixmoc) work as-is.
  # After rebuild, enroll with `fprintd-enroll`, then turn on Settings → Lock Screen →
  # Fingerprint in DMS. The greeter (tuigreet) is intentionally left password-only.
  services.fprintd.enable = true;

  # Dedicated password-only PAM stack for the DMS lock screen's PASSWORD field. DMS's lock runs
  # two separate PAM contexts: fingerprint (its own bundled `fprint` config) and password
  # (config "dankshell" if /etc/pam.d/dankshell exists, else it falls back to "login"). Enabling
  # fprintd above auto-sets fprintAuth=true on the system `login` service, so the fallback would
  # put pam_fprintd FIRST in the password stack — two contexts then fight over the one fprintd
  # device and typed-password auth breaks. Defining this service creates /etc/pam.d/dankshell,
  # which DMS detects and uses for the password field; fprintAuth=false keeps it password-only.
  # Fingerprint unlock is unaffected — it stays in DMS's own fprint context.
  security.pam.services.dankshell.fprintAuth = false;

  # Hyprland per-host fragments the chezmoi hyprland.conf `source`s (alongside gpu.conf
  # from modules/amd.nix and autostart.conf from modules/desktop-apps.nix). Kept here, not
  # in chezmoi, so the shared dotfile stays host-agnostic. One ${username} binding — Nix
  # can't merge a dynamic key across separate bindings (see modules/desktop-apps.nix).
  home-manager.users.${username}.xdg.configFile = {
    # Internal panel is BOE 2560x1600@165 (16" HiDPI) — at scale 1 the UI is microscopic.
    # Scale 1.333 (= 4/3) → logical 1920x1200: Hyprland needs the scale to divide the mode
    # into whole pixels (2560/1.333 = 1920, 1600/1.333 = 1200). 1.333 is the middle ground
    # between 1.25 (2048x1280, smaller UI) and 1.6 (1600x1000, larger UI) — bump toward 1.6
    # if it's still too small. The bare line is a catch-all so an external display still works.
    "hypr/monitors.conf".text = ''
      monitor = eDP-1, 2560x1600@165, 0x0, 1.333
      monitor = , preferred, auto, auto

      # Steam is XWayland-only and renders its desktop UI at 1x; scale it to match the panel
      # so it isn't tiny. Same value as the monitor scale above.
      env = STEAM_FORCE_DESKTOPUI_SCALING,1.333
    '';
    # Touchpad defaults for a laptop. natural_scroll + tap-to-click are the common wants;
    # disable_while_typing avoids stray cursor jumps. Tune via the Hyprland input wiki.
    "hypr/input.conf".text = ''
      input {
        touchpad {
          natural_scroll = false
          tap-to-click = true
          disable_while_typing = true
          scroll_factor = 0.3   # 0.5 (half of the 1.0 default) still scrolled too fast; 0.3 tames it
        }
      }
    '';
  };
}
