# doubletake — an AirPlay 2 mirroring SENDER (cast this desktop OUT to an Apple TV / AirPlay TV).
# Note the direction: every other AirPlay project on Linux (uxplay, RPiPlay, airplay2-receiver) is
# a *receiver*, which is the opposite of what modules/airplay.nix wants.
#
# Not in nixpkgs, and deliberately NOT an nvfetcher pin either — nvfetcher.toml is for prebuilt
# upstream binaries, whereas this is a real Go source build, so it lives here like claude-cred.nix.
#
# Pinned to a master COMMIT rather than the v0.4.0 tag on purpose: only master ships
# cmd/doubletake-test-receiver, a hardware-free AirPlay sink that lets you prove the
# capture→encode→RTSP chain locally without a TV in the loop. That splits "is my pipeline right?"
# from "does this TV's AirPlay implementation cooperate?", which is the whole debugging story for a
# receiver as quirky as a Samsung. A rev is every bit as reproducible as a tag.
#
# Pure Go, no cgo (upstream's own release target sets CGO_ENABLED=0). GStreamer is therefore NOT a
# link-time dependency: at RUNTIME doubletake shells out to gst-launch-1.0 for the capture/H.264
# pipeline, probes with gst-inspect-1.0, and calls pactl for audio. That is why the wrapper below
# has to put those on PATH *and* export the plugin path so the gst-launch CHILD process can find
# its elements. Get it wrong and the failure is a confusing "element not found" at cast time
# rather than anything the build would have caught.
{ pkgs }:
let
  inherit (pkgs) lib;

  # Elements the capture/encode pipeline needs: pipewiresrc (Wayland portal capture) lives in
  # pipewire itself, the VA-API H.264 encoder in -bad, x264 in -ugly, openh264 in -bad.
  #
  # `.out` on gstreamer is load-bearing. gst_all_1.gstreamer is multi-output and its DEFAULT is
  # `bin`, so plain interpolation yields …-gstreamer-bin/lib/gstreamer-1.0 — which holds the
  # gst-launch-1.0 binary but none of the plugins. libgstcoreelements.so (fdsink, queue, tee) is
  # in `out`, so getting this wrong loses the *core* element set while every codec plugin still
  # resolves: the pipeline then dies on `no element "fdsink"`, which reads like a missing codec.
  gstPlugins = (with pkgs.gst_all_1; [
    gstreamer.out
    gst-plugins-base
    gst-plugins-good
    gst-plugins-bad
    gst-plugins-ugly
    gst-libav
  ]) ++ [ pkgs.pipewire ];

  # Built by hand rather than with lib.makeSearchPathOutput: that helper appends its subDir
  # VERBATIM, so passing "gstreamer-1.0" yields <store>/gstreamer-1.0 and silently drops the
  # "lib/" segment. Every directory then fails to exist, GStreamer registers zero plugins, and
  # doubletake dies at cast time with "no supported GStreamer H.264 encoder is available" —
  # nothing about it looks like a path bug, so spell the full subdirectory out.
  gstPluginPath = lib.concatMapStringsSep ":" (p: "${p}/lib/gstreamer-1.0") gstPlugins;

  # pactl ships in the pulseaudio package and talks fine to pipewire-pulse; xrandr is only
  # consulted on X11 but is cheap to include and avoids a silent geometry-probe failure.
  runtimeBins = [ pkgs.gst_all_1.gstreamer pkgs.pulseaudio pkgs.xrandr ];
in
pkgs.buildGoModule rec {
  pname = "doubletake";
  # renovate: datasource=git-refs depName=omarroth/doubletake packageName=https://github.com/omarroth/doubletake currentValue=master
  version = "0.4.0-unstable-2026-08-09";

  src = pkgs.fetchFromGitHub {
    owner = "omarroth";
    repo = "doubletake";
    rev = "b95fdec6b0579817227f17e1100c00c12c4681a6";
    hash = "sha256-H5T2bFuSBJrOhHbyAgI1uhVZxyQpgOJi6ZuO+a8pbd0=";
  };

  vendorHash = "sha256-cgvY9MVGe8I3g3Ni2sGucTY6YCyPJ2YnoxxUaYfl1E4=";

  # Mirrors upstream's `all` target. doubletake-ctl drives the -daemonize mode over D-Bus;
  # doubletake-test-receiver is the local sink used to validate without a TV.
  subPackages = [
    "cmd/doubletake"
    "cmd/doubletake-ctl"
    "cmd/doubletake-test-receiver"
  ];

  ldflags = [ "-s" "-w" ];

  nativeBuildInputs = [ pkgs.makeWrapper ];

  # doubletake-ctl is a pure D-Bus client, so it needs no GStreamer wrapping — only the two
  # binaries that actually spawn a gst-launch pipeline get wrapped.
  postInstall = ''
    install -Dm644 man/man1/*.1 -t $out/share/man/man1

    for bin in doubletake doubletake-test-receiver; do
      wrapProgram $out/bin/$bin \
        --prefix PATH : ${lib.makeBinPath runtimeBins} \
        --prefix GST_PLUGIN_SYSTEM_PATH_1_0 : "${gstPluginPath}"
    done
  '';

  meta = {
    description = "AirPlay 2 mirroring sender for Linux (X11 and Wayland)";
    homepage = "https://github.com/omarroth/doubletake";
    license = lib.licenses.lgpl3Plus;
    mainProgram = "doubletake";
    platforms = lib.platforms.linux;
  };
}
