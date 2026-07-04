{ config, pkgs, lib, ... }:

# Real-time mic noise suppression — the closest open equivalent to NVIDIA Broadcast.
#
# Uses DeepFilterNet (a deep-learning speech-enhancement model), NOT vanilla RNNoise:
# RNNoise is lighter but DeepFilterNet removes far more (keyboard, fans, room) while
# keeping voice natural — i.e. actually Broadcast-tier. The `deepfilternet` package builds
# only the LADSPA plugin and bakes the DNN model into the .so, so there's no runtime model
# path to wire up — just point the filter-chain at it.
#
# This loads libpipewire-module-filter-chain in the main PipeWire daemon, which exposes a
# virtual mic "DeepFilter Noise Canceling Source" (node name `deepfilter_source`). Make it
# your DEFAULT input (wpctl set-default / pavucontrol) so apps record the denoised stream.
#
# ⚠️ When you make this the default input you MUST pin captureTarget (below). Otherwise the
# capture side follows the default source — which is now itself — creating a feedback loop /
# dead air. Pinning it to the real mic breaks the cycle. Leave captureTarget null to instead
# follow whatever the current default input is (fine when this is NOT the default source).
#
# ⚠️ PLUGIN LOOKUP IS BY NAME, NOT PATH. PipeWire's modern `spa.filter-graph` ignores an
# absolute `plugin = /nix/store/…/libdeep_filter_ladspa.so` and only searches the dirs on
# LADSPA_PATH (DeepFilterNet issue #689; pipewire gitlab work-item 5222). An abs path fails
# with "failed to load plugin '…' in '<LADSPA_PATH dirs>': No such file or directory". So:
#   1. extraLadspaPackages adds deepfilternet to the nixpkgs `pipewire-ladspa-plugins`
#      buildEnv that LADSPA_PATH points at (the supported, store-path-free way to extend it).
#   2. the node references the plugin by BARE NAME `libdeep_filter_ladspa` (no dir, no .so).
#
# Inference is pure-CPU (the plugin is built on `tract`, a Rust NN runtime — no CUDA/GPU),
# so there's nothing to wire up for NVIDIA; cost is a few % of one core.
#
# System audio → the flake (not chezmoi). Opted into by the Hyprland hosts via extraModules.
let
  cfg = config.services.deepfilterNoiseSuppression;
in
{
  options.services.deepfilterNoiseSuppression.captureTarget = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    example = "alsa_input.usb-Focusrite_Scarlett_Solo_USB_XXXX-00.HiFi__Mic1__source";
    description = ''
      `node.name` of the real microphone to pin the DeepFilter capture to. null (default)
      makes the filter follow the system default input instead. The value carries the device
      serial, so it is host-specific — set it per-host in hosts/<name>/default.nix, NOT in
      this shared module (the laptop has no Scarlett, so a hardcoded name would fail to link
      there). Required whenever deepfilter_source itself is the default input (see header).
    '';
  };

  config = {
    # Put deepfilternet's lib/ladspa on PipeWire's LADSPA_PATH (see header note #1).
    services.pipewire.extraLadspaPackages = [ pkgs.deepfilternet ];

    services.pipewire.extraConfig.pipewire."99-deepfilter-source" = {
      "context.modules" = [
        {
          name = "libpipewire-module-filter-chain";
          # nofail is CRITICAL: a filter-chain in the main daemon config is otherwise a
          # *mandatory* module — if the LADSPA plugin fails to load, PipeWire aborts (exit
          # 254) and takes ALL audio (pulse + wireplumber) down with it. nofail downgrades a
          # plugin-load failure to a logged warning so the rest of the audio stack still comes up.
          flags = [ "nofail" ];
          args = {
            "node.description" = "DeepFilter Noise Canceling Source";
            "media.name" = "DeepFilter Noise Canceling Source";
            "filter.graph" = {
              nodes = [
                {
                  type = "ladspa";
                  name = "DeepFilter Mono";
                  plugin = "libdeep_filter_ladspa"; # bare name — resolved via LADSPA_PATH (see header)
                  label = "deep_filter_mono";
                  # 100 dB = remove essentially all detected noise (most Broadcast-like).
                  # Drop to ~30–40 if aggressive suppression adds watery/garbled artifacts.
                  control = { "Attenuation Limit (dB)" = 100; };
                }
              ];
            };
            # DeepFilterNet operates on 48 kHz mono — match it on both ends.
            "audio.rate" = 48000;
            "audio.position" = [ "MONO" ];
            "capture.props" = {
              "node.name" = "capture.deepfilter_source";
              "node.passive" = true; # only pulls from the real mic while an app is recording
            } // lib.optionalAttrs (cfg.captureTarget != null) {
              # Pin the input to a specific real mic (see captureTarget option + header).
              "target.object" = cfg.captureTarget;
            };
            "playback.props" = {
              "node.name" = "deepfilter_source";
              "media.class" = "Audio/Source"; # makes it show up as a selectable microphone
            };
          };
        }
      ];
    };
  };
}
