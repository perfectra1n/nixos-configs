{ config, pkgs, lib, ... }:

# Printing + scanning for the graphical hosts. There was no printing stack in this flake at all
# before now, and the symptom of that is silent rather than loud: with no cupsd running, every
# GTK/Qt/Electron print dialog (Firefox, Chromium, Nemo, the lot) opens listing ZERO destinations,
# because they all enumerate printers by speaking IPP to localhost:631. Nothing errors, nothing
# logs — the dialog is just empty. So `services.printing.enable` is what makes printing *exist*,
# not merely what makes a specific printer work.
#
# Headless `server` is excluded by construction: this module is opted into via `graphical` in
# flake.nix, so only desktop + laptop get it.
{
  # ── CUPS ───────────────────────────────────────────────────────────────────────────────────
  services.printing = {
    enable = true;

    # Vendor drivers, i.e. insurance for hardware that ISN'T driverless. Anything made in roughly
    # the last decade speaks IPP Everywhere / AirPrint, where CUPS interrogates the printer for
    # its capabilities and synthesizes the PPD itself — no entry below is consulted at all in that
    # case. Kept broad anyway since we don't know what gets plugged in.
    #   Why this list and not environment.systemPackages: the module collects these into a
    #   `cups-progs` buildEnv and symlinks their PPDs + filter binaries into /var/lib/cups/path,
    #   which is the ONLY directory cupsd searches. A driver installed system-wide is invisible
    #   to CUPS — it must come through this option.
    #   Cost, if you ever want to trim: the whole stack in this module is ~760 MiB download /
    #   2.3 GiB unpacked on a cold store. There is no single hog to delete — measured alone,
    #   foomatic-db-ppds is 154 MiB, hplip 143, cnijfilter2 137, and even system-config-printer
    #   134 (it drags in PyQt5). Meaningful savings mean dropping several vendors you don't own,
    #   not one entry.
    drivers = with pkgs; [
      gutenprint # generic FOSS driver, ~700 models across most vendors — the broadest single net
      gutenprintBin # Gutenprint's binary-only PPDs (Epson/Canon models the FOSS set doesn't cover)
      foomatic-db-ppds # the full OpenPrinting PPD database — widest coverage of the lot
      brlaser # Brother mono laser (HL-/DCP- line)
      brgenml1lpr # Brother "generic ML1" fallback for models brlaser doesn't claim
      hplip # HP, all of it — also ships the SANE backend reused in hardware.sane below.
      # Swap to hplipWithPlugin if a specific HP laser demands the proprietary
      # binary plugin; unfree is already allowed, so it's a one-word change.
      cnijfilter2 # Canon inkjet (PIXMA / MAXIFY)
      epson-escpr # Epson ESC/P-R
      epson-escpr2 # Epson ESC/P-R v2 (newer EcoTank / WorkForce)
      splix # Samsung + Xerox QPDL
      samsung-unified-linux-driver # Samsung's own unified driver, for what splix misses
      postscript-lexmark # Lexmark PostScript PPDs
    ];

    # OFF, deliberately — it auto-discovers network printers into local queues (CUPS 2.4 dropped
    # its own remote browsing, so that job moved to this daemon), but on the HP Color LaserJet
    # M452dw here it actively broke printing:
    #   The printer was ALREADY added by hand as `dnssd://…_ipp._tcp…` — plain IPP on 631, no TLS.
    #   cups-browsed then built a SECOND queue for the same device, `implicitclass://…`, and made
    #   it the default. That backend talks to the printer on :443, where CUPS validates the
    #   certificate — and this model ships a self-signed cert valid 2016-01-01 → 2026-01-01, i.e.
    #   expired. Every job hit `cups-pki-expired`, the ipp backend exited status 4, and cupsd
    #   stopped the queue ("Job processing failed"), parking the job on a paused queue while the
    #   healthy duplicate sat idle next to it — which makes the web UI look like jobs vanished.
    # So the convenience cost a working printer. Add network printers manually instead
    # (system-config-printer); it's a one-time action, and the queue it creates picks the plain
    # _ipp._tcp path that never involves a certificate.
    #   Re-enable only if a printer ever needs to be found automatically AND its TLS cert is
    #   valid — or fix the cert on the device (HP EWS → Networking → Security → Certificates).
    browsed.enable = false;

    # Virtual "Print to PDF" queue, output lands in ~/cups-pdf. Costs nothing and covers the case
    # where an app's own "Save as PDF" is missing or mangles the layout.
    cups-pdf.enable = true;

    # Deliberately NOT set, because the module defaults are already right: startWhenNeeded (socket
    # activation, so cupsd isn't resident), webInterface (the admin UI at http://localhost:631 —
    # the always-available way to add a queue), and defaultShared = false (we're a client, not a
    # print server; nothing gets re-advertised to the LAN).
  };

  # Driverless over USB. Modern multifunction units expose the very same IPP + eSCL stack on a USB
  # interface that they do over the network; ipp-usb bridges it to a localhost port so CUPS and
  # SANE treat a USB printer exactly like a network one — no PPD, no vendor driver, no queue setup.
  # It flips services.printing.enable and hardware.sane.enable to mkDefault true; both are set
  # explicitly here regardless, so this stays a pure addition.
  services.ipp-usb.enable = true;

  # mDNS. Still REQUIRED even with browsed off above, and not merely for discovery: a manually
  # added network queue keeps a `dnssd://…local/` device URI, so Avahi is what resolves the
  # printer on every single print job. Drop this and an already-working printer stops printing.
  # nssmdns4 is the load-bearing half, wiring mdns4_minimal into /etc/nsswitch.conf so that
  # `something.local` resolves at all. openFirewall is a no-op while the global
  # firewall is off (modules/common.nix) but keeps this honest if that ever flips.
  #   laptop already gets an identical block from modules/miracast.nix (Chromecast discovery).
  #   That's fine rather than a conflict: these are equal bool definitions, which merge cleanly.
  #   It's declared here too so desktop — which has no miracast.nix — isn't quietly left unable to
  #   see any network printer.
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    openFirewall = true;
  };

  # ── Scanning ───────────────────────────────────────────────────────────────────────────────
  # Separate subsystem from printing: a multifunction device needs both, and neither implies the
  # other. No `scanner`/`lp` group membership is added on purpose — the sane module's udev rules
  # tag scanners with `uaccess`, so whoever is physically logged in already has access, and the
  # groups only matter for the saned network daemon (not enabled).
  hardware.sane = {
    enable = true;
    extraBackends = [
      pkgs.sane-airscan # driverless scanning (eSCL / WSD) — the scanner half of AirPrint
      pkgs.hplip # HP multifunction scanning; the same package is a CUPS driver above
    ];
  };

  environment.systemPackages = with pkgs; [
    system-config-printer # GTK app to add/manage queues. Earns its place because Hyprland has no
    # settings shell to host a printer panel; the alternative is localhost:631.
    simple-scan # GTK scanning frontend, matching the GTK stack (Nemo, etc.).
    # Not skanlite — that one is KDE-only in nixpkgs.
  ];
}
