{ pkgs, ... }:

# SnapX — ShareX fork (C#/Avalonia, GPL-3): region capture + annotation + upload-to-anywhere.
# Graphical hosts only. Currently 0.4.0-ALPHA upstream, added to evaluate it alongside flameshot
# (which stays the default — see modules/hyprland.nix's grim wrapper and the Hyprland keybinds).
#
# Capture path: SnapX shells out to the XDG *Screenshot portal* on Linux, never raw X11, so on
# Hyprland it goes through xdg-desktop-portal-hyprland → the grim wrapper in modules/hyprland.nix
# and inherits that wrapper's latency fix for free. Upstream lists Hyprland as "should work,
# untested" — it does.
#
# Why an FHS sandbox and not a normal derivation: `snapx-ui` is a self-contained .NET single-file
# bundle — an 82 MiB ELF with the runtime + every managed DLL appended AFTER the last ELF section.
# patchelf (and stdenv's strip) rebuild the file from its ELF structures and write straight over
# those appended bytes, so the app then reads a garbage bundle header and SIGSEGVs before a single
# line of managed code runs. VERIFIED, not theoretical: a --set-interpreter'd apphost segfaults
# instantly, the untouched one runs. So the bytes stay untouched and buildFHSEnv supplies the
# /usr/lib world they were linked against instead (a steam-run-style FHS sandbox; modules/nvbroadcast.nix
# used the same trick until cleanroom replaced it, so this is now the only place it survives).
#   Hence `dontFixup` on the payload below — that is load-bearing, not tidiness.
#
# Why the Fedora RPMs are the source: they are the only Linux artifact upstream ships that links
# against SYSTEM libs (116 MiB). The plain tarball vendors an entire userland — samba, mesa,
# ffmpeg, vulkan — for 672 MiB unpacked, all of it store bloat we already have in nixpkgs.
let
  sources = pkgs.callPackage ../_sources/generated.nix { };

  # Both RPMs: -ui (app, desktop entry, icons, Skia/HarfBuzz) hard-requires -core (sqlite +
  # onnxruntime natives, the browser NativeMessagingHost, and share/SnapX/Resources).
  payload = pkgs.stdenvNoCC.mkDerivation {
    pname = "snapx-payload";
    inherit (sources.snapx-ui) version;
    srcs = [ sources.snapx-core.src sources.snapx-ui.src ];

    nativeBuildInputs = with pkgs; [ rpm cpio ];

    unpackPhase = ''
      runHook preUnpack
      for rpm in $srcs; do rpm2cpio "$rpm" | cpio -idm --quiet; done
      runHook postUnpack
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp -r usr/lib $out/lib
      cp -r usr/share $out/share
      rm -rf $out/share/doc $out/share/licenses   # rpm packaging cruft
      runHook postInstall
    '';

    # THE load-bearing line: any fixup (strip, patchelf) corrupts the single-file bundle — see above.
    dontFixup = true;
  };

  snapx = pkgs.buildFHSEnv {
    name = "snapx-ui"; # = the Exec= in upstream's .desktop, so the menu entry resolves to this

    # Everything SnapX dlopens by soname at runtime. None of it is a DT_NEEDED entry — Avalonia
    # P/Invokes the X11 stack by name and .NET's crypto/globalization shims are extracted from the
    # bundle at launch — so nothing here can be discovered by autoPatchelf; it has to exist in the
    # sandbox's /usr/lib. libICE/libSM are the easy ones to miss: nothing declares them, and the
    # app dies with a DllNotFoundException at startup without them (Avalonia's X11 session mgmt).
    targetPkgs = p: with p; [
      stdenv.cc.cc.lib # libstdc++ — onnxruntime
      fontconfig
      freetype
      openssl # libssl.so.3 — .NET's OpenSSL shim (HTTPS to the upload destinations)
      icu # .NET globalization; the runtime refuses to start without it
      zlib
      libx11
      libxrandr
      libxi
      libxcursor
      libxext
      libxcb
      libice
      libsm
      libGL
      libglvnd

      # Shelled out to, not linked: the GPU/monitor probe on the startup path (lspci|grep|sed,
      # xrandr) and, from snapx-core, avifenc + xdg-open for AVIF export and "open in browser".
      pciutils
      gnugrep
      gnused
      xrandr
      libavif
      xdg-utils
    ];

    # The GPU driver is a NixOS host path, not a package: without this the sandbox's mesa libEGL
    # can't find the NVIDIA/AMD driver and SnapX logs no GPU at all. Correct on BOTH graphical
    # hosts — /run/opengl-driver is whatever that host's driver is (nvidia here, mesa on the laptop).
    profile = ''
      export LD_LIBRARY_PATH=/run/opengl-driver/lib:$LD_LIBRARY_PATH
    '';

    runScript = "${payload}/lib/snapx/snapx-ui";

    # buildFHSEnv only emits bin/, but the .desktop + icons have to sit OUTSIDE the sandbox for the
    # app launcher (and DMS's) to index them.
    extraInstallCommands = ''
      mkdir -p $out/share
      cp -r ${payload}/share/applications ${payload}/share/icons ${payload}/share/metainfo $out/share/
    '';
  };
in
{
  environment.systemPackages = [ snapx ];
}
