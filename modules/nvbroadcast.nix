{ config, pkgs, lib, ... }:

# NV Broadcast — unofficial NVIDIA Broadcast for Linux (Hkshoonya/nvidia-broadcast-linux):
# AI virtual camera (background blur/replace, auto-framing, eye contact) + noise removal,
# GTK4/Python, GPU-accelerated via the onnxruntime CUDA EP. NVIDIA hosts only (desktop).
#
# Why not a normal Nix package: the app hard-pins onnxruntime-gpu==1.24.4 and depends on
# mediapipe + pyrnnoise, none of which exist in nixpkgs (mediapipe is an unpackaged Bazel
# build). So instead of fighting that, run it the way upstream expects — pip manylinux
# wheels — inside a buildFHSEnv sandbox (the steam-run trick: wheels get the /usr/lib +
# ld.so.cache world they were linked against). The venv is bootstrapped on first launch
# and rebuilt whenever the pin or interpreter changes; WHICH source version gets installed
# stays declarative — nvfetcher-pinned + Renovate-bumped like the other out-of-tree pins.
# The pip CUDA wheels (cudnn/cublas/nvrtc) are self-contained; only libcuda comes from the
# host driver via /run/opengl-driver.
#
# This replaces the retired OBS `blurcam` workflow (obs-backgroundremoval + a manual OBS
# toggle, removed from modules/desktop-apps.nix) — same blurred-webcam outcome, purpose-built
# UI, no OBS cold-start.
#
# Virtual camera: the app hardcodes /dev/video10 — the v4l2loopback node owned by
# modules/virtual-camera.nix (shared with OBS's "Start Virtual Camera"; one producer at a
# time). Don't add a second loopback device here: the app's discovery checks the video10
# path FIRST, so it would grab that node anyway.
let
  sources = pkgs.callPackage ../_sources/generated.nix { };
  inherit (sources.nvbroadcast) version src;

  # python312, NOT 313: mediapipe ships manylinux wheels only up to cp312. pygobject/pycairo
  # come from nixpkgs (pip can't build them without girepository headers) and reach the app
  # through the venv's --system-site-packages.
  python = pkgs.python312.withPackages (ps: with ps; [ pygobject3 pycairo ]);

  # "[cuda]" pulls the self-contained nvidia-*-cu12 wheel stack + onnxruntime-gpu (the 5090
  # runs inference); "[meeting]" adds local Whisper meeting transcription — its openai-whisper
  # dep drags in a multi-GB torch, accepted for the feature. Changing this rebuilds the venv.
  extras = "cuda,meeting";

  fhsEnv = pkgs.buildFHSEnv {
    name = "nvbroadcast-env";
    targetPkgs = p: with p; [
      python

      # GTK4 UI + introspection (typelibs merge into /usr/lib/girepository-1.0). gi resolves
      # a namespace's DEPENDENCY typelibs too, so GTK4's chain (Graphene/Pango/GdkPixbuf/
      # HarfBuzz) must be present explicitly — nix RPATHs cover the .so's but not typelibs.
      gtk4
      graphene
      pango
      harfbuzz
      gdk-pixbuf
      librsvg # SVG pixbuf loader (app + icon theme ship SVG assets)
      libadwaita
      glib
      gobject-introspection
      gsettings-desktop-schemas
      adwaita-icon-theme
      gtk3 # the AyatanaAppIndicator3 tray path is GTK3-based
      libayatana-appindicator # tray icon (gi AyatanaAppIndicator3)

      # camera pipeline: GStreamer core + v4l2src/videoconvert live in -good/-base
      gst_all_1.gstreamer
      gst_all_1.gst-plugins-base
      gst_all_1.gst-plugins-good
      gst_all_1.gst-plugins-bad
      pipewire

      # native libs the manylinux wheels dlopen but don't bundle (mediapipe: GL + glib;
      # everything C++: libstdc++; mediapipe's opencv-contrib — the non-headless build —
      # wants the X11 client libs even on Wayland). Must be in /usr/lib — wheels have no RPATHs.
      libGL
      libglvnd
      stdenv.cc.cc.lib
      zlib
      xorg.libxcb
      xorg.libX11
      xorg.libXext
      xorg.libSM
      xorg.libICE

      # upstream debian Depends: v4l2-ctl (device discovery), pactl (mic routing),
      # fuser/killall (stale-producer cleanup)
      v4l-utils
      pulseaudio
      psmisc
    ];
    profile = ''
      # nixpkgs gi/gst only search their baked-in store paths — point them at the FHS
      # merge dirs so the typelibs/plugins of every targetPkg above are visible.
      export GI_TYPELIB_PATH=/usr/lib/girepository-1.0
      export GST_PLUGIN_SYSTEM_PATH_1_0=/usr/lib/gstreamer-1.0
      # libcuda/libnvidia-* live with the driver, not in any wheel
      export LD_LIBRARY_PATH=/run/opengl-driver/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
    '';
    # $1 = console-script to exec (nvbroadcast | nvbroadcast-vcam), rest passed through.
    runScript = pkgs.writeShellScript "nvbroadcast-launch" ''
      set -euo pipefail
      entry="$1"; shift
      state="''${XDG_DATA_HOME:-$HOME/.local/share}/nvbroadcast-nix"
      venv="$state/venv"
      want="${version}-py${python.pythonVersion or "3.12"}-${extras}"
      if [ ! -x "$venv/bin/$entry" ] || [ "$(cat "$venv/.pin" 2>/dev/null)" != "$want" ]; then
        echo "nvbroadcast: building venv for $want (first run downloads ~3 GB of CUDA wheels)…" >&2
        rm -rf "$venv"
        mkdir -p "$state"
        python3 -m venv --system-site-packages "$venv"
        # pip's PEP 517 build wants to write next to the source — copy out of the RO store
        tmp="$(mktemp -d)"
        trap 'rm -rf "$tmp"' EXIT
        cp -r --no-preserve=mode ${src} "$tmp/src"
        "$venv/bin/pip" install --quiet --upgrade pip
        "$venv/bin/pip" install "$tmp/src[${extras}]"
        # onnxruntime (CPU, core dep) and onnxruntime-gpu (cuda extra) unpack into the SAME
        # package dir; whichever installs last wins, and losing the GPU one silently drops
        # the CUDAExecutionProvider. Upstream's installer re-runs the cuda extra as a second
        # pass for the same reason — reinstall the GPU wheel last, at the version the
        # resolver already picked, so its capi library is the survivor.
        ortgpu="$("$venv/bin/pip" show onnxruntime-gpu 2>/dev/null | sed -n 's/^Version: //p')"
        if [ -n "$ortgpu" ]; then
          "$venv/bin/pip" install --quiet --force-reinstall --no-deps "onnxruntime-gpu==$ortgpu"
        fi
        echo "$want" > "$venv/.pin"
      fi
      exec "$venv/bin/$entry" "$@"
    '';
  };

  # buildFHSEnv exposes exactly one binary, so fan the two upstream console-scripts out
  # into thin wrappers that pick the entry point via the launcher's first arg.
  nvbroadcast = pkgs.writeShellScriptBin "nvbroadcast" ''
    exec ${fhsEnv}/bin/nvbroadcast-env nvbroadcast "$@"
  '';
  nvbroadcast-vcam = pkgs.writeShellScriptBin "nvbroadcast-vcam" ''
    exec ${fhsEnv}/bin/nvbroadcast-env nvbroadcast-vcam "$@"
  '';

  # Launcher entry + icon straight from the pinned source (its Exec=nvbroadcast already
  # resolves to the wrapper above on PATH).
  desktopEntry = pkgs.runCommand "nvbroadcast-desktop" { } ''
    install -Dm644 ${src}/data/com.doczeus.NVBroadcast.desktop \
      $out/share/applications/com.doczeus.NVBroadcast.desktop
    install -Dm644 ${src}/data/icons/com.doczeus.NVBroadcast.svg \
      $out/share/icons/hicolor/scalable/apps/com.doczeus.NVBroadcast.svg
  '';
in
{
  environment.systemPackages = [ nvbroadcast nvbroadcast-vcam desktopEntry ];
}
