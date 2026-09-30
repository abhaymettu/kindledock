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

## Prior-art survey, continued (2026-09-29)

More existing solutions and what they establish, from the user's "look at the
already built solutions" ask:

- **kindle-dash forks**: ramLlama's Rust rewrite of kindle-dash (single static
  binary, lower memory) confirms the fetch-suspend pattern is worth
  reimplementing per device generation; nothing about it conflicts with the
  rendezvous design.
- **CyberPixel44/kindle-remote** (github.com/CyberPixel44/kindle-remote): an
  ESP32 wired to the Kindle that physically injects input/wake. Proves the
  hardware fallback: if software RTC wake ever proves unreliable on the 2024
  firmware, an MCU on the power/button line is the established escape hatch.
  We avoid it - the Kindle already has an RTC and a power controller.
- **MobileRead RTC wake threads**: t=322900 (+ post 3895087) shows working RTC
  wakeup on the KT4/PW5 generation via the rtcwake / /dev/rtc0 alarm path;
  t=351128 has a K4 sleep/wake script; t=141323 "wake at given time" covers
  the same alarm registers. Consensus across generations: the RTC alarm is
  settable from userspace and survives suspend; the differences are which
  sysfs node the firmware exposes.
- **MobileRead t=235821 / t=268453**: power/sleep/wakeup state machines on
  recent firmware; documents that lipc powerd events (charging, button,
  hall sensor) are the reliable wake sources, and that `preventScreenSaver`
  keeps the device in shallow wake where Wi-Fi stays associated.
- **MobileRead t=367800**: listening for lipc events from userspace - the
  pattern our dockkeepalive already uses (watch AC state, flip
  preventScreenSaver). Confirms the docked-mode design matches what the
  community converged on.
- **KOReader issue #14453** ("Koreader will not wake after suspend"): a live
  reminder that wake behavior is firmware-fragile; the duty-cycle design must
  degrade gracefully - if an RTC wake is missed, the next charger attach or
  button press is the fallback rendezvous, never a brick.
- **HN item?id=28605638** (remote page-turning thread): the community's
  appetite for remote Kindle control is real; the approaches there are all
  "keep the Kindle awake and reachable", which is exactly the battery cost
  the duty-cycle avoids.
- **SwitchBot / button-pushers** (us.switch-bot.com/products/switchbot-remote):
  the consumer-hardware answer to the same problem - a motor that presses the
  power button. Works on any firmware, costs a gadget per Kindle, and can't
  open a UI or sync state. Strictly a fallback for non-jailbroken devices.
- **USB power-cycle wake**: inserting USB power generates a lipc charger
  event that wakes the device from suspend on current firmware (the same
  event dockkeepalive watches). A smart plug cycling USB power is therefore
  a crude remote wake: power on -> Kindle wakes -> Wi-Fi -> rendezvous.
  Latency is the smart plug's, and repeated power cycling is inelegant, but
  it is zero-install and worth documenting as the no-jailbreak path.

### Where this lands

No existing solution does "asleep Kindle becomes a live controller on
demand": kindle-dash wakes on its own schedule to refresh a passive display,
KindleCron runs jobs, KOReader's wakeup_mgr runs local tasks, and everything
else keeps the device awake. The rendezvous design (§ above) is the piece
none of them have: the wake is cheap because staying awake is the exception.
Docked, none of this matters - keepalive wins, which is what shipped.
