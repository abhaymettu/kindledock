# kindledock

Turn a jailbroken Kindle into an always-on now-playing display and remote control for the music playing on your Mac.

![kindledock on a Kindle](docs/screenshot.png)

## What it does

- Shows what's playing on your Mac - track, artist, album art - on a clean e-ink UI that looks native to the device
- Works system-wide: Apple Music, Spotify, and browser audio (YouTube included) via [media-control](https://github.com/ungive/media-control); YouTube gets real video thumbnails
- Controls playback from the Kindle: play/pause, next/previous, ±15s seek, volume
- Runs as a KOReader plugin: open it from Tools > More tools > Now Playing, or bind a gesture (e.g. swipe right along the top edge) to open it anywhere
- Zero-touch: the Mac daemon starts at login (launchd), KOReader starts at boot on the Kindle, and the two reconnect on their own over your LAN or Tailscale
- The Kindle never sleeps while docked, so it's always reachable and always showing the current track

The Kindle is a display and remote only - audio keeps playing on the Mac.

## How it works

```
kindledock.koplugin (KOReader, on the Kindle)
        |  HTTP GET /now-playing  (poll)
        |  HTTP POST /cmd         (play/pause/seek/volume)
        v
kindledockd.py (launchd agent, port 8931, on the Mac)
        |  media-control stream   (now-playing state, system-wide)
        |  AppleScript / media keys (playback control)
```

The daemon bears a token (auto-generated on first run, `~/.config/kindledock/config.json`); the plugin presents it on every request. Both devices just need to reach each other - same LAN, or Tailscale if your LAN is CGNAT or you want it to work away from home.

## Setup

The full end-to-end setup - written so a coding agent can do it for you - is in [AGENTS.md](AGENTS.md).

## Docs

- [docs/sleep-wake.md](docs/sleep-wake.md) - research on Kindle sleep/wake behavior, boot persistence, and prior art in this space

## Requirements

- A jailbroken Kindle with [KOReader](https://github.com/koreader/koreader) installed
- A Mac (the daemon uses macOS media APIs and AppleScript)

## License

MIT - see [LICENSE](LICENSE).
