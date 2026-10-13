-- One-tap catalog refresh and current-document progress push.
-- Install alongside now_playing.lua in settings/bookshelf/micromodules/.
local _ = require("lib/bookshelf_i18n").gettext
return {
    key = "kindledock_sync_now",
    title = _("Sync now"),
    summary = _("Refresh your book catalog and push the open book's progress."),
    render = function(ctx)
        return require("lib/bookshelf_module_kit").valueCard{
            width = math.max(50, ctx.width), scale_pct = ctx.scale,
            heading = _("Books & progress"), value = _("Sync now"),
            sub = _("Refresh catalog · push open book"),
        }
    end,
    on_tap = function()
        require("ui/uimanager"):broadcastEvent(require("ui/event"):new("KindleDockSync"))
    end,
}
