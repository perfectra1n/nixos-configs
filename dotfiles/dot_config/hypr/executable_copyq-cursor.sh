#!/usr/bin/env bash
# Toggle CopyQ; when showing, anchor it to the mouse cursor, opening toward the screen
# interior so it never spills off the edge.
#
# Why a script instead of a windowrule: Wayland apps can't position themselves, and
# CopyQ reuses one persistent window — so Hyprland's `move cursor` windowrule only
# fires on the first map and never again on show/toggle, leaving it centered on the
# focused monitor. So: show it, then move it to the cursor with a dispatcher.

class="com.github.hluk.copyq"

# Already visible? This press hides it (toggle off).
vis=$(copyq visible 2>/dev/null)
if [ "$vis" = "true" ] || [ "$vis" = "1" ]; then
    copyq hide
    exit 0
fi

copyq show

# Wait (bounded) until Hyprland reports the window.
for _ in $(seq 1 80); do
    hyprctl clients -j 2>/dev/null | grep -q "$class" && break
done

# Anchor to the cursor: pick the window corner that points into the screen interior
# (left half -> open right, top half -> open down, etc.), then clamp inside the monitor.
python3 - "$class" <<'PY'
import json, subprocess, sys

cls = sys.argv[1]

def hc(*args):
    return subprocess.run(["hyprctl", *args], capture_output=True, text=True).stdout

clients = json.loads(hc("clients", "-j") or "[]")
win = next((c for c in clients if cls in c.get("class", "")), None)
if win is None:
    sys.exit(0)
w, h = win["size"]
addr = win["address"]

mons = json.loads(hc("monitors", "-j") or "[]")
mon = next((m for m in mons if m.get("focused")), mons[0] if mons else None)
if mon is None:
    sys.exit(0)
scale = mon.get("scale") or 1
mx, my = mon["x"], mon["y"]
mw, mh = round(mon["width"] / scale), round(mon["height"] / scale)
if mon.get("transform", 0) in (1, 3, 5, 7):   # 90/270 rotations swap logical w/h
    mw, mh = mh, mw

cx, cy = (int(v) for v in hc("cursorpos").strip().replace(" ", "").split(","))

# corner facing the screen interior
x = cx if (cx - mx) < mw / 2 else cx - w
y = cy if (cy - my) < mh / 2 else cy - h
# safety clamp so it's always fully on the monitor
x = max(mx, min(x, mx + mw - w))
y = max(my, min(y, my + mh - h))

hc("dispatch", "movewindowpixel", f"exact {x} {y},address:{addr}")
PY
