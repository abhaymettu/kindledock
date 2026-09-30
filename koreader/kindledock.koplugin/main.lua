--[[
Kindle Dock - now-playing display + remote control for a Mac running kindledockd.

The Mac serves the system now-playing state over HTTP; this plugin polls it and
renders a clean e-ink screen: cover art, track info, progress, and controls
(play/pause, skip, +/-15s, volume). Works for any media the Mac reports
system-wide (Music, browser video, ...), not just one app.
]]

local BD = require("ui/bidi")
local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
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
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
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


function KindleDock:isDark()
    return (self.settings:readSetting("theme") or "dark") == "dark"
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

function KindleDock:appLabel(app)
    local names = {
        ["com.apple.Music"] = "Apple Music",
        ["com.spotify.client"] = "Spotify",
        ["com.google.Chrome"] = "Chrome",
        ["com.apple.Safari"] = "Safari",
        ["company.thebrowser.Browser"] = "Arc",
        ["com.brave.Browser"] = "Brave",
        ["tv.twitch"] = "Twitch",
    }
    return names[app or ""] or app or ""
end

function KindleDock:buildContent()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local state = self.state
    local v = VerticalGroup:new{ align = "center" }
    local pad = math.floor(sw * 0.05)
    local dark = self:isDark()
    local C_HI   = dark and Blitbuffer.COLOR_WHITE      or Blitbuffer.COLOR_BLACK
    local C_DIM  = dark and Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_DARK_GRAY
    local C_FILL = dark and Blitbuffer.COLOR_WHITE      or Blitbuffer.COLOR_BLACK
    local C_TRK  = dark and Blitbuffer.COLOR_DARK_GRAY  or Blitbuffer.COLOR_LIGHT_GRAY

    local function hspan(w) return HorizontalSpan:new{ width = w } end
    local function vspan(h) return VerticalSpan:new{ width = h } end

    -- top label
    local top_text
    if state and state.app then
        top_text = string.upper(self:appLabel(state.app))
    elseif self.offline then
        top_text = "OFFLINE"
    else
        top_text = "KINDLE DOCK"
    end
    table.insert(v, vspan(math.floor(sh * 0.022)))
    table.insert(v, TextWidget:new{
        text = top_text,
        face = Font:getFace("cfont", 18),
        fgcolor = Blitbuffer.COLOR_GRAY,
    })
    table.insert(v, vspan(math.floor(sh * 0.02)))

    local playing = state and (state.state == "playing" or state.state == "paused")

    -- cover art: video (browser) = 16:9, music = square album art
    local BROWSER_APPS = {
        ["com.google.Chrome"] = true,
        ["com.apple.Safari"] = true,
        ["company.thebrowser.Browser"] = true,
        ["com.brave.Browser"] = true,
        ["org.mozilla.firefox"] = true,
        ["com.microsoft.edgemac"] = true,
    }
    local cover_w, cover_h
    if state and BROWSER_APPS[state.app or ""] then
        cover_w = math.floor(sw * 0.8)
        cover_h = math.floor(cover_w * 9 / 16)
    else
        cover_w = math.floor(sw * 0.55)
        cover_h = cover_w
    end
    if playing and self.have_art then
        table.insert(v, CenterContainer:new{
            dimen = Geom:new{ w = sw, h = cover_h },
            FrameContainer:new{
                padding = 0,
                margin = 0,
                bordersize = dark and Size.border.thin or 0,
                color = C_DIM,
                background = Blitbuffer.COLOR_BLACK,
                ImageWidget:new{
                    file = self.art_path or ART_PATH,
                    width = cover_w,
                    height = cover_h,
                },
            },
        })
    else
        table.insert(v, CenterContainer:new{
            dimen = Geom:new{ w = sw, h = cover_h },
            TextWidget:new{
                text = playing and "" or (self.offline and _("Mac unreachable") or _("Nothing playing")),
                face = Font:getFace("cfont", 26),
                fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            },
        })
    end
    table.insert(v, vspan(math.floor(sh * 0.012)))

    -- title / artist
    if playing then
        table.insert(v, CenterContainer:new{
            dimen = Geom:new{ w = sw, h = math.floor(sh * 0.09) },
            TextWidget:new{
                text = state.track or "",
                face = Font:getFace("cfont", 30),
                max_width = sw - 2 * pad,
                bold = true,
                fgcolor = C_HI,
            },
        })
        local sub = state.artist or ""
        if state.album and state.album ~= "" then
            sub = sub .. " - " .. state.album
        end
        table.insert(v, CenterContainer:new{
            dimen = Geom:new{ w = sw, h = math.floor(sh * 0.05) },
            TextWidget:new{
                text = sub,
                face = Font:getFace("cfont", 22),
                max_width = sw - 2 * pad,
                fgcolor = C_DIM,
            },
        })
    else
        table.insert(v, CenterContainer:new{
            dimen = Geom:new{ w = sw, h = math.floor(sh * 0.09) },
            TextWidget:new{
                text = self.offline and _("Could not reach the Mac") or _("Play something on the Mac"),
                face = Font:getFace("cfont", 24),
                fgcolor = C_HI,
            },
        })
    end

    -- progress
    if playing and (state.duration or 0) > 0 then
        table.insert(v, vspan(math.floor(sh * 0.014)))
        local pct = math.min(1, (state.position or 0) / state.duration)
        table.insert(v, ProgressWidget:new{
            width = sw - 2 * pad,
            height = math.floor(sh * 0.012),
            percentage = pct,
            fillcolor = C_FILL,
            bgcolor = C_TRK,
        })
        table.insert(v, vspan(8))
        table.insert(v, TextWidget:new{
            text = fmt_time(state.position) .. "  /  " .. fmt_time(state.duration),
            face = Font:getFace("cfont", 18),
            fgcolor = C_DIM,
        })
    end

    -- controls
    local btn_w = math.floor((sw - 2 * pad) / 3.4)
    local btn_h = math.floor(sh * 0.062)
    local small_w = math.floor((sw - 2 * pad) / 4.6)
    local small_h = math.floor(sh * 0.05)
    local function tbtn(label, cmd, enabled, w, h, fsize)
        local kd = self
        local btn = InputContainer:new{
            dimen = Geom:new{ w = w, h = h },
            CenterContainer:new{
                dimen = Geom:new{ w = w, h = h },
                TextWidget:new{
                    text = label,
                    face = Font:getFace("cfont", fsize),
                    fgcolor = (enabled == false) and Blitbuffer.COLOR_GRAY or C_HI,
                },
            },
        }
        btn.ges_events = {
            Tap = { GestureRange:new{ ges = "tap", range = function() return btn.dimen end } },
        }
        function btn:onTap()
            if enabled ~= false then kd:sendCommand(cmd) end
            return true
        end
        return btn
    end
    local function bigbtn(label, cmd, enabled)
        if dark then return tbtn(label, cmd, enabled, btn_w, btn_h, 22) end
        return Button:new{
            text = label,
            width = btn_w,
            height = btn_h,
            text_font_face = "cfont",
            text_font_size = 22,
            enabled = enabled ~= false,
            callback = function() self:sendCommand(cmd) end,
        }
    end
    local function smallbtn(label, cmd, enabled)
        if dark then return tbtn(label, cmd, enabled, small_w, small_h, 18) end
        return Button:new{
            text = label,
            width = small_w,
            height = small_h,
            text_font_face = "cfont",
            text_font_size = 18,
            enabled = enabled ~= false,
            callback = function() self:sendCommand(cmd) end,
        }
    end
    table.insert(v, vspan(math.floor(sh * 0.02)))
    table.insert(v, HorizontalGroup:new{ align = "center",
        bigbtn("<<", "c=prev", playing),
        hspan(math.floor(pad / 2)),
        bigbtn(playing and state.state == "playing" and "Pause" or "Play", "c=toggle", state ~= nil),
        hspan(math.floor(pad / 2)),
        bigbtn(">>", "c=next", playing),
    })
    table.insert(v, vspan(math.floor(sh * 0.012)))
    local vol = state and state.volume
    table.insert(v, HorizontalGroup:new{ align = "center",
        smallbtn("-15s", "c=back15", playing),
        hspan(math.floor(pad / 3)),
        smallbtn("Vol -", "c=volume_down", state ~= nil),
        hspan(math.floor(pad / 3)),
        smallbtn("Vol +", "c=volume_up", state ~= nil),
        hspan(math.floor(pad / 3)),
        smallbtn("+15s", "c=fwd15", playing),
    })
    if vol then
        table.insert(v, vspan(8))
        table.insert(v, TextWidget:new{
            text = _("Volume") .. " " .. tostring(vol),
            face = Font:getFace("cfont", 16),
            fgcolor = Blitbuffer.COLOR_GRAY,
        })
    end

    -- close
    table.insert(v, vspan(math.floor(sh * 0.02)))
    if dark then
        local kd = self
        local cbtn = InputContainer:new{
            dimen = Geom:new{ w = math.floor(sw * 0.4), h = btn_h },
            CenterContainer:new{
                dimen = Geom:new{ w = math.floor(sw * 0.4), h = btn_h },
                TextWidget:new{ text = _("Close"), face = Font:getFace("cfont", 20), fgcolor = C_HI },
            },
        }
        cbtn.ges_events = {
            Tap = { GestureRange:new{ ges = "tap", range = function() return cbtn.dimen end } },
        }
        function cbtn:onTap() kd:closeDock() return true end
        table.insert(v, cbtn)
    else
        table.insert(v, Button:new{
            text = _("Close"),
            width = math.floor(sw * 0.4),
            height = btn_h,
            text_font_face = "cfont",
            text_font_size = 20,
            callback = function() self:closeDock() end,
        })
    end

    return v
end

function KindleDock:refreshScreen(refresh)
    if not self.root then return end
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
