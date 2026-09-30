--[[
Bookshelf micro-module: what the Mac is playing, from kindledock's daemon.
Drop into <koreader>/settings/bookshelf/micromodules/ (needs kindledock.koplugin
configured; it reuses that plugin's host/port/token). Tap opens the full dock.

The fetch runs in a scheduled task, never in render; the card re-renders once a
minute (wants_minute_tick), which is enough for a glance.
]]
local _ = require("lib/bookshelf_i18n").gettext

local STALE_SECONDS = 50
local state, fetched_at, fetching = nil, 0, false

local function fetch()
    local LuaSettings = require("luasettings")
    local DataStorage = require("datastorage")
    local cfg = LuaSettings:open(DataStorage:getSettingsDir() .. "/kindledock.lua")
    local host = cfg:readSetting("host")
    if not host or host == "" then return { err = _("Set up Now Playing first") } end
    local http, ltn12, json = require("socket.http"), require("ltn12"), require("json")
    local body = {}
    http.TIMEOUT = 3
    local ok, one, code = pcall(http.request, {
        url = "http://" .. host .. ":" .. tostring(cfg:readSetting("port") or 8931) .. "/nowplaying",
        headers = { Authorization = "Bearer " .. (cfg:readSetting("token") or "") },
        sink = ltn12.sink.table(body),
    })
    if not ok or one == nil or code ~= 200 then return { err = _("Mac unreachable") } end
    local okj, s = pcall(json.decode, table.concat(body))
    return (okj and type(s) == "table") and s or { err = _("Mac unreachable") }
end

return {
    key = "kindledock_now_playing", -- stable id stored in user menus; never change it
    title = _("Now playing"),
    summary = _("From kindledock on your Mac. Needs the network."),
    wants_minute_tick = true,
    render = function(ctx)
        local Kit = require("lib/bookshelf_module_kit")
        local mw = math.max(50, ctx.width)
        if not ctx.preview and not fetching and os.time() - fetched_at > STALE_SECONDS then
            fetching = true
            local refresh = ctx.refresh
            require("ui/uimanager"):scheduleIn(0.1, function()
                state, fetched_at, fetching = fetch(), os.time(), false
                if refresh then refresh() end
            end)
        end
        local s = ctx.preview and { state = "playing", track = "Track", artist = "Artist" } or state
        local value, sub, bar = "…", nil, nil
        if s and s.err then
            value = s.err
        elseif s and (s.state == "playing" or s.state == "paused") then
            value = s.track or ""
            sub = (type(s.artist) == "string" and s.artist or "")
                .. (s.state == "paused" and ("  ·  " .. _("paused")) or "")
            if type(s.duration) == "number" and s.duration > 0 then
                bar = Kit.progressBar{ width = mw, height = Kit.sc(ctx.scale)(6),
                    fraction = math.min(1, (s.position or 0) / s.duration) }
            end
        elseif s then
            value = _("Nothing playing")
        end
        return Kit.valueCard{ width = mw, scale_pct = ctx.scale,
            heading = _("Now playing"), value = value, bar = bar, sub = sub }
    end,
    on_tap = function()
        -- broadcast, not Dispatcher: the dispatcher only reaches the top widget
        -- (Bookshelf), while the dock plugin lives on the FileManager/Reader
        local Event = require("ui/event")
        require("ui/uimanager"):broadcastEvent(Event:new("KindleDockOpen"))
    end,
}
