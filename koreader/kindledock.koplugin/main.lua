--[[
Kindle Dock - now-playing display + remote control for a Mac running kindledockd.

The Mac serves the system now-playing state over HTTP; this plugin polls it and
renders a clean e-ink screen: cover art, track info, progress, and controls
(play/pause, skip, +/-15s, volume). Works for any media the Mac reports
system-wide (Music, browser video, ...), not just one app.
]]

local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local DataStorage = require("datastorage")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local InputContainer = require("ui/widget/container/inputcontainer")
local Dispatcher = require("dispatcher")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local LuaSettings = require("luasettings")
local Menu = require("ui/widget/menu")
local logger = require("logger")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local ProgressWidget = require("ui/widget/progresswidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local GestureRange = require("ui/gesturerange")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Screen = Device.screen
local Size = require("ui/size")
local http = require("socket.http")
local ltn12 = require("ltn12")
local url = require("socket.url")
local json = require("json")
local _ = require("gettext")

local POLL_SECONDS = 3
local ART_PATH = "/tmp/kindledock_art.png"

local KindleDock = WidgetContainer:extend{
    name = "kindledock",
    is_doc_only = false,
}

function KindleDock:onKindleDockOpen()
    self:openDock()
    return true
end

function KindleDock:onDispatcherRegisterActions()
    Dispatcher:registerAction("kindledock_open", {
        category = "none",
        event = "KindleDockOpen",
        title = _("Now Playing"),
        device = true,
    })
end


-- theme setting: "dark" (default), "light", or "auto" (dark from 19:00 to 07:00)
local THEMES = { dark = true, light = true, auto = true }

function KindleDock:theme()
    local t = self.settings:readSetting("theme") or "dark"
    return THEMES[t] and t or "dark"
end

function KindleDock:isDark()
    local t = self:theme()
    if t == "auto" then
        local h = tonumber(os.date("%H"))
        return h >= 19 or h < 7
    end
    return t == "dark"
end

function KindleDock:setLocked(locked)
    self.locked = locked
    self:refreshScreen("full")
end

function KindleDock:init()
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/kindledock.lua")
    self.ui.menu:registerToMainMenu(self)
    -- test hook: auto-open the dock screen (used by the emulator test harness)
    if self.settings:readSetting("autotest_open") then
        UIManager:scheduleIn(2, function() self:openDock() end)
    end
end

function KindleDock:serverUrl()
    local host = self.settings:readSetting("host")
    local port = self.settings:readSetting("port") or 8931
    if not host or host == "" then return nil end
    return "http://" .. host .. ":" .. tostring(port)
end

function KindleDock:addToMainMenu(menu_items)
    menu_items.kindledock = {
        text = _("Now Playing"),
        sorting_hint = "tools",
        callback = function()
            if not self:serverUrl() then
                self:showSetup()
            else
                self:openDock()
            end
        end,
        hold_callback = function()
            self:showSetup()
        end,
    }
end

function KindleDock:showSetup()
    self.setup_dialog = MultiInputDialog:new{
        title = _("Kindle Dock server"),
        fields = {
            {
                text = self.settings:readSetting("host") or "",
                hint = _("Mac address (IP or hostname)"),
            },
            {
                text = tostring(self.settings:readSetting("port") or 8931),
                hint = _("Port"),
            },
            {
                text = self.settings:readSetting("token") or "",
                hint = _("Access token (from the Mac's config.json)"),
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(self.setup_dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local f = self.setup_dialog:getFields()
                        self.settings:saveSetting("host", f[1])
                        self.settings:saveSetting("port", tonumber(f[2]) or 8931)
                        self.settings:saveSetting("token", f[3])
                        self.settings:flush()
                        UIManager:close(self.setup_dialog)
                        self:openDock()
                    end,
                },
            },
        },
    }
    UIManager:show(self.setup_dialog)
    self.setup_dialog:onShowKeyboard()
end

-- networking -----------------------------------------------------------------

http.TIMEOUT = 6

function KindleDock:request(method, path)
    local base = self:serverUrl()
    if not base then return nil, "no server configured" end
    local token = self.settings:readSetting("token") or ""
    local body = {}
    -- pcall(http.request) yields: ok, 1-or-nil, http-code-or-error, ...
    local ok, one, code = pcall(http.request, {
        url = base .. path,
        method = method,
        sink = ltn12.sink.table(body),
        source = method == "POST" and ltn12.source.string("") or nil,
        headers = { Authorization = "Bearer " .. token },
    })
    if not ok then return nil, tostring(one) end
    if one == nil then return nil, tostring(code) end
    local raw = table.concat(body)
    return raw, code
end

function KindleDock:fetchState()
    local raw, code = self:request("GET", "/nowplaying")
    if not raw then return nil, code end
    if code ~= 200 then return nil, "http " .. tostring(code) end
    local ok, state = pcall(json.decode, raw)
    if not ok or type(state) ~= "table" then return nil, "bad json" end
    return state
end

function KindleDock:fetchArtwork(track_id)
    local raw, code = self:request("GET", "/artwork.png?track=" .. tostring(track_id or ""))
    if not raw or code ~= 200 then return false end
    -- reject truncated/non-PNG payloads: a corrupt file would make ImageWidget
    -- throw during render and kill the poll loop (frozen title + art)
    if #raw < 100 or raw:sub(2, 4) ~= "PNG" then return false end
    -- per-track path: ImageWidget caches decoded art by filename, so a constant
    -- path would keep showing the previous track's cover
    local path = "/tmp/kindledock_art_" .. tostring(track_id or "x") .. ".png"
    local f = io.open(path, "wb")
    if not f then return false end
    f:write(raw)
    f:close()
    if self.art_path and self.art_path ~= path then os.remove(self.art_path) end
    self.art_path = path
    return true
end

function KindleDock:showOutputs()
    local raw, code = self:request("GET", "/outputs")
    local ok, res = pcall(json.decode, raw or "")
    if code ~= 200 or not ok or type(res) ~= "table" or type(res.outputs) ~= "table" then return end
    local buttons = {}
    for _, o in ipairs(res.outputs) do
        table.insert(buttons, {{
            text = o.current and (o.name .. "  (current)") or o.name,
            enabled = not o.current,
            callback = function()
                UIManager:close(self.output_dialog)
                self:sendCommand("c=set_output&uid=" .. url.escape(o.uid))
            end,
        }})
    end
    self.output_dialog = ButtonDialog:new{ title = _("Play sound on"), buttons = buttons }
    UIManager:show(self.output_dialog)
end

-- Apple Music's current playlist, starting at the playing track; tap one to play it
function KindleDock:showQueue()
    local raw, code = self:request("GET", "/queue")
    local ok, q = pcall(json.decode, raw or "")
    if code ~= 200 or not ok or type(q) ~= "table" or type(q.tracks) ~= "table" then return end
    local items = {}
    for _, t in ipairs(q.tracks) do
        table.insert(items, {
            text = t.title,
            mandatory = t.artist,
            bold = t.index == q.current,
            callback = function()
                UIManager:close(self.queue_menu)
                self:sendCommand("c=play_index&i=" .. tostring(t.index))
            end,
        })
    end
    local modes = self.state and type(self.state.modes) == "table" and self.state.modes
    self.queue_menu = Menu:new{
        title = q.playlist .. ((modes and modes.shuffle) and "  ·  " .. _("shuffle on") or ""),
        item_table = items,
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        close_callback = function() UIManager:close(self.queue_menu) end,
    }
    UIManager:show(self.queue_menu)
end

-- cmd is a /cmd query string, or a function for buttons that open a dialog instead
function KindleDock:runCommand(cmd)
    if type(cmd) == "function" then cmd() else self:sendCommand(cmd) end
end

function KindleDock:sendCommand(params)
    self:request("POST", "/cmd?" .. params)
    -- immediate repaint so the button press feels responsive
    self:poll(true)
end

-- view -----------------------------------------------------------------------

local function fmt_time(secs)
    secs = math.max(0, math.floor(secs or 0))
    return string.format("%d:%02d", math.floor(secs / 60), secs % 60)
end

local BROWSER_APPS = {
    ["com.google.Chrome"] = true, ["com.apple.Safari"] = true, ["company.thebrowser.Browser"] = true,
    ["com.brave.Browser"] = true, ["org.mozilla.firefox"] = true, ["com.microsoft.edgemac"] = true,
}

-- Font Awesome glyphs from KOReader's bundled nerdfonts/symbols.ttf, which the
-- UI font falls back to, so they render with the regular "cfont" face
local ICON = {
    play = "\u{F04B}", pause = "\u{F04C}", prev = "\u{F048}", next = "\u{F051}",
    shuffle = "\u{F074}", ["repeat"] = "\u{F01E}", vol_down = "\u{F027}", vol_up = "\u{F028}",
    output = "\u{F025}", queue = "\u{F0CA}", lock = "\u{F023}",
}

function KindleDock:buildContent()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local state = self.state
    local dark = self:isDark()
    local C_HI   = dark and Blitbuffer.COLOR_WHITE      or Blitbuffer.COLOR_BLACK
    local C_DIM  = dark and Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_DARK_GRAY
    local C_MUTE = Blitbuffer.COLOR_GRAY
    local C_TRK  = dark and Blitbuffer.COLOR_DARK_GRAY  or Blitbuffer.COLOR_LIGHT_GRAY
    local pad = math.floor(sw * 0.07)
    local inner_w = sw - 2 * pad
    local playing = state ~= nil and (state.state == "playing" or state.state == "paused")
    local kd = self

    local function vspan(h) return VerticalSpan:new{ width = h } end
    local function hspan(w) return HorizontalSpan:new{ width = w } end
    local function text(t, size, color, opts)
        opts = opts or {}
        return TextWidget:new{
            text = t, face = Font:getFace("cfont", size), fgcolor = color,
            bold = opts.bold, max_width = opts.max_width,
        }
    end
    local function centered(w, h, widget)
        return CenterContainer:new{ dimen = Geom:new{ w = w, h = h }, widget }
    end
    -- flat text/icon button; a disabled one is simply not drawn tappable
    local function tbtn(label, cmd, w, h, size, color)
        local btn = InputContainer:new{
            dimen = Geom:new{ w = w, h = h },
            centered(w, h, text(label, size, color)),
        }
        btn.ges_events = {
            Tap = { GestureRange:new{ ges = "tap", range = function() return btn.dimen end } },
        }
        function btn:onTap() kd:runCommand(cmd) return true end
        return btn
    end

    local main = VerticalGroup:new{ align = "center" }

    -- art, or a clock / message in its place
    local is_video = state and BROWSER_APPS[state.app or ""]
    local art_w = is_video and math.floor(sw * 0.86) or math.floor(sw * 0.6)
    local art_h = is_video and math.floor(art_w * 9 / 16) or art_w
    if playing and self.have_art then
        table.insert(main, FrameContainer:new{
            padding = 0, margin = 0,
            bordersize = dark and Size.border.thin or 0,
            color = Blitbuffer.COLOR_DARK_GRAY,
            background = Blitbuffer.COLOR_BLACK,
            ImageWidget:new{ file = self.art_path or ART_PATH, width = art_w, height = art_h },
        })
    elseif playing then
        table.insert(main, vspan(art_h))
    else
        local clock = (os.date("%I:%M"):gsub("^0", ""))
        table.insert(main, text(self.offline and _("Mac unreachable") or clock,
            self.offline and 32 or 150, C_HI))
        table.insert(main, vspan(math.floor(sh * 0.02)))
        table.insert(main, text(self.offline and _("Retrying every few seconds") or _("Nothing playing"), 20, C_MUTE))
    end

    if playing then
        -- title and artist
        table.insert(main, vspan(math.floor(sh * 0.03)))
        table.insert(main, text(state.track or "", 30, C_HI, { bold = true, max_width = inner_w }))
        table.insert(main, vspan(math.floor(sh * 0.008)))
        local sub = state.artist or ""
        if type(state.album) == "string" and state.album ~= "" then
            sub = sub ~= "" and (sub .. "  ·  " .. state.album) or state.album
        end
        table.insert(main, text(sub, 20, C_DIM, { max_width = inner_w }))

        -- progress: tap anywhere along the bar to seek; times at either end
        if (state.duration or 0) > 0 then
            table.insert(main, vspan(math.floor(sh * 0.025)))
            local bar_h = math.floor(sh * 0.008)
            local hit_h = bar_h * 6
            local dur = state.duration
            local bar = InputContainer:new{
                dimen = Geom:new{ w = inner_w, h = hit_h },
                centered(inner_w, hit_h, ProgressWidget:new{
                    width = inner_w, height = bar_h,
                    percentage = math.min(1, (state.position or 0) / dur),
                    fillcolor = C_HI, bgcolor = C_TRK,
                    bordersize = 0, radius = 0,
                }),
            }
            bar.ges_events = {
                Tap = { GestureRange:new{ ges = "tap", range = function() return bar.dimen end } },
            }
            function bar:onTap(_, ges)
                if kd.locked then return true end
                local frac = math.max(0, math.min(1, (ges.pos.x - self.dimen.x) / self.dimen.w))
                kd:sendCommand(string.format("c=seek&to=%.1f", frac * dur))
                return true
            end
            table.insert(main, bar)
            local left = text(fmt_time(state.position), 16, C_MUTE)
            local right = text(fmt_time(dur), 16, C_MUTE)
            local mid = text(type(state.queue) == "table"  -- json null decodes to a sentinel function
                and (state.queue[1] .. " of " .. state.queue[2]) or "", 16, C_MUTE)
            local gap = (inner_w - left:getSize().w - mid:getSize().w - right:getSize().w) / 2
            table.insert(main, HorizontalGroup:new{
                left, hspan(math.floor(gap)), mid, hspan(math.ceil(gap)), right,
            })
        end
    end

    -- controls (hidden while locked, so the dock is a display only)
    if not self.locked and state then
        local row_h = math.floor(sh * 0.065)
        local modes = type(state.modes) == "table" and state.modes or nil
        local cell = math.floor(inner_w / 5)
        local function mode_btn(icon, cmd, on)
            if not modes then return hspan(cell) end
            return tbtn(icon, cmd, cell, row_h, 24, on and C_HI or C_MUTE)
        end
        local rep = modes and modes["repeat"] or "off"
        table.insert(main, vspan(math.floor(sh * 0.03)))
        table.insert(main, HorizontalGroup:new{ align = "center",
            mode_btn(ICON.shuffle, "c=shuffle", modes and modes.shuffle),
            tbtn(ICON.prev, "c=prev", cell, row_h, 32, C_HI),
            tbtn(state.state == "playing" and ICON.pause or ICON.play, "c=toggle", cell, row_h, 46, C_HI),
            tbtn(ICON.next, "c=next", cell, row_h, 32, C_HI),
            mode_btn(rep == "one" and (ICON["repeat"] .. " 1") or ICON["repeat"], "c=repeat", rep ~= "off"),
        })
        local cell4 = math.floor(inner_w / 4)
        local small_h = math.floor(sh * 0.05)
        table.insert(main, vspan(math.floor(sh * 0.01)))
        table.insert(main, HorizontalGroup:new{ align = "center",
            tbtn("\u{2212}15", "c=back15", cell4, small_h, 20, C_DIM),
            tbtn(ICON.vol_down, "c=volume_down", cell4, small_h, 22, C_DIM),
            tbtn(ICON.vol_up, "c=volume_up", cell4, small_h, 22, C_DIM),
            tbtn("+15", "c=fwd15", cell4, small_h, 20, C_DIM),
        })
        -- sound output + volume: tap to pick where the Mac plays
        local out = type(state.output) == "string" and state.output ~= "" and state.output
        if out then
            local vol = type(state.volume) == "number" and ("  ·  " .. state.volume .. "%") or ""
            table.insert(main, vspan(math.floor(sh * 0.01)))
            table.insert(main, tbtn(ICON.output .. "  " .. out .. vol .. "  \u{203A}",
                function() kd:showOutputs() end, inner_w, small_h, 17, C_DIM))
        end
    end

    -- footer, pinned to the bottom edge
    local foot_h = math.floor(sh * 0.05)
    local footer
    if self.locked then
        footer = centered(sw, foot_h, text(ICON.lock .. "  " .. _("Hold anywhere to unlock"), 16, C_MUTE))
    else
        local items = {}
        if state and state.app == "com.apple.Music" then  -- /queue is Apple Music only
            table.insert(items, { ICON.queue .. "  " .. _("Queue"), function() kd:showQueue() end })
        end
        table.insert(items, { ICON.lock .. "  " .. _("Lock"), function() kd:setLocked(true) end })
        table.insert(items, { _("Close"), function() kd:closeDock() end })
        local w = math.floor(inner_w / #items)
        footer = HorizontalGroup:new{ align = "center" }
        for _, it in ipairs(items) do
            table.insert(footer, tbtn(it[1], it[2], w, foot_h, 17, C_MUTE))
        end
    end

    local bottom = math.floor(sh * 0.02)
    return VerticalGroup:new{ align = "center",
        centered(sw, sh - foot_h - bottom, main),
        centered(sw, foot_h, footer),
    }
end

function KindleDock:refreshScreen(refresh)
    if not self.root then return end
    local dark = self:isDark()
    if dark ~= self.painted_dark then refresh = "full" end  -- theme flip needs a full e-ink refresh
    self.painted_dark = dark
    self.root[1].background = dark and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
    self.root[1][1] = self:buildContent()
    UIManager:setDirty(self.root, refresh or "ui")
end

function KindleDock:poll(force_refresh)
    if not self.dock_open then return end
    local state, err = self:fetchState()
    local track_changed = false
    if state then
        self.offline = false
        if state.track_id and state.track_id ~= self.last_track_id then
            track_changed = true
            self.last_track_id = state.track_id
            self.have_art = state.has_artwork and self:fetchArtwork(state.track_id) or false
            self.last_art_try = os.time()
        elseif not state.track_id then
            self.have_art = false
        end
        if state.track_id and state.has_artwork and not self.have_art then
            if not self.last_art_try or (os.time() - self.last_art_try) >= 10 then
                self.last_art_try = os.time()
                self.have_art = self:fetchArtwork(state.track_id)
                if self.have_art then track_changed = true end
            end
        end
        self.state = state
    else
        self.offline = true
    end
    self:refreshScreen(track_changed and "full" or "ui")
end

function KindleDock:openDock()
    self.dock_open = true
    self.state = nil
    self.last_track_id = nil
    self.have_art = false
    self.art_path = nil
    self.locked = false
    self.painted_dark = self:isDark()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    self.root = InputContainer:new{
        dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh },
        covers_fullscreen = true,
        FrameContainer:new{
            width = sw,
            height = sh,
            padding = 0,
            margin = 0,
            background = self:isDark() and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE,
            self:buildContent(),
        },
    }
    local kd = self
    self.root.ges_events = {
        Hold = { GestureRange:new{ ges = "hold", range = self.root.dimen } },
    }
    function self.root:onHold()
        if kd.locked then kd:setLocked(false) end
        return true
    end
    UIManager:show(self.root)
    pcall(function() self:poll(true) end)
    self:scheduleNext()
end

function KindleDock:scheduleNext()
    -- re-arm the poll loop; a poll error must never kill the loop
    UIManager:scheduleIn(POLL_SECONDS, function()
        if not self.dock_open then return end
        local ok, err = pcall(function() self:poll() end)
        if not ok then logger.warn("kindledock: poll error:", err) end
        self:scheduleNext()
    end)
end

function KindleDock:closeDock()
    self.dock_open = false
    if self.root then
        UIManager:close(self.root)
        self.root = nil
    end
    UIManager:setDirty("all", "full")
end

return KindleDock
