-- Hyprland config (Lua — hyprlang's hyprland.conf is deprecated since 0.55 and slated for removal).
-- https://wiki.hypr.land/Configuring/  ·  API stubs: <hyprland pkg>/share/hypr/stubs/hl.meta.lua
-- Validate offline before reloading:  Hyprland --verify-config -c ~/.config/hypr/hyprland.lua
--
-- Module layout (require() resolves relative to ~/.config/hypr):
--   nix.*  — flake-owned per-host fragments (modules/{nvidia,amd}.nix, hosts/<name>/default.nix,
--            modules/desktop-apps.nix). Host-specific truth; never edit them here.
--   dms.*  — DankMaterialShell-generated (matugen colors, the DMS keybind editor's binds).
--
-- ⚠️ Lua mode changes hyprctl too: `hyprctl dispatch X` is now `hl.dispatch(X)` (legacy strings
-- like `dispatch workspace 3` FAIL), and `hyprctl keyword` is refused outright — use
-- `hyprctl eval '<lua>'`. That's why the old hyprsome / stack-*.sh / hdr-toggle.sh helpers are
-- gone: they spoke legacy IPC, so they live below as native Lua instead.

-- Flake-owned fragments (GPU env, monitor layout, input, autostart) — keep these first.
require("nix.gpu")
local monitors = require("nix.monitors") -- returns its spec list; the HDR toggle below reads it
require("nix.input")
require("nix.autostart")

-- A module that may legitimately be absent (DMS writes its files lazily). Only a MISSING file is
-- skipped — an error inside one that exists still surfaces as a config error.
local function require_optional(name)
    if package.searchpath(name, package.path) then
        return require(name)
    end
end

local DIRS = { "l", "r", "u", "d" }

-- Don't auto-convert SDR fullscreen apps to HDR. With the Alienware in HDR mode, auto-HDR
-- inverse-tone-maps SDR games (e.g. Space Marine 2) into PQ range, lifting blacks
-- to grey and over-brightening — but only in fullscreen. Desktop HDR stays on.
hl.config({ render = { cm_auto_hdr = 0 } })

-- NOTE: do NOT add static workspace→monitor rules — the per-monitor workspace binds below
-- namespace workspaces by monitor id (id 0 -> ws 1-10, id 1 -> ws 11-20). Static rules fight
-- that scheme; the primary monitor earns id 0 by being on the lowest-numbered connected port.
-- The "focus the primary at login" hook lives in nix.monitors, where it can name the panel by
-- `desc:` — a monitor identity is host-specific and has no business in this host-agnostic file.

-- No Hyprland plugins right now. hyprsplit was dropped: its nixpkgs C++ build is broken against
-- Hyprland 0.55 (nixpkgs#524892). Re-add via Nix once fixed — never via hyprpm, which compiles
-- at runtime and fights the immutable store.

-----------------------------
---- ENVIRONMENT VARIABLES ----
-----------------------------
-- GPU env (nvidia/amd) and the no_hardware_cursors workaround live in the flake-owned nix.gpu.
-- Only host-agnostic Wayland env stays here.

hl.env("XDG_SESSION_TYPE", "wayland")
hl.env("ENABLE_GAMESCOPE_WSI", "1")
hl.env("SDL_VIDEODRIVER", "wayland")
-- Run Electron apps (Discord, VSCode, …) natively on Wayland instead of XWayland,
-- so they get proper fractional scaling (sharp AND correct size) — sidesteps the
-- force_zero_scaling shrink. "auto" falls back to X11 where there's no Wayland.
hl.env("ELECTRON_OZONE_PLATFORM_HINT", "auto")

-----------------
---- THEMING ----
-----------------

hl.env("GTK_THEME", "Adwaita:dark")
hl.env("QT_QPA_PLATFORM", "wayland")
-- NO QT_QPA_PLATFORMTHEME / QT_STYLE_OVERRIDE here — the flake owns Qt theming (home/gui.nix
-- `qt` block → hm-session-vars: platformtheme=kde, style=breeze). hl.env() values are exported
-- to systemd/D-Bus by Hyprland and OUTRANK hm-session-vars, so a stale `qt5ct` here once
-- silently disabled plasma-integration for every Qt app (qt5ct has no Qt6 plugin, so Qt fell
-- back to its generic theme and a LIGHT default palette): Dolphin then painted black text and
-- white alternate rows on its dark view until a colour scheme was re-picked by hand.
hl.env("XCURSOR_THEME", "Posy_Cursor")
hl.env("XCURSOR_SIZE", "24")

---------------------
---- MY PROGRAMS ----
---------------------

local terminal    = "kitty"
-- KDE/Qt. Installed via home/gui.nix along with kio-extras (Trash/network) and ark (archive
-- context menu). Nautilus stays installed as the GTK fallback.
local fileManager = "dolphin"

-----------------------
---- LOOK AND FEEL ----
-----------------------

hl.config({
    general = {
        gaps_in  = 5,
        gaps_out = 5,

        border_size = 4, -- komorebi border_width

        -- Border COLORS are owned by DMS (dms.colors, required near the bottom) plus the
        -- komorebi-green accent layered on after it — see the end of this file.

        -- Set to true to enable resizing windows by clicking and dragging on borders and gaps
        resize_on_border = false,

        -- Tearing vs VRR are alternative latency strategies — for the 240Hz G-Sync OLED prefer
        -- VRR (misc.vrr) and leave this false. Set true only if you choose the tearing path
        -- instead (then also uncomment the gamescope `immediate` window rule below).
        allow_tearing = false,

        layout = "dwindle",
    },

    decoration = {
        rounding       = 10,
        rounding_power = 2,

        active_opacity   = 1.0,
        inactive_opacity = 1.0,

        shadow = {
            enabled      = true,
            range        = 4,
            render_power = 3,
            color        = "rgba(1a1a1aee)",
        },

        blur = {
            enabled  = true,
            size     = 3,
            passes   = 1,
            vibrancy = 0.1696,
        },
    },

    animations = { enabled = true },

    dwindle = {
        -- `pseudotile` option removed in Hyprland 0.55 — toggle per-window via the
        -- pseudo dispatcher (bound to mainMod + P below).
        preserve_split = true,
    },

    master = { new_status = "master" },

    -- Groups = komorebi-style stacks (tabbed). COLORS are owned by DMS — dms.colors sets every
    -- group col.* to the live primary, and a komorebi-green accent is layered back on AFTER it
    -- at the end of this file. So this block carries only the NON-color STYLE of the tab bar.
    group = {
        groupbar = {
            enabled           = true,
            font_family       = "FiraCode Nerd Font",
            font_size         = 12,     -- a touch bigger so tab titles are easy to read
            height            = 24,     -- ~komorebi stackbar height
            indicator_height  = 3,      -- thin accent strip under the active tab
            gradients         = true,   -- filled, rounded tabs (vs the flat indicator lines)
            rounding          = 8,
            gradient_rounding = 8,
            round_only_edges  = true,   -- round the bar's outer ends, not every tab seam
            gaps_in           = 3,      -- gap between tabs
            gaps_out          = 4,      -- gap around the whole bar
            keep_upper_gap    = true,
            text_color        = "rgb(ffffff)",
            render_titles     = true,
            scrolling         = true,   -- scroll over the bar to cycle tabs
        },
    },

    misc = {
        force_default_wallpaper = 0,    -- no anime mascot wallpapers
        disable_hyprland_logo   = true,

        -- VRR / G-Sync for the 240Hz OLED. 2 = fullscreen-only (safest on NVIDIA — avoids the
        -- desktop/app flicker that always-on vrr = 1 can cause). Verify with `hyprctl monitors`
        -- (vrr: 1 while a fullscreen game is up). Keep tearing off when using VRR.
        vrr = 2,
    },

    -- XWayland apps (Steam, Discord, …) can't use Wayland fractional scaling, so on a
    -- fractionally-scaled display Hyprland upscales their buffer → blurry / low-res UI. Force
    -- them to render at scale 1 so they're sharp. They'll render smaller on a scaled panel;
    -- bump per-app zoom if needed (Steam: UI scaling in settings; Discord: Ctrl+=).
    xwayland = { force_zero_scaling = true },

    -- Per-host mouse/touchpad feel is in nix.input; only the shared keyboard basics here.
    input = {
        kb_layout  = "us",
        kb_variant = "",
        kb_model   = "",
        kb_options = "",
        kb_rules   = "",

        follow_mouse = 1,
    },
})

-- Default curves and animations, see https://wiki.hypr.land/Configuring/Advanced-and-Cool/Animations/
hl.curve("easeOutQuint",   { type = "bezier", points = { {0.23, 1},    {0.32, 1} } })
hl.curve("easeInOutCubic", { type = "bezier", points = { {0.65, 0.05}, {0.36, 1} } })
hl.curve("linear",         { type = "bezier", points = { {0, 0},       {1, 1}    } })
hl.curve("almostLinear",   { type = "bezier", points = { {0.5, 0.5},   {0.75, 1} } })
hl.curve("quick",          { type = "bezier", points = { {0.15, 0},    {0.1, 1}  } })

hl.animation({ leaf = "global",        enabled = true, speed = 10,   bezier = "default" })
hl.animation({ leaf = "border",        enabled = true, speed = 5.39, bezier = "easeOutQuint" })
hl.animation({ leaf = "windows",       enabled = true, speed = 4.79, bezier = "easeOutQuint" })
hl.animation({ leaf = "windowsIn",     enabled = true, speed = 4.1,  bezier = "easeOutQuint", style = "popin 87%" })
hl.animation({ leaf = "windowsOut",    enabled = true, speed = 1.49, bezier = "linear",       style = "popin 87%" })
hl.animation({ leaf = "fadeIn",        enabled = true, speed = 1.73, bezier = "almostLinear" })
hl.animation({ leaf = "fadeOut",       enabled = true, speed = 1.46, bezier = "almostLinear" })
hl.animation({ leaf = "fade",          enabled = true, speed = 3.03, bezier = "quick" })
hl.animation({ leaf = "layers",        enabled = true, speed = 3.81, bezier = "easeOutQuint" })
hl.animation({ leaf = "layersIn",      enabled = true, speed = 4,    bezier = "easeOutQuint", style = "fade" })
hl.animation({ leaf = "layersOut",     enabled = true, speed = 1.5,  bezier = "linear",       style = "fade" })
hl.animation({ leaf = "fadeLayersIn",  enabled = true, speed = 1.79, bezier = "almostLinear" })
hl.animation({ leaf = "fadeLayersOut", enabled = true, speed = 1.39, bezier = "almostLinear" })
hl.animation({ leaf = "workspaces",    enabled = true, speed = 1.94, bezier = "almostLinear", style = "fade" })
hl.animation({ leaf = "workspacesIn",  enabled = true, speed = 1.21, bezier = "almostLinear", style = "fade" })
hl.animation({ leaf = "workspacesOut", enabled = true, speed = 1.94, bezier = "almostLinear", style = "fade" })

--------------------------
---- LUA HELPERS (ex-scripts) ----
--------------------------
-- These replace shell scripts that drove `hyprctl dispatch` over legacy IPC (dead in Lua mode).
-- In-process they're also instant: no hyprctl/jq round-trip per step. Bind callbacks run on the
-- compositor event loop, so everything here stays non-blocking (no io.popen / sleeps).

-- Per-monitor workspaces (was hyprsome): monitor id N owns workspaces N*10+1 … N*10+9, so
-- Super+3 means "workspace 3 of THIS monitor". Same numbering hyprsome used, so existing
-- muscle memory and any workspace-numbered window rules carry over.
local function monitor_ws(n)
    local mon = hl.get_active_monitor()
    return tostring((mon and mon.id or 0) * 10 + n)
end

-- stack_push(dir) — make Super+Alt+arrow merge in BOTH directions. Plain group-aware move only
-- ever moves the FOCUSED window INTO a group that already sits in <dir>; it can't make a focused
-- STACK swallow the loose window next to it (it falls back to a plain move — the "I pushed the
-- stack and nothing merged" surprise). So:
--   focused window IS a stack → hop to the neighbour in <dir> and pull it INTO the stack
--   focused window is loose   → group-aware move (merge into a stack in <dir>, else just move)
local function stack_push(dir)
    local cur = hl.get_active_window()
    if not cur then return end
    if not cur.group then
        hl.dispatch(hl.dsp.window.move({ direction = dir, group_aware = true }))
        return
    end
    hl.dispatch(hl.dsp.focus({ direction = dir }))
    local neighbour = hl.get_active_window()
    if neighbour and neighbour.address ~= cur.address then
        -- into_group is a no-op unless a group sits in that direction, so fire all four — the
        -- stack we just came from is in exactly one of them, whatever the geometry.
        for _, d in ipairs(DIRS) do hl.dispatch(hl.dsp.window.move({ into_group = d })) end
    end
    -- Re-focus the stack's original front window so the view doesn't jump to the new tab.
    hl.dispatch(hl.dsp.focus({ window = cur }))
end

-- stack_all() — komorebi-style toggle: dissolve the focused stack, or else group every tiled
-- window on the workspace into one. Hyprland has no native "stack everything" dispatcher.
local function stack_all()
    local cur = hl.get_active_window()
    if cur and cur.group then
        hl.dispatch(hl.dsp.group.toggle())
        return
    end
    local ws = hl.get_active_workspace()
    if not ws then return end
    local wins = hl.get_windows({ workspace = ws, floating = false, mapped = true })
    if #wins < 2 then return end -- need two tiled windows to stack
    -- Group the first window, then pull the rest in (all four directions, as in stack_push).
    hl.dispatch(hl.dsp.focus({ window = wins[1] }))
    hl.dispatch(hl.dsp.group.toggle())
    for i = 2, #wins do
        hl.dispatch(hl.dsp.focus({ window = wins[i] }))
        for _, d in ipairs(DIRS) do hl.dispatch(hl.dsp.window.move({ into_group = d })) end
    end
    hl.dispatch(hl.dsp.focus({ window = wins[1] }))
end

-- toggle_hdr() — flip HDR/10-bit on the HDR panel(s). Why: the PipeWire screencast portal
-- (Discord/OBS full-screen share) can't read the 10-bit HDR framebuffer — shares come out a
-- black box. Flip HDR OFF to share, then back ON. (Everyday screenshots don't need this —
-- render.keep_unmodified_copy = 0 below handles those.)
-- The HDR specs come from nix.monitors (the flake is the single source of truth), picked by
-- `cm = "hdr"` rather than a port name — so a DP-x rename can't silently break this again.
-- hl.monitor MERGES into the existing rule for an output, so going SDR has to reset cm/bitdepth
-- explicitly (omitting them would keep the HDR values).
local function toggle_hdr()
    local hdr = {}
    for _, m in ipairs(monitors) do
        if m.cm == "hdr" then table.insert(hdr, m) end
    end
    if #hdr == 0 then
        hl.exec_cmd([[notify-send -t 2000 "HDR toggle" "no HDR monitor in nix.monitors"]])
        return
    end
    local live_hdr = false
    for _, mon in ipairs(hl.get_monitors()) do
        if mon.cm == "hdr" then live_hdr = true end
    end
    for _, m in ipairs(hdr) do
        if live_hdr then
            hl.monitor({ output = m.output, cm = "srgb", bitdepth = 8 })
        else
            hl.monitor(m)
        end
    end
    if live_hdr then
        hl.exec_cmd([[notify-send -t 2000 "HDR → SDR" "screenshots / screen-share work now"]])
    else
        hl.exec_cmd([[notify-send -t 2000 "SDR → HDR" "bright; capture disabled"]])
    end
end

---------------------
---- KEYBINDINGS ----
---------------------
-- Every bind carries a `description`: hypr-cheatsheet (Super+/) reads them from
-- `hyprctl binds -j`, so the text IS the cheatsheet entry — keep it short. (Lua binds all
-- report dispatcher "__lua", so without a description a row would say nothing useful.)

local mainMod = "SUPER"
local function bind(keys, action, description, opts)
    opts = opts or {}
    opts.description = description
    return hl.bind(keys, action, opts)
end

-- ── VM keyboard passthrough ────────────────────────────────────────────────
-- Wayland compositors own the global keybinds, so VMware/VirtualBox guests don't see
-- Super/workspace shortcuts the way they do under i3. Ctrl+Alt toggles a passthrough submap in
-- which Hyprland ignores ALL of its binds and every key reaches the guest (Ctrl+Alt mirrors
-- VMware's own input-release chord). Press it again to exit. The DMS submap indicator shows
-- when passthrough is active.
bind("CTRL + Alt_L", hl.dsp.submap("passthrough"), "VM keyboard passthrough (toggle)")
hl.define_submap("passthrough", function()
    bind("CTRL + Alt_L", hl.dsp.submap("reset"), "Leave VM passthrough")
end)
-- ───────────────────────────────────────────────────────────────────────────

bind(mainMod .. " + Return", hl.dsp.exec_cmd(terminal), "Open terminal")
-- ALT+Space launcher is managed by DMS now (dms.binds).
bind(mainMod .. " + Q", hl.dsp.window.close(), "Close window")
bind(mainMod .. " + E", hl.dsp.exec_cmd(fileManager), "Open file manager")
bind(mainMod .. " + SHIFT + Space", hl.dsp.window.float({ action = "toggle" }), "Toggle floating")
bind(mainMod .. " + P", hl.dsp.window.pseudo(), "Pseudotile (dwindle)")
bind(mainMod .. " + slash", hl.dsp.exec_cmd("hypr-cheatsheet"), "Show this keybind cheatsheet")
-- Flip the split orientation of the focused dwindle pair (i3 split h / split v). Super+V is
-- DMS's clipboard, so this lives on Super+T.
bind(mainMod .. " + T", hl.dsp.layout("togglesplit"), "Toggle split direction (dwindle)")
-- swapsplit swaps which window occupies the first vs second half of the focused dwindle split —
-- the two tiles trade places WITHOUT changing the split's orientation (unlike Super+T, which
-- rotates side-by-side <-> stacked but keeps each window's slot). Acts only on the focused split
-- node, so with 3+ windows it swaps the pair under the focus, not the whole tree.
bind(mainMod .. " + SHIFT + T", hl.dsp.layout("swapsplit"), "Swap the two halves of the split (dwindle)")
bind(mainMod .. " + F", hl.dsp.window.fullscreen({ mode = "maximized" }), "Maximize within work area (monocle)")
bind(mainMod .. " + SHIFT + F", hl.dsp.window.fullscreen({ mode = "fullscreen" }), "True edge-to-edge fullscreen (games)")
bind(mainMod .. " + G", stack_all, "Stack ALL windows in workspace (toggle)")

-- Window groups (tabbed stacks):
--   Super+W        — toggle the FOCUSED window into / out of its own group. This is the "start a
--                    stack" primitive: make a 1-tab group here, then merge neighbours with
--                    Super+Alt+arrow (stack_push — works whether the stack or the loose window is
--                    focused). Super+G stacks the WHOLE workspace.
--   Super+Shift+G  — lock the active group (toggle), so Super+Alt+arrow stops merging more
--                    windows in by accident.
--   MOVE vs. MERGE — Super+Shift+arrow MOVES the window (or the whole stack, since a stack is
--                    one tile) and never merges; Super+Alt+arrow MERGES into a stack. Tab
--                    cycling: Super+Tab / Super+[ ];  Super+Shift+W pops out.
bind(mainMod .. " + W", hl.dsp.group.toggle(), "Toggle window into/out of a stack")
bind(mainMod .. " + SHIFT + G", hl.dsp.group.lock_active({ action = "toggle" }), "Lock active stack")
bind(mainMod .. " + SHIFT + W", hl.dsp.window.move({ out_of_group = true }), "Pop window out of stack")
bind(mainMod .. " + Tab", hl.dsp.group.next(), "Next tab in stack")
bind(mainMod .. " + SHIFT + Tab", hl.dsp.group.prev(), "Previous tab in stack")
-- Bracket keys = step left/right through the stack (komorebi-style).
bind(mainMod .. " + bracketleft", hl.dsp.group.prev(), "Previous tab in stack")
bind(mainMod .. " + bracketright", hl.dsp.group.next(), "Next tab in stack")

local ARROWS = { left = "l", down = "d", up = "u", right = "r" }
for key, dir in pairs(ARROWS) do
    -- Merge INTO a stack (grow it) — both directions, see stack_push.
    bind(mainMod .. " + ALT + " .. key, function() stack_push(dir) end, "Merge window into stack (" .. key .. ")")
    -- Move windows / whole stacks. A stack is a single tile, so this relocates the ENTIRE stack
    -- as a block; it never merges (that's Super+Alt+arrow) — move vs. merge are split so the
    -- i3/sway muscle memory (Super+Shift+arrow = move) holds for stacks too.
    bind(mainMod .. " + SHIFT + " .. key, hl.dsp.window.move({ direction = dir }), "Move window / stack " .. key)
    bind(mainMod .. " + " .. key, hl.dsp.focus({ direction = dir }), "Focus " .. key)
    -- Swap the focused tile with its neighbour (i3 "move" between tiles, komorebi swap). All
    -- four arrow combos above are taken, so swap lives on Super+Ctrl+Shift+arrows.
    bind(mainMod .. " + CTRL + SHIFT + " .. key, hl.dsp.window.swap({ direction = dir }), "Swap tile " .. key)
end

-- Multi-monitor (komorebi focus-monitor / move-to-monitor). comma = left, period = right for
-- focus + send-window; Ctrl moves the WHOLE workspace to the other display (relative ±1, which
-- on a 2-monitor setup is just "the other one").
bind(mainMod .. " + comma", hl.dsp.focus({ monitor = "l" }), "Focus monitor left")
bind(mainMod .. " + period", hl.dsp.focus({ monitor = "r" }), "Focus monitor right")
bind(mainMod .. " + SHIFT + comma", hl.dsp.window.move({ monitor = "l" }), "Move window to left monitor")
bind(mainMod .. " + SHIFT + period", hl.dsp.window.move({ monitor = "r" }), "Move window to right monitor")
bind(mainMod .. " + CTRL + comma", hl.dsp.workspace.move({ monitor = "-1" }), "Move workspace to other monitor")
bind(mainMod .. " + CTRL + period", hl.dsp.workspace.move({ monitor = "+1" }), "Move workspace to other monitor")

-- Floating helpers + quick navigation
bind(mainMod .. " + C", hl.dsp.window.center(), "Center floating window")
bind(mainMod .. " + SHIFT + P", hl.dsp.window.pin(), "Pin floating window (all workspaces)")
bind(mainMod .. " + Z", hl.dsp.focus({ last = true }), "Focus last window (toggle)")
bind(mainMod .. " + Backspace", hl.dsp.focus({ workspace = "previous" }), "Workspace back-and-forth")

-- Scratchpad — Hyprland "special" workspace (i3 scratchpad). Super+minus shows/hides it;
-- Super+Shift+minus stashes the focused window into it.
bind(mainMod .. " + minus", hl.dsp.workspace.toggle_special("scratch"), "Toggle scratchpad")
bind(mainMod .. " + SHIFT + minus", hl.dsp.window.move({ workspace = "special:scratch", follow = false }), "Move window to scratchpad")

-- Alt+Tab window switching is handled by the hyprshell daemon (autostarted from nix.autostart),
-- which registers the Alt+Tab key itself from ~/.config/hyprshell/config.ron — so no binds here.

-- Per-monitor workspaces (see monitor_ws). The ws is resolved at PRESS time inside the
-- function — passing hl.dsp.focus({ workspace = monitor_ws(i) }) directly would freeze
-- whichever monitor was focused when the config loaded.
for i = 1, 9 do
    bind(mainMod .. " + " .. i, function()
        hl.dispatch(hl.dsp.focus({ workspace = monitor_ws(i) }))
    end, "Workspace " .. i .. " (this monitor)")
    bind(mainMod .. " + SHIFT + " .. i, function()
        hl.dispatch(hl.dsp.window.move({ workspace = monitor_ws(i), follow = false }))
    end, "Move window → workspace " .. i)
end

-- Scroll through existing workspaces with mainMod + scroll
bind(mainMod .. " + mouse_down", hl.dsp.focus({ workspace = "e+1" }), "Next workspace (scroll)")
bind(mainMod .. " + mouse_up", hl.dsp.focus({ workspace = "e-1" }), "Previous workspace (scroll)")

-- Move/resize windows with mainMod + LMB/RMB and dragging
bind(mainMod .. " + mouse:272", hl.dsp.window.drag(), "Drag to move window", { mouse = true })
bind(mainMod .. " + mouse:273", hl.dsp.window.resize(), "Drag to resize window", { mouse = true })

-- Resize the FOCUSED window from the keyboard — grow one window so it takes more area (dwindle
-- shrinks its neighbours to fit). True tiling resize, NOT the cursor zoom/magnify. Quick nudge:
-- hold Super+Ctrl and tap arrows (held = repeat).
local RESIZE = { left = { -60, 0 }, right = { 60, 0 }, up = { 0, -60 }, down = { 0, 60 } }
for key, d in pairs(RESIZE) do
    bind(mainMod .. " + CTRL + " .. key, hl.dsp.window.resize({ x = d[1], y = d[2], relative = true }),
        "Resize window " .. key, { repeating = true })
end

-- Sustained resize mode for big changes: Super+R, then just the arrows (held = repeat),
-- Esc/Enter to exit — no need to hold three keys the whole time.
bind(mainMod .. " + R", hl.dsp.submap("resize"), "Resize mode (then arrows)")
hl.define_submap("resize", function()
    for key, d in pairs(RESIZE) do
        bind(key, hl.dsp.window.resize({ x = d[1], y = d[2], relative = true }), "Resize " .. key, { repeating = true })
    end
    bind("escape", hl.dsp.submap("reset"), "Leave resize mode")
    bind("Return", hl.dsp.submap("reset"), "Leave resize mode")
end)

-- Laptop multimedia keys for volume and LCD brightness (work on the lock screen too)
bind("XF86AudioRaiseVolume", hl.dsp.exec_cmd("wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+"), "Volume up", { locked = true, repeating = true })
bind("XF86AudioLowerVolume", hl.dsp.exec_cmd("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-"), "Volume down", { locked = true, repeating = true })
bind("XF86AudioMute", hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"), "Mute", { locked = true, repeating = true })
bind("XF86AudioMicMute", hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle"), "Mute microphone", { locked = true, repeating = true })
bind("XF86MonBrightnessUp", hl.dsp.exec_cmd("brightnessctl -e4 -n2 set 5%+"), "Brightness up", { locked = true, repeating = true })
bind("XF86MonBrightnessDown", hl.dsp.exec_cmd("brightnessctl -e4 -n2 set 5%-"), "Brightness down", { locked = true, repeating = true })

-- Requires playerctl
bind("XF86AudioNext", hl.dsp.exec_cmd("playerctl next"), "Next track", { locked = true })
bind("XF86AudioPause", hl.dsp.exec_cmd("playerctl play-pause"), "Play / pause", { locked = true })
bind("XF86AudioPlay", hl.dsp.exec_cmd("playerctl play-pause"), "Play / pause", { locked = true })
bind("XF86AudioPrev", hl.dsp.exec_cmd("playerctl previous"), "Previous track", { locked = true })

-- Lock + log out
bind(mainMod .. " + L", hl.dsp.exec_cmd("dms ipc lock lock"), "Lock screen")
-- Log out — exits Hyprland back to the DMS greeter. No confirmation, so unsaved work is lost.
bind(mainMod .. " + SHIFT + L", hl.dsp.exit(), "Log out of Hyprland")

-- Quake/dropdown terminal — pyprland handles float/size/animation (see pypr config.toml).
bind(mainMod .. " + grave", hl.dsp.exec_cmd("pypr toggle term"), "Dropdown terminal (toggle)")

---------------------
---- Screenshots ----
---------------------
-- flameshot is the sole screenshot tool (its tray daemon is autostarted by nix.autostart) and
-- the grim portal is wrapped `-l 0` (modules/hyprland.nix) so the selector opens in ~300ms.
-- Bind the physical PrintScreen keycode (XKB <PRSC> = 107), NOT the Print keysym: on the us
-- layout the key carries [Print, Sys_Req], so Shift would resolve to the level-2 keysym Sys_Req
-- and a keysym bind would miss. code:107 is immune to the shift level.
-- screenshot-flameshot.sh wraps `flameshot gui --raw`: keeps a local copy + clipboard, and
-- best-effort mirrors into the Nextcloud VFS by month (skips cleanly when /mnt isn't mounted).
bind("code:107", hl.dsp.exec_cmd("~/.config/hypr/screenshot-flameshot.sh"), "Screenshot (flameshot)")

-- HDR screencopy is broken upstream (Hyprland #11294 regression): with the AW3225QF QD-OLED in
-- HDR mode, screencopy (grim/flameshot/OBS/hyprpicker) wedges — stale, frozen, or blank. No
-- keep_unmodified_copy value is clean: =2 freezes the HDR monitor; =1 (force the FP16 copy on
-- ALL monitors) stales the SDR monitor; =0 fixes the freeze/stale everywhere but blanks
-- FULLSCREEN HDR GAME captures. No in-session refresh re-inits the wedged FP16 pipeline — only a
-- real HDR mode-set does. DECISION: =0 is the daily baseline (desktop + windows capture reliably
-- on both monitors). For fullscreen HDR games use Steam's F12 (the Steam overlay bypasses
-- wlr-screencopy) or the HDR toggle (Super+Shift+B). https://github.com/hyprwm/Hyprland/pull/11294
hl.config({ render = { keep_unmodified_copy = 0, use_shader_blur_blend = true } })

-- Separately, grim & the screencast portal STILL can't read the HDR primary for SCREEN-SHARING
-- (black share). Flip HDR off before sharing, then back on.
bind(mainMod .. " + SHIFT + B", toggle_hdr, "Toggle HDR on the HDR monitor(s)")

-- Blank/unblank all monitors ("screensaver"): Super+B powers the panels off; press it AGAIN to
-- turn them back on. Input doesn't reliably wake DPMS here (NVIDIA), so it's a toggle you hit
-- blind. Deferred via a timer: dispatching DPMS straight from the key event is undefined
-- behaviour per the wiki (the old bind got the same deferral for free by shelling out to hyprctl).
bind(mainMod .. " + B", function()
    hl.timer(function()
        hl.dispatch(hl.dsp.dpms({ action = "toggle" }))
    end, { timeout = 500, type = "oneshot" })
end, "Toggle monitors off/on (DPMS)")

--------------------------------
---- WINDOWS AND WORKSPACES ----
--------------------------------

-- Ignore maximize requests from apps.
hl.window_rule({ name = "suppress-maximize", match = { class = ".*" }, suppress_event = "maximize" })

-- Fix some dragging issues with XWayland
hl.window_rule({
    name  = "fix-xwayland-drags",
    match = { class = "^$", title = "^$", xwayland = true, float = true, fullscreen = false, pin = false },
    no_focus = true,
})

-- Orange border on fullscreen/maximized windows (e.g. the Super+F monocle) as a visual cue.
-- Shows on maximize (which keeps the border); a true edge-to-edge fullscreen draws no border.
hl.window_rule({ name = "fullscreen-border", match = { fullscreen = true }, border_color = "rgb(FFA500)" })

-- Gamescope setup. `immediate` (tearing) only takes effect with general.allow_tearing = true,
-- and tearing conflicts with VRR — reconciled toward the VRR path, so left commented out.
-- hl.window_rule({ match = { class = "^(gamescope)$" }, immediate = true })
hl.window_rule({ name = "gamescope", match = { class = "^(gamescope)$" }, fullscreen = true, float = true })

-- flameshot region-selection overlay — matched by TITLE (the window has an empty class). Float
-- it so Hyprland doesn't tile the overlay into a workspace slot (which shrinks it and breaks the
-- full-screen region pick). Created by `flameshot gui` (PrintScreen).
hl.window_rule({ name = "flameshot-overlay", match = { title = "^(flameshot)$" }, float = true })

-- War Thunder — force TRUE fullscreen so it covers the DMS bar's reserved zone (maximize
-- avoids that zone -> bar stays). Matched by TITLE (most reliable) AND likely class.
-- If WT still TILES as a half-window, the match is wrong: run
--   hyprctl clients | grep -iE 'class:|title:'
-- while WT is up and fix the regex. Manual fallback works regardless: Super+Shift+F.
hl.window_rule({
    name  = "war-thunder-title",
    match = { title = "^(War Thunder.*)$" },
    fullscreen = true, no_anim = true, idle_inhibit = "always",
})
hl.window_rule({
    name  = "war-thunder-class",
    match = { class = [[^(aces|aces\.exe)$]] },
    fullscreen = true, idle_inhibit = "always",
})

---------------------------
---- DMS-owned modules ----
---------------------------
-- Keybinds the DMS keybind editor manages (clipboard, launcher, notifications, …). DMS detects
-- these requires by name, so keep the exact "dms.binds" / "dms.binds-user" spelling.
require_optional("dms.binds")
require_optional("dms.binds-user")

-- Colors: DMS's matugen hook writes dms.colors as a plain hl.config({...}) call — no variable
-- to reuse, unlike hyprlang's $primary. To layer our accent on the LIVE theme primary we
-- capture the table it passes to hl.config on its way through, then read the primary back out.
local dms_colors = {}
do
    local real_config = hl.config
    hl.config = function(t)
        dms_colors = t
        return real_config(t)
    end
    local ok, err = pcall(require_optional, "dms.colors")
    hl.config = real_config
    if not ok then error(err, 0) end
end
local primary = (((dms_colors.general or {}).col or {}).active_border) or "rgba(33ccffee)"

hl.config({
    -- Active window border: DMS's live primary (tracks the theme) + green, 45° gradient.
    general = { col = { active_border = { colors = { primary, "rgba(00ff99ee)" }, angle = 45 } } },
    group = {
        -- Stacks get a distinct komorebi-green accent so a focused GROUP reads differently from
        -- a focused normal window (DMS would otherwise paint both plain primary).
        col = { border_active = "rgb(00A542)" }, -- solid green = "this is a stack"
        -- Groupbar tabs: FLAT solid fills (a primary→green gradient blended the theme colour into
        -- neon green diagonally — loud, and white text was unreadable over the bright end).
        -- Active tab = komorebi green (matches the border), other tabs = dim nord0 so they
        -- recede, and a red active tab while the group is LOCKED (Super+Shift+G) for feedback.
        groupbar = {
            col = {
                active          = "rgb(00A542)",   -- focused tab
                inactive        = "rgba(2e3440cc)", -- other tabs, dimmed
                locked_active   = "rgb(bf616a)",   -- focused tab when the stack is locked
                locked_inactive = "rgba(2e3440cc)",
            },
        },
    },
})
