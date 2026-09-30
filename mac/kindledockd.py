#!/usr/bin/env python3
"""kindledock daemon - serves system now-playing state from a Mac and accepts
remote control commands. Designed to be polled by the KOReader plugin.

Data source: media-control (https://github.com/ungive/media-control), which reads
macOS's system now-playing layer (works for Music, Spotify, browser video, ...).
Volume: AppleScript system output volume.

Endpoints:
  GET  /status                      no auth - {"ok": true}
  GET  /nowplaying                  auth - JSON now-playing snapshot
  GET  /artwork.png?track=<id>      auth - PNG artwork (cached, resized)
  POST /cmd?c=toggle|play|pause|next|prev|back15|fwd15
  POST /cmd?c=set_volume&v=0-100 | volume_up | volume_down

Config: ~/.config/kindledock/config.json {"port": 8931, "token": "<auto>"}
"""
import json, os, subprocess, hashlib, threading, time, secrets, base64, re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs
import urllib.request

CFG_DIR = os.path.expanduser("~/.config/kindledock")
RUN_DIR = os.path.expanduser("~/.local/share/kindledock")
CFG_PATH = os.path.join(CFG_DIR, "config.json")
os.makedirs(CFG_DIR, exist_ok=True)
os.makedirs(RUN_DIR, exist_ok=True)

def load_config():
    cfg = {}
    if os.path.exists(CFG_PATH):
        cfg = json.load(open(CFG_PATH))
    changed = False
    if "token" not in cfg:
        cfg["token"] = secrets.token_hex(20); changed = True
    if "port" not in cfg:
        cfg["port"] = 8931; changed = True
    if changed:
        fd = os.open(CFG_PATH, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        os.write(fd, json.dumps(cfg, indent=2).encode()); os.close(fd)
    return cfg

CFG = load_config()
TOKEN, PORT = CFG["token"], int(CFG["port"])

def find_media_control():
    if os.environ.get("MEDIA_CONTROL"):
        return os.environ["MEDIA_CONTROL"]
    for p in ("/opt/homebrew/bin/media-control", "/usr/local/bin/media-control"):
        if os.path.exists(p):
            return p
    return "media-control"

MEDIA_CONTROL = find_media_control()

def mc(*args, timeout=8):
    p = subprocess.run([MEDIA_CONTROL, *args], capture_output=True, text=True, timeout=timeout)
    return p.returncode, p.stdout.strip(), p.stderr.strip()

def osa(script, timeout=8):
    p = subprocess.run(["osascript", "-e", script], capture_output=True, text=True, timeout=timeout)
    return p.returncode, p.stdout.strip(), p.stderr.strip()

def get_volume():
    rc, out, _ = osa("output volume of (get volume settings)")
    try: return int(out)
    except ValueError: return None

def nowplaying():
    rc, out, err = mc("get")
    if rc != 0 or not out:
        return {"state": "idle", "volume": get_volume(), "server_time": time.time()}
    try:
        j = json.loads(out)
    except json.JSONDecodeError:
        return {"state": "idle", "volume": get_volume(), "server_time": time.time()}
    pos = j.get("elapsedTime") or 0.0
    rate = j.get("playbackRate") or 0.0
    if j.get("playing") and rate and j.get("timestamp"):
        try:
            from datetime import datetime, timezone
            ts = datetime.strptime(j["timestamp"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
            pos += (datetime.now(timezone.utc) - ts).total_seconds() * rate
        except Exception:
            pass
    dur = j.get("duration") or 0.0
    if dur and pos > dur: pos = dur
    LAST_APP[0] = j.get("bundleIdentifier")
    uid = j.get("uniqueIdentifier")
    track_id = ("%x" % (uid & 0xFFFFFFFFFFFF)) if isinstance(uid, int) else None
    if not track_id and j.get("title"):
        track_id = hashlib.md5(((j.get("title") or "") + "|" + (j.get("artist") or "")).encode()).hexdigest()[:12]
    return {
        "state": "playing" if j.get("playing") else ("paused" if j.get("title") else "idle"),
        "track": j.get("title"), "artist": j.get("artist"), "album": j.get("album"),
        "duration": round(dur, 1), "position": round(pos, 1),
        "app": j.get("bundleIdentifier"), "media_type": j.get("mediaType"),
        "volume": get_volume(),
        "has_artwork": bool(j.get("artworkData")) or (j.get("bundleIdentifier") in BROWSERS),
        "track_id": track_id, "server_time": round(time.time(), 1),
    }


BROWSERS = {
    "com.google.Chrome": ("Google Chrome", "URL of active tab of front window"),
    "com.brave.Browser": ("Brave Browser", "URL of active tab of front window"),
    "com.microsoft.edgemac": ("Microsoft Edge", "URL of active tab of front window"),
    "com.vivaldi.Vivaldi": ("Vivaldi", "URL of active tab of front window"),
    "company.thebrowser.Browser": ("Arc", "URL of active tab of front window"),
    "com.apple.Safari": ("Safari", "URL of front document"),
}
_YT_RE = re.compile(r"(?:youtube\.com/(?:watch\?[^#]*v=|shorts/|embed/|live/)|youtu\.be/)([A-Za-z0-9_-]{11})")
LAST_APP = [None]

def tab_url(app):
    b = BROWSERS.get(app or "")
    if not b: return None
    rc, out, _ = osa('tell application "%s" to get %s' % b)
    if rc != 0: return None
    u = out.strip()
    return u if u.startswith("http") else None

def yt_thumb_jpg():
    u = tab_url(LAST_APP[0])
    if not u: return None
    m = _YT_RE.search(u)
    if not m: return None
    vid = m.group(1)
    for name in ("maxresdefault", "hqdefault"):
        try:
            req = urllib.request.Request(
                "https://i.ytimg.com/vi/%s/%s.jpg" % (vid, name),
                headers={"User-Agent": "Mozilla/5.0"})
            with urllib.request.urlopen(req, timeout=8) as r:
                data = r.read()
            if name == "maxresdefault" and len(data) < 5000:
                continue  # placeholder image when maxres missing
            if len(data) < 1000: continue
            return data
        except Exception:
            continue
    return None


def browser_seek(delta):
    b = BROWSERS.get(LAST_APP[0] or "")
    if not b: return False, "not a browser"
    name = b[0]
    js = ("(function(){var v=document.querySelector('video');"
          "if(v){v.currentTime=Math.max(0,Math.min(v.duration||1e9,v.currentTime+(%d)));return 'ok'}"
          "return 'no'}())" % delta)
    if name == "Safari":
        script = ('tell application "Safari"\n'
                  'repeat with w in windows\nrepeat with t in tabs of w\ntry\n'
                  'set r to (do JavaScript "%s" in t)\n'
                  'if r is "ok" then return "ok"\n'
                  'end try\nend repeat\nend repeat\nreturn "novideo"\nend tell' % js)
    else:
        script = ('tell application "%s"\n'
                  'repeat with w in windows\nrepeat with t in tabs of w\ntry\n'
                  'set r to (execute t javascript "%s")\n'
                  'if r is "ok" then return "ok"\n'
                  'end try\nend repeat\nend repeat\nreturn "novideo"\nend tell' % (name, js))
    rc, out, _ = osa(script, timeout=20)
    ok = rc == 0 and out.strip() == "ok"
    return ok, ("" if ok else ("no <video> in any tab" if rc == 0 else "applescript rc %d" % rc))

_art_lock = threading.Lock()
def artwork_png(track_id):
    """Fetch artwork via media-control, convert to <=640px PNG, cache per track_id."""
    marker = os.path.join(RUN_DIR, "art_id")
    png = os.path.join(RUN_DIR, "art.png")
    raw = os.path.join(RUN_DIR, "art_raw")
    with _art_lock:
        if track_id and os.path.exists(png) and os.path.exists(marker):
            if open(marker).read().strip() == track_id:
                with open(png, "rb") as f: return f.read()
        blob = None
        if LAST_APP[0] in BROWSERS:
            blob = yt_thumb_jpg()
        if blob is None:
            rc, out, _ = mc("get", timeout=15)
            if rc != 0: return None
            try:
                data = json.loads(out).get("artworkData")
            except json.JSONDecodeError:
                return None
            if not data: return None
            blob = base64.b64decode(data)
        with open(raw, "wb") as f:
            f.write(blob)
        p = subprocess.run(["sips", "-s", "format", "png", "-Z", "640", raw, "--out", png],
                           capture_output=True, timeout=20)
        if p.returncode != 0 or not os.path.exists(png): return None
        if track_id:
            with open(marker, "w") as f: f.write(track_id)
        with open(png, "rb") as f: return f.read()

MC_COMMANDS = {
    "toggle": ["toggle-play-pause"], "play": ["play"], "pause": ["pause"],
    "next": ["next-track"], "prev": ["previous-track"],
    "back15": ["go-back-fifteen-seconds"], "fwd15": ["skip-fifteen-seconds"],
    "toggle_shuffle": ["toggle-shuffle"], "toggle_repeat": ["toggle-repeat"],
}

def run_command(qs):
    c = qs.get("c", [""])[0]
    if c in ("back15", "fwd15") and LAST_APP[0] in BROWSERS:
        ok, err = browser_seek(-15 if c == "back15" else 15)
        if ok: return {"ok": True}
        rc, _, err2 = mc(*MC_COMMANDS[c])
        return {"ok": rc == 0, "err": (err2[:200] if rc else err)}
    if c in MC_COMMANDS:
        rc, _, err = mc(*MC_COMMANDS[c])
        return {"ok": rc == 0, "err": err[:200] if rc else ""}
    if c == "seek":
        try: s = max(0.0, float(qs.get("to", [""])[0]))
        except ValueError: return {"ok": False, "err": "bad pos"}
        rc, _, err = mc("seek", str(s))
        return {"ok": rc == 0, "err": err[:200] if rc else ""}
    if c == "set_volume":
        try: v = max(0, min(100, int(qs.get("v", [""])[0])))
        except ValueError: return {"ok": False, "err": "bad volume"}
        rc, _, err = osa(f"set volume output volume {v}")
        return {"ok": rc == 0, "err": err[:200] if rc else "", "volume": v}
    if c in ("volume_up", "volume_down"):
        cur = get_volume() or 50
        v = max(0, min(100, cur + (5 if c == "volume_up" else -5)))
        rc, _, err = osa(f"set volume output volume {v}")
        return {"ok": rc == 0, "err": err[:200] if rc else "", "volume": v}
    return {"ok": False, "err": "unknown command"}

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _auth_ok(self):
        return self.headers.get("Authorization", "") == "Bearer " + TOKEN
    def _json(self, obj, code=200):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def do_GET(self):
        try:
            return self._do_GET()
        except Exception as e:
            return self._json({"ok": False, "err": str(e)[:300]}, 500)
    def _do_GET(self):
        u = urlparse(self.path)
        if u.path == "/status":
            return self._json({"ok": True, "service": "kindledock", "ts": time.time()})
        if not self._auth_ok():
            return self._json({"ok": False, "err": "auth"}, 403)
        if u.path == "/nowplaying":
            return self._json(nowplaying())
        if u.path == "/artwork.png":
            tid = parse_qs(u.query).get("track", [""])[0]
            data = artwork_png(tid)
            if data is None:
                return self._json({"ok": False, "err": "no artwork"}, 404)
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            return self.wfile.write(data)
        return self._json({"ok": False, "err": "not found"}, 404)
    def do_POST(self):
        try:
            return self._do_POST()
        except Exception as e:
            return self._json({"ok": False, "err": str(e)[:300]}, 500)
    def _do_POST(self):
        u = urlparse(self.path)
        if not self._auth_ok():
            return self._json({"ok": False, "err": "auth"}, 403)
        if u.path == "/cmd":
            return self._json(run_command(parse_qs(u.query)))
        return self._json({"ok": False, "err": "not found"}, 404)

if __name__ == "__main__":
    srv = ThreadingHTTPServer(("0.0.0.0", PORT), H)
    print(f"kindledock on :{PORT}")
    srv.serve_forever()
