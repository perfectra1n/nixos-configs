# idevice-wifi-sync — sets/reads the iOS lockdown key that permits Wi-Fi connections.
# One definition, two consumers: the flake's packages output (so `nix flake check` actually
# COMPILES it every CI run, and `nix run .#idevice-wifi-sync` works) and modules/ios-backup.nix
# (installed on the host that pairs the phones).
#
# Why C rather than reaching for pymobiledevice3: the whole job is one lockdownd_set_value()
# call against a library that is ALREADY in this host's closure (libimobiledevice, pulled in
# by idevicebackup2 and usbmuxd2). pymobiledevice3 would reimplement the entire lockdown
# protocol in Python for that one call, and its pyimg4 dependency is genuinely broken against
# nixpkgs' asn1 3.x — not conservatively marked, it fails decoding at runtime. See main.c's
# header for why libimobiledevice's own tools can't do this.
{ pkgs }:
pkgs.runCommandCC "idevice-wifi-sync"
{
  nativeBuildInputs = [ pkgs.pkg-config ];
  buildInputs = [ pkgs.libimobiledevice pkgs.libplist ];
  meta = {
    description = "Enable/disable/report iOS Wi-Fi lockdown connections (EnableWifiConnections)";
    mainProgram = "idevice-wifi-sync";
    platforms = pkgs.lib.platforms.linux;
  };
} ''
  mkdir -p $out/bin

  # Copy in and compile a RELATIVE filename rather than passing the store path to $CC.
  # Compiling ${./idevice-wifi-sync.c} directly leaves the .c itself registered as a runtime
  # reference, so the bare source file rides along in every system closure that installs this.
  cp ${./idevice-wifi-sync.c} idevice-wifi-sync.c

  # -Werror: 200 lines against a stable C API — no reason to tolerate a warning, and CI
  # compiling it on every run is what makes that a real gate rather than a good intention.
  # (It has already earned this: it caught nanosleep needing _POSIX_C_SOURCE under -std=c11.)
  $CC -O2 -std=c11 -Wall -Wextra -Werror \
    idevice-wifi-sync.c \
    $(pkg-config --cflags --libs libimobiledevice-1.0 libplist-2.0) \
    -o $out/bin/idevice-wifi-sync

  # Smoke test: --help must run and exit 0. Catches a link-time/runtime symbol problem that
  # a clean compile wouldn't — the binary is useless if it can't start.
  $out/bin/idevice-wifi-sync --help >/dev/null
''
