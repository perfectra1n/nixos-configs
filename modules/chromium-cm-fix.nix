{ lib, inputs, ... }:

# HDR brightness fix for Chromium/Electron apps on Wayland.
#
# Chromium >= 141 binds the wp_color_manager_v1 protocol and declares its SDR UI as
# sRGB, so Hyprland renders it at the colorimetric reference (~80 nits) in HDR mode and
# deliberately skips the `sdrbrightness` boost. Result: Chrome/VSCode/Brave/Trilium look
# dim next to color-unmanaged apps (e.g. the older Discord Electron) on the HDR monitor.
#
# Hyprland has no global switch to hide client color management while keeping HDR output
# (verified on 0.55.3: render:reference_luminance / sdr_content_brightness don't exist —
# the proper fix is the unmerged hyprwm/Hyprland#14999). Until then we disable the
# Chromium feature per app via this single overlay.
#
# The flag is baked into the binary AND each app's .desktop Exec, because some desktop
# entries (e.g. google-chrome) hardcode an absolute store path, so a PATH-only wrapper
# would be bypassed by app-menu launches.
#
# Imported by modules/hyprland.nix → applies to the Wayland hosts only. Harmless on
# non-HDR / AMD outputs (it just turns off one Chromium feature). To cover another
# Chromium app, add one line to the attrset below.
#
# This module ALSO decides where Trilium comes from (upstream's flake, see the trilium input
# in flake.nix) — see the comment on that line for why the two can't be separate overlays.
# So when #14999 ships, don't just delete this file: re-home the trilium-desktop definition first.
{
  nixpkgs.overlays = [
    (final: prev:
      let
        flag = "--disable-features=WaylandWpColorManagerV1";

        # Wrap each named binary to append `flag`, then rewrite the Exec= of every
        # desktop entry that launches one of those binaries to the wrapped path.
        addCmFlag = pkg: bins: final.symlinkJoin {
          name = "${pkg.pname or pkg.name}-cmfix";
          paths = [ pkg ];
          nativeBuildInputs = [ final.makeWrapper ];
          postBuild = ''
            for b in ${lib.escapeShellArgs bins}; do
              if [ -e "$out/bin/$b" ]; then
                wrapProgram "$out/bin/$b" --add-flags "${flag}"
              fi
            done

            # Replace the symlinked .desktop files with writable copies whose Exec=
            # points at the wrapped binary (only for the binaries we actually wrapped).
            shopt -s nullglob
            for d in "$out"/share/applications/*.desktop; do
              real=$(readlink -f "$d"); rm -f "$d"; cp "$real" "$d"; chmod +w "$d"
              for b in ${lib.escapeShellArgs bins}; do
                sed -E -i "s|^(Exec=)([^ ]*/)?$b( .*)?\$|\1$out/bin/$b\3|" "$d"
              done
            done
          '';
        };
      in
      {
        google-chrome   = addCmFlag prev.google-chrome   [ "google-chrome-stable" ];
        brave           = addCmFlag prev.brave           [ "brave" ];
        vscode          = addCmFlag prev.vscode          [ "code" ];
        # The one entry NOT sourced from `prev`: Trilium comes from upstream's own flake, not
        # nixpkgs. Fusing the source swap into this wrap is deliberate — as two overlays it
        # would depend on which ran first (wrap-then-replace silently drops the flag), and an
        # invisible ordering constraint between two modules is worse than one honest line here.
        trilium-desktop = addCmFlag
          inputs.trilium.packages.${prev.stdenv.hostPlatform.system}.desktop [ "trilium" ];
        slack           = addCmFlag prev.slack           [ "slack" ];
      })
  ];
}
