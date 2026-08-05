{ inputs, ... }:

# Cleanroom — webcam + microphone effects (background blur/replace, DeepFilterNet denoise) as a
# PipeWire client + v4l2loopback producer, with a GUI and `cleanroom-ctl`. Vendor-neutral: matting
# runs on wgpu/Vulkan, so the AMD laptop gets a blurred webcam for the first time.
#
# Ours (github.com/perfectra1n/cleanroom) — bugs here are fixable rather than reportable, which is
# what makes it acceptable to put alpha software on the critical path of every video call.
#
# Replaces THREE modules retired alongside this one. Each retirement is the point of the swap:
#
#   modules/nvbroadcast.nix       CUDA-only, therefore desktop-only, and not a derivation at all —
#                                 an FHS venv that pip-installed ~3 GB of wheels at first run.
#                                 Cleanroom is a real closure and covers both GPUs.
#
#   modules/virtual-camera.nix    pinned /dev/video10 (`video_nr=10`) because NV Broadcast
#                                 hardcoded that path. Cleanroom instead selects a FREE loopback
#                                 node at runtime, which is exactly what lets it coexist with OBS's
#                                 virtual camera instead of fighting it for one node. ⚠️ Do NOT
#                                 reintroduce a video_nr pin — it defeats that selection.
#
#   modules/noise-suppression.nix a libpipewire-module-filter-chain declared in PipeWire's DAEMON
#                                 config, which makes it a *mandatory* module: a failed LADSPA load
#                                 aborted PipeWire (exit 254) and took ALL audio with it — the sole
#                                 reason that module needed `nofail`. Cleanroom is a PipeWire
#                                 *client*, so the whole failure mode is gone structurally rather
#                                 than downgraded to a warning.
#
# ⚠️ Weights are NOT declarative, deliberately. DeepFilterNet licenses "all code in this
# repository"; weights are not code, and the upstream issue asking for a weights licence has gone
# unanswered since July 2026 on a repo dormant since Oct 2024. This repo is public, so we do not
# bake in a URL+hash for a blob whose licence is unresolved. Run `cleanroom-ctl fetch-models` ONCE
# per host. Until then the microphone is a *reported* passthrough — it tells you — not a silent one.
#
# ⚠️ The denoised mic is now `cleanroom_mic`, NOT `deepfilter_source`. DMS pins a preferred input
# in dotfiles/dot_config/DankMaterialShell/settings.json, which is chezmoi-owned — the flake must
# never write it (a collision there fails home-manager-<user>.service and silently freezes ALL HM
# file updates). Pick the new node in DMS, then `chezmoi add` to re-capture the snapshot.
#
# releaseCamera defaults to true: a WirePlumber rule marks the webcam `node.disabled` so cleanroom
# can open it directly and get MJPG. PipeWire's v4l2 node only ever advertised YUY2, and raw 4:2:2
# at 1080p saturates USB 2 (~5 fps) — so capturing *through* PipeWire was never viable. Consequence
# worth knowing: the raw camera stops being independently selectable; apps see the processed node.
#
# Defaults otherwise kept as upstream ships them — loopbackDevices = 2 (one for cleanroom, one left
# spare for OBS) and the `~.*(Webcam|Camera).*` nick regex, which matches the desktop's C922 and the
# laptop's built-in camera alike. Per-host tuning belongs in hosts/<name>/default.nix if that
# changes; nothing needs it today, which is why the Scarlett-serial pin the old filter-chain
# required could be deleted outright (a PipeWire client picks its source at runtime).
{
  imports = [ inputs.cleanroom.nixosModules.cleanroom ];

  services.cleanroom.enable = true;
}
