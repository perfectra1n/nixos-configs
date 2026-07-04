# Idle-inhibit watchdog (the DMS sleep-pattern daemon)

Why the monitors on the graphical hosts reliably DPMS-off when idle, even though apps keep
leaking "keep the screen awake" requests. This is the reasoning behind
`dms-idle-inhibit-watchdog`; the root [`CLAUDE.md`](../CLAUDE.md) states the rules, this
explains the *why*.

## TL;DR

- A small userspace **idle-policy daemon** — *not* a hardware/systemd watchdog (nothing to do
  with `/dev/watchdog` or `WatchdogSec`). It "watches" for a stuck-awake screen and corrects it.
- Lives as a single `writeShellApplication` **`let`-binding** in
  [`modules/desktop-apps.nix`](../modules/desktop-apps.nix), run by the **`dms-idle-watchdog`
  systemd user service** defined in the same module (`Restart=on-failure`, single instance,
  restarts on rebuild via sd-switch).
- **Watch it:** `journalctl --user -t dms-idle-watchdog` (silent until an inhibit is held);
  `systemctl --user status dms-idle-watchdog` for liveness.

## The problem it solves

DMS ([DankMaterialShell](../modules/hyprland.nix)) owns the whole idle pipeline — monitor-off,
lock, suspend — and explicitly replaces `swayidle`/`hypridle` (which is why there is **no
hypridle** in `autostart.conf`). Part of that pipeline: DMS honors every
`org.freedesktop.ScreenSaver` inhibit by mirroring it into a **compositor-level Wayland
idle-inhibitor** that blocks DPMS for *everything*.

That's correct behavior — until an app **leaks** the inhibit: takes it and never releases it
when nothing needs the screen on. Real offenders seen here:

| App | Leak |
|-----|------|
| Steam | `gldriverquery`/`reaper` holds an inhibit after a game exits |
| teams-for-linux | keeps the call inhibit after a call ends |
| Chromium / Electron | wake-locks that outlive the tab that took them |

A leaked inhibit is **byte-for-byte indistinguishable** from a legitimate one. So chasing every
misbehaving app (an unbounded blocklist) is the wrong model.

## The design: watch positive signals, not negative ones

Instead of asking "which app is lying?", the watchdog asks **"is anything legitimate actually
happening right now?"** — a small, *stable* set of positive signals:

| Signal | How it's detected | Why this way |
|--------|-------------------|--------------|
| **Game** | `pgrep -f 'reaper SteamLaunch'` or `gamemoded -s` says active | Covers Steam games + gamemode-wrapped launches |
| **Media** | `playerctl -a status` reports `Playing` | MPRIS-based: a *muted* video still counts, a *paused* one doesn't. Output is captured *before* grepping so one misbehaving player can't hide another's `Playing` under pipefail |
| **Audio out** | a `pactl` sink-input with `Corked: no` | Something is actually producing sound |
| **Mic in** | a `pactl` source-output with `Corked: no` | A call is capturing the mic |

Every probe is **three-state** — `y` / `n` / `u`(nknown) — and the failure semantics are the
point: a probe that can't answer (pactl with the audio server down, playerctl erroring
mid-listing) reports `u`, **never** `n`. Any `y` → hold. No `y` but any `u` → **hold with a
WARNING** — the watchdog only releases on positive certainty of silence. The old boolean probes
turned every tool failure into a vote for release, exactly the wrong bias.

When DMS reports an **external** inhibit held while every signal is a certain `n` — sustained
across `NEED` consecutive checks to bridge brief gaps (a track change, an MPRIS blip) — the
watchdog removes the leaked inhibits at the source (next section).

### Subtleties worth knowing

- **The always-uncorked exclusion (`EXCLUDE_STREAMS`).** `linux-wallpaperengine` (the DMS
  wallpaper plugin) holds its PipeWire output streams open and **uncorked 24/7**, even for
  silent wallpapers. A naive "any `Corked: no` anywhere" check would therefore be *always
  true*, and a leaked inhibit would be held forever. So both `pactl` probes inspect streams
  **per-stream** and skip anything matching the `EXCLUDE_STREAMS` regex — applied to
  sink-inputs *and* source-outputs so a future always-uncorked capture stream can't pin the
  mic signal the same way. See [[wallpaperengine-audio-defeats-idle-watchdog]].
- **The manual coffee-cup hold is sacred.** A deliberate "Keep system awake" toggle produces an
  inhibit whose reason is *not* `"External app"`. The watchdog only ever clears inhibits whose
  reason starts with `External app` — a manual hold is **never** touched. (`dms ipc inhibit
  reason ""` is a pure getter; a *non-empty* argument would SET the reason — never change that
  `""`.)
- **One known blind spot:** a manual hold taken *while* a leak is already active is
  indistinguishable from the leak — DMS collapses both into one bit + one reason string
  (`SessionService.idleInhibited` / `inhibitReason`) — and gets released with it. Re-toggling
  the coffee cup afterwards sticks (the reason is then `Keep system awake`).

## Releasing at the source: the UnInhibit sweep

The watchdog used to run `dms ipc inhibit disable`. That was subtly wrong — it clears only
**DMS's mirror bit**, not the leaked D-Bus cookie inside the danklinux daemon (the `dms run`
backend that owns `org.freedesktop.ScreenSaver`). Verified consequences (DMS 1.4.6 source,
`IdleService.qml` + `SessionService.qml` + `core/internal/server/freedesktop/screensaver.go`):

- The daemon's `inhibited` bool stays **pinned true** by the leaked cookie, and DMS reacts
  only to **edges** of that bool — so after a mirror-clear, every *later legitimate* external
  inhibit (a new Teams call, a Chromium video) was **silently never honored** until the
  leaking app exited.
- DMS's disable path never resets `inhibitReason`, so the reason stayed `"External app: X"` —
  a later manual coffee-cup hold surfaced with that stale reason and would have been wrongly
  released.

Now the watchdog removes the cookies from the daemon itself, via its **public D-Bus API**:

1. **Probe:** call `Inhibit("dms-idle-watchdog", "leak sweep ceiling probe")` — cookies are
   sequential (`atomic.AddUint32`), so the returned cookie is the **ceiling**: every existing
   inhibit has a cookie at or below it. (The probe reason must never contain "audio": the
   daemon drops audio-only inhibits.)
2. **Sweep:** `UnInhibit(c)` for `c = 1..ceiling` — the probe plus every pre-existing cookie,
   all of which the loop *just judged leaked* (the identical policy decision the old
   mirror-disable applied, executed at the root). `UnInhibit` is not sender-validated, and
   unknown cookies are no-ops.
3. **Race-free by construction:** an inhibit taken *after* the probe gets a *higher* cookie —
   the sweep can never touch it.

Emptying the set makes the daemon's bool **edge**, so DMS resets `idleInhibited` *and* the
reason natively — no pinned bool, no stale reason. The watchdog then re-reads the status:
`released leaked inhibit(s) at the source` on success, or `still held` when an app re-took an
inhibit mid-sweep (wake-lock cycling — the journal now names it via the reason string). If the
sweep itself fails (busctl error, garbled reply), it falls back to the old
`dms ipc inhibit disable` **plus** an explicit `reason "Keep system awake"` reset to close the
stale-reason trap on that path too.

Other daemon facts worth remembering: it reaps inhibitors when their D-Bus peer disconnects
(leaks only survive while the leaking *process* lives — and a leak *simulator* must hold its
bus connection open), and it drops audio-only inhibit reasons at intake.

## How it decides — the poll loop

```
every POLL seconds (30s):
  if wall clock jumped > 2*POLL:          # suspend/resume — pre-suspend counts are stale
      stuck = 0
  status = dms ipc inhibit status         # exact match on "is enabled" (DMSShellIPC.qml)
  if not enabled:                         # idle/DPMS working fine
      stuck = 0; stay silent; continue    #   → never spams the journal

  # inhibit IS held — narrate every poll from here, reason (= WHO) in every line
  g,m,a,i = probe game / media / audio / mic   (each y|n|u, evaluated once)
  reason  = dms ipc inhibit reason ""
  if reason is not "External app…":       # manual hold or unexpected → leave it
      stuck = 0; continue
  if any probe == y:                      # something legit is happening → hold
      stuck = 0; continue
  if any probe == u:                      # can't be CERTAIN of silence → hold + WARNING
      stuck = 0; continue

  stuck += 1                              # external + certainly nothing playing
  if stuck >= NEED (2):                   # ~POLL*NEED = ~60s grace
      UnInhibit sweep (fallback: mirror disable + reason reset)
      verify + log outcome; stuck = 0
```

Tunables (top of the script): `POLL=30` (seconds between checks) and `NEED=2` (consecutive
"stuck" checks before releasing → roughly a 60-second grace window).

### Fail-safes

- Waits for DMS's IPC socket at startup (`until dms_ipc inhibit status …; do sleep 5; done`) —
  the socket isn't up the instant the session starts, and this keeps the unit inert on
  TTY/SSH logins with no Hyprland session.
- Every `dms ipc` call runs under `timeout 10` (a wedged quickshell becomes a failed probe,
  not a hung daemon that `Restart=` can't fix); `busctl` calls carry `--timeout=10`.
- If `dms` is down, the reason is unexpected, a signal is active, **or any probe can't
  answer** → it does **nothing**. The default is always "leave the inhibit alone."
- `DBUS_SESSION_BUS_ADDRESS` falls back to `/run/user/$UID/bus` if unset (glib tools —
  playerctl, gamemode's client — have no built-in fallback, unlike libdbus).
- A wall-clock jump > `2*POLL` (suspend/resume) resets the stuck counter.
- The unit restarts on failure (15s) — a SIGPIPE from a journald restart is a blip, not a
  permanent silent death like under the old `exec-once`.

## Logging behavior (deliberately quiet)

The daemon is **silent whenever no inhibit is held** — i.e. whenever idle/DPMS is working. It only
logs once an inhibit is *enabled*, because that's the exact window where the screen refuses to
sleep; there it narrates every poll with the full `game=… media=… audio=… mic=…` breakdown **and
the reason string**, which carries the leaking app's name(s) (`External app: Steam, …`) — so a
release is auditable after the fact, including *who* leaked. (Caveat: DMS 1.4.6 often shows
`External app: unknown` for the *first* inhibit — an upstream ordering bug in `DMSService.qml`,
which assigns the `screensaverInhibited` bool before the `screensaverInhibitors` list, so the
edge handler reads a still-empty list. The gate still works; only the name is lost.)

**Debugging corollary — the silent-but-stuck case.** If the screen is stuck ON but
`journalctl --user -t dms-idle-watchdog` is *silent*, the inhibitor is **invisible to DMS**: it's a
compositor-level Wayland idle-inhibitor on an app's own surface (a Chromium/Electron tab, say), not
a `ScreenSaver` D-Bus inhibit. No ScreenSaver cookie exists to sweep — it needs a different fix.
This is the key diagnostic from [[idle-inhibit-watchdog-no-app-list]]. See also
[[dms-monitors-wont-sleep-steam-inhibit]].

## Where everything lives

| Piece | Location |
|-------|----------|
| Daemon definition (`writeShellApplication`) | [`modules/desktop-apps.nix`](../modules/desktop-apps.nix) — `dms-idle-inhibit-watchdog` `let`-binding |
| Supervision | same file, `systemd.user.services.dms-idle-watchdog` (`Restart=on-failure`, `WantedBy=default.target`) |
| Installed into the profile | same file, in the `home.packages` list (manual debug runs only) |
| Runtime deps | `coreutils procps gamemode playerctl pulseaudio gnugrep gawk systemd` (via `runtimeInputs`) |
| Hosts | desktop + laptop (both import `modules/desktop-apps.nix`) |

### Why a systemd user service (and why `default.target`)

`graphical-session.target` is **inactive** under Hyprland+DMS — the reason everything *else* in
this module is `exec-once`. But the watchdog needs supervision (`exec-once` gave it none: one
SIGPIPE from its old `systemd-cat` pipe and it was dead until re-login), and verified live, the
user manager's activation environment carries the session PATH (incl.
`/run/current-system/sw/bin`, where `dms` lives), `DBUS_SESSION_BUS_ADDRESS`, and
`WAYLAND_DISPLAY` — so a `default.target`-bound unit works fine, and the startup socket-wait
makes an early start inert. Bonus over `exec-once`: `systemd.user.startServices` defaults to
sd-switch, so the unit (and therefore the script) restarts on `nixos-rebuild switch` — no more
re-login after changes.

## Operating it

```sh
# Liveness + decisions (silent unless an inhibit is currently held)
systemctl --user status dms-idle-watchdog
journalctl --user -t dms-idle-watchdog -f

# Inspect the state the watchdog acts on
dms ipc inhibit status      # "Idle inhibit is enabled" / "…disabled"
dms ipc inhibit reason ""   # "External app: <names>" vs a manual "Keep system awake"

# Simulate a leak end-to-end (must HOLD the bus connection — the daemon reaps
# inhibitors on peer disconnect, so one-shot `gdbus call` won't stay leaked):
nix shell nixpkgs#python3 nixpkgs#python3Packages.dbus-python -c python3 -c \
 'import dbus,time; b=dbus.SessionBus(); o=b.get_object("org.freedesktop.ScreenSaver","/org/freedesktop/ScreenSaver"); print(o.Inhibit("leak-test","simulated leak",dbus_interface="org.freedesktop.ScreenSaver")); time.sleep(3600)'
# With nothing playing: journal shows stuck 1/2 → 2/2 →
# "released leaked inhibit(s) at the source (was: External app: leak-test)" within ~60–90s.
# With audio playing: "holding … audio=y" every 30s, no release.
```

Set the actual monitor-off timeout in **DMS Settings → Power & Sleep**
(`acMonitorTimeout`/`batteryMonitorTimeout`, in seconds) — the watchdog only removes *blockers* to
that timeout, it doesn't set the timeout itself.

## Related

- [[dms-monitors-wont-sleep-steam-inhibit]] — the original Steam-leak diagnosis.
- [[wallpaperengine-audio-defeats-idle-watchdog]] — why the per-stream audio check excludes wallpaper-engine.
- [[idle-inhibit-watchdog-no-app-list]] — the watchdog is generic; a silent journal + stuck screen means a Wayland-surface inhibitor.
- [architecture.md](architecture.md) — the chezmoi boundary and why the flake owns `autostart.conf`.
