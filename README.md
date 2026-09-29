# kindledock

Turn a jailbroken Kindle into a now-playing display and remote control for your Mac.

Your Mac already knows what's playing - system-wide, for any app: Apple Music,
Spotify, YouTube in a browser, anything that shows up in the macOS Control Center
now-playing tile. kindledock serves that state over your LAN/Tailscale, and a
KOReader plugin renders it on the Kindle's e-ink screen: cover art, track info,
progress, and playback controls. No audio on the Kindle - it's a remote, not a
speaker. Latency is a second or two and that's fine.

![screenshot](docs/screenshot.png)

## What you get

- Cover art, title / artist / album, progress bar, app badge
- Play / pause / previous / next
- -15s / +15s skip
- System volume up / down
- Works for whatever the Mac is playing, not just one app
- Clean e-ink layout (designed for a 1072x1448 Kindle, adapts to other sizes)

## How it works

```
[ any app on the Mac ]
        |  macOS now-playing (via media-control)
        v
 kindledockd.py  --(launchd, port 8931)-->  HTTP + bearer token
        |                                       |
        v                                       v
   Apple Music etc.                    KOReader plugin (Kindle)
   (playback + volume)                polls /nowplaying every 3s,
                                       sends /cmd on button taps
```

The Mac side reads the system now-playing layer with
[media-control](https://github.com/ungive/media-control) - macOS 15.4 broke the
old private-framework path, media-control is the maintained workaround. Volume
goes through AppleScript. The Kindle side is pure Lua inside KOReader.

## Install

### Mac

```sh
brew tap ungive/media-control && brew install media-control
cp mac/kindledockd.py ~/kindledockd.py
# edit install/com.kindledock.daemon.plist path if needed, then:
cp install/com.kindledock.daemon.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.kindledock.daemon.plist
cat ~/.config/kindledock/config.json   # <- your token and port
```

### Kindle (jailbroken, KOReader)

Copy `koreader/kindledock.koplugin` into `/mnt/us/koreader/plugins/`, restart
KOReader, then open Kindle Dock from the tools menu and enter the Mac's address
(IP or Tailscale hostname), port, and token. Both devices just need to reach
each other - same Wi-Fi, or Tailscale.

## Configuration

- Mac: `~/.config/kindledock/config.json` (`port`, `token` - auto-generated on
  first run). Runtime files (artwork cache, log) in `~/.local/share/kindledock/`.
- Kindle: settings are stored by the plugin in KOReader's settings directory
  (`kindledock.lua`).

## Roadmap

- Duty-cycled RTC wake so the Kindle can sleep yet still be reachable
  (see docs/sleep-wake.md for the research)
- Auto-open on playback start
- Seek by tapping the progress bar

## License

MIT
