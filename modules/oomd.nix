{ ... }:

{
  # systemd-oomd is on by default but watches NOTHING until a slice opts in, and its only other
  # trigger is swap >90% full — useless here, since a memory livelock can leave swap mostly
  # "free" (see the zswap note in gaming.nix). Opting the user slices into PSI-based killing
  # means a runaway build/linker in a terminal gets its scope killed after sustained memory
  # pressure instead of freezing the whole session. user.slice only: system.slice would put
  # docker containers and nix-daemon builds in the blast radius.
  systemd.oomd.enableUserSlices = true;
}
