# Sleep, wake, and battery: the research

The dream spec is: Kindle asleep (battery-sipping), still on Wi-Fi, wakeable
on demand. On this hardware that exact trio does not exist - but something
close does.

## What suspend actually does

In suspend-to-RAM the Kindle's SoC halts and the Wi-Fi radio is powered down.
The only wake sources are the power button and the RTC alarm. No jailbroken
Kindle exposes Wake-on-WLAN. Anything that looks like "wake it over the
network" is shallow sleep (screen off, CPU + Wi-Fi running), which costs real
battery.

## What exists

- **kindle-dash** (pascalw, ~1.4k stars, MIT): the canonical low-power Kindle
  dashboard. Fetches an image over Wi-Fi, suspends to RAM until the next
  update. The duty-cycle pattern, proven for years.
- **KindleCron** (lennardollesch, 2026, Go, AGPL): cron for jailbroken Kindles
  that survives deep sleep, via RTC wake.
- **KOReader built-ins**: `keepalive.koplugin`
  (`lipc-set-prop com.lab126.powerd preventScreenSaver 1` - never sleeps),
  autosuspend/autostandby plugins, and `Device.wakeup_mgr`, an RTC-alarm task
  queue that runs a Lua task at a future epoch across suspend. A duty-cycled
  wake checker can be a pure KOReader plugin.
- MobileRead: suspend levels & SSH in shallow sleep (thread 221497),
  rtcWakeup mechanics (thread 268453).

## The design this points to

Duty-cycled wake with a wake-request rendezvous:

1. Kindle sleeps normally; before each suspend, arm RTC wake for now + N
   seconds (N = 60-300).
2. On wake, Wi-Fi reconnects (seconds); the Kindle GETs a tiny "should I stay
   up?" endpoint (the kindledock daemon on the Mac, or a flag on a server).
3. Flag set -> stay awake, open the dock UI, clear the flag at session end.
   Flag unset -> re-arm and go back to sleep.

Remote wake latency is at most N. Battery cost is one resume + Wi-Fi reconnect
per cycle - on the order of a percent or two a day at five-minute cycles,
versus weeks of standby when fully asleep. And on USB power, skip the dance
entirely: keepalive mode, always on.
