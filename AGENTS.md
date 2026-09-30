# AGENTS.md - set up kindledock end to end

This file is written for a coding agent. Follow it top to bottom and you will have a working kindledock install. Everything is verifiable at each step - run the verification commands and do not move on until they pass.

## Prerequisites

- A jailbroken Kindle with KOReader installed and SSH access (KOReader's SSH server plugin, port 2222 by default on recent KOReader)
- A Mac running macOS, with Python 3 (system Python is fine - the daemon uses only the stdlib)
- Network reachability between the two. If the LAN is CGNAT (100.64.0.0/10) or you want it to work remotely, install Tailscale on both and use the Tailscale IPs

## Step 1 - Mac daemon

1. Copy `mac/kindledockd.py` to `~/kindledock/kindledockd.py`.
2. Install media-control: `brew install media-control`. Verify: `media-control stream --no-diff` prints JSON while media plays.
3. For browser seek support (YouTube ±15s): in Chrome, enable View > Developer > Allow JavaScript from Apple Events. Approve the Automation permission the first time the daemon drives Chrome.
4. Install the launchd agent: copy `install/com.kindledock.daemon.plist` to `~/Library/LaunchAgents/`, edit the paths inside to match where you put the script and log, then `launchctl load ~/Library/LaunchAgents/com.kindledock.daemon.plist`.
5. First run creates `~/.config/kindledock/config.json` with `{"port": 8931, "token": "<random>"}`.
6. Verify: `curl -s -H "Authorization: Bearer <token>" http://localhost:8931/nowplaying` returns JSON while something plays. `curl -s -X POST -H "Authorization: Bearer <token>" "http://localhost:8931/cmd?c=toggle"` toggles playback. `curl -s -H "Authorization: Bearer <token>" http://localhost:8931/outputs` lists sound outputs with the current one marked.

## Step 2 - Kindle plugin

1. From the Mac: `scp -P 2222 -r koreader/kindledock.koplugin root@<kindle-ip>:/mnt/us/koreader/plugins/`
2. SSH in (`ssh -p 2222 root@<kindle-ip>`) and create `/mnt/us/koreader/settings/kindledock.lua` - or just open the plugin's settings dialog after first launch and enter: Mac host (IP or Tailscale hostname), port 8931, and the token from the Mac's config.json.
3. Restart KOReader: `killall -9 luajit; sleep 2; cd /mnt/us/koreader && setsid sh -c 'exec ./koreader.sh' </dev/null >/tmp/ko.log 2>&1 &`
   - NEVER use `pkill -f koreader.sh` over SSH - the pattern matches your own SSH session's remote command and kills your connection mid-restart.
4. Verify: in KOReader, open the hamburger menu > Tools > More tools > Now Playing. The dock opens and shows the current track. Tap = open player, hold = settings.

## Step 3 - Gesture (optional but recommended)

Bind a gesture to open the dock from anywhere:

1. Back up: `cp /mnt/us/koreader/settings/gestures.lua /mnt/us/koreader/settings/gestures.lua.bak`
2. In both the `gesture_fm` and `gesture_reader` sections, set a free gesture to the action, e.g.: `one_finger_swipe_top_edge_right = {kindledock_open = true,},`
3. Restart KOReader as above. Swiping right along the top edge now opens Now Playing.
4. Or do it in the UI: Gesture manager > pick a gesture > Device (or General) > "KindleDock: open Now Playing".

## Step 4 - Theme

The dock defaults to a dark (true-black) theme. For light, or auto (dark from 19:00 to 07:00), add `["theme"] = "light",` or `["theme"] = "auto",` to `/mnt/us/koreader/settings/kindledock.lua` and restart KOReader.

## Step 5 - Dock behavior

While docked and plugged in, you want the Kindle awake and reachable. KOReader: Settings > Screen > turn off autosuspend, or use the keepalive approach described in docs/sleep-wake.md. When undocked, re-enable normal sleep for battery life.

## Troubleshooting

- Dock shows nothing: check the Kindle can reach the Mac (`curl` the daemon from the Kindle's shell), and that the token matches.
- No thumbnail for browser media: normal for some players; YouTube gets thumbnails via the tab URL. The daemon falls back to a placeholder.
- Controls do nothing in Chrome: the "Allow JavaScript from Apple Events" toggle and the macOS Automation prompt are both required.
- KOReader won't come back after a restart: you probably killed your SSH session with `pkill -f` - see step 2.3. Power-cycle the Kindle if needed; boot persistence (KOReader at boot) is out of scope for this plugin and is covered in docs/sleep-wake.md.
