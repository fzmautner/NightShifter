# Setting up NightShifter

**This document is written for a coding agent** (Claude Code, or similar) installing NightShifter
on its user's Mac. Work through it in order. It should take a couple of minutes.

If you are a human reading this: hand this file to your agent, or follow it yourself — the commands
are the same. You need the Xcode Command Line Tools (one command, ~1.8 GB) and nothing else. No
Xcode, no Apple Developer account, no payment.

---

## 0. Tell your user what this does, before you start

NightShifter replaces the Night Shift schedule macOS gives you. Say this much up front:

- It uses a **private Apple framework** (`CBBlueLightClient` in CoreBrightness). There is no public
  API for Night Shift; every app in this space uses it. It is not sandboxed and could break on a
  future macOS release. If it does, the app reports "not supported" rather than crashing.
- When the schedule is engaged it sets macOS's own Night Shift mode to **Off** and drives the
  warmth itself. System Settings will show Night Shift as unscheduled while it runs. Quitting the
  app hands the original mode back.
- It ships **disengaged**. Nothing touches the display until the user flips the toggle.

Do not engage the schedule on the user's behalf. Build it, launch it, and let them turn it on.

---

## 1. Check the machine can run it

**You do not need Xcode, and you do not need an Apple Developer account.** The Command Line Tools
are enough — verified on a clean clone: 33-second build, and the app launches. Nothing here costs
money or requires signing up for anything.

```bash
sw_vers                 # need ProductVersion 14.0 or later
swift --version         # need a working Swift toolchain
```

If `swift` is missing, install the Command Line Tools:

```bash
xcode-select --install
```

That opens an Apple dialog; the user clicks Install and waits. It is about **1.8 GB**. Full Xcode
is several times larger and buys nothing here — the Command Line Tools ship the Swift compiler,
SwiftPM, and the macOS SDK including SwiftUI and AppKit, which is the whole dependency list. `git`
comes with them too.

If the user already has Homebrew, they already have the Command Line Tools; skip straight to
step 2.

Apple silicon and Intel both work. Night Shift itself requires a Metal-capable Mac (roughly 2012
and later); if the Mac is older than that, stop here — nothing will work.

## 2. Build and launch

```bash
git clone https://github.com/fzmautner/NightShifter.git
cd NightShifter
./Scripts/bundle.sh release
open build/NightShifter.app
```

`bundle.sh` compiles with SwiftPM and assembles `build/NightShifter.app` with an ad-hoc signature.
Expect roughly half a minute on a first build.

**Gatekeeper is not a problem here.** It polices code that arrives from elsewhere — quarantined
downloads. A bundle compiled locally is never quarantined, so an ad-hoc signature is enough. This
is the whole reason the install is "build it yourself" rather than "download a .zip".

You may see a linker warning about `SwiftUICore` not being an allowed client. It is harmless and
the build still links. (It appears when building against full Xcode, not against the Command Line
Tools.)

Confirm it is alive:

```bash
pgrep -lf "NightShifter.app"
```

There is no Dock icon and no window — it is a menu bar app (`LSUIElement`). Look for a sun icon in
the menu bar. Tell the user to click it; you will not be able to open the panel yourself, because
`MenuBarExtra` panels dismiss when another process takes focus.

## 3. Verify the private API works on this Mac

This is the step that actually catches problems. It only reads.

```bash
cat > /tmp/ns_preflight.swift <<'SWIFT'
import Foundation
dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY)
guard let bl: AnyClass = NSClassFromString("CBBlueLightClient") else { print("FAIL: no CBBlueLightClient"); exit(1) }
let c = (bl as! NSObject.Type).init()
typealias FnBool = @convention(c) (AnyObject, Selector) -> ObjCBool
let sup = unsafeBitCast(method_getImplementation(class_getInstanceMethod(bl, Selector(("supported")))!), to: FnBool.self)
print("Night Shift supported: \(sup(c, Selector(("supported"))).boolValue)")

guard let bs: AnyClass = NSClassFromString("BrightnessSystemClient") else { print("FAIL: no BrightnessSystemClient"); exit(1) }
let b = (bs as! NSObject.Type).init()
typealias FnCopy = @convention(c) (AnyObject, Selector, CFString) -> Unmanaged<AnyObject>?
let sel = Selector(("copyPropertyForKey:"))
let copy = unsafeBitCast(method_getImplementation(class_getInstanceMethod(bs, sel)!), to: FnCopy.self)
if let r = copy(b, sel, "BlueLightSunSchedule" as CFString), let d = r.takeRetainedValue() as? [String: Any] {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm zzz"
    for k in ["sunrise", "sunset", "nextSunrise", "nextSunset"] {
        print("  \(k) = \((d[k] as? Date).map { f.string(from: $0) } ?? "MISSING")")
    }
} else { print("FAIL: no BlueLightSunSchedule — see step 4") }
SWIFT
swift /tmp/ns_preflight.swift
```

Expected:

```
Night Shift supported: true
  sunrise     = 2026-08-18 06:32 PDT
  sunset      = 2026-08-18 19:53 PDT
  nextSunrise = ...
  nextSunset  = ...
```

Sanity-check the times against the user's actual location. If they look like a different part of
the world, the OS has stale location data — step 4.

## 4. If the sun schedule is missing or wrong

The app reads sun times from macOS rather than asking for location permission itself. That means
macOS has to have computed them, which it only does once Location Services is on.

Have the user:

1. Turn on **System Settings → Privacy & Security → Location Services**, and within
   **Details… → System Services**, enable **Setting Time Zone**.
2. Open **System Settings → Displays → Night Shift**, set the schedule to **Sunset to Sunrise**
   once, and leave it a moment so macOS populates the schedule.

Re-run the preflight. Once real times appear, the Night Shift schedule can be set back to whatever
they like — NightShifter overrides it anyway once engaged.

Until times exist, the panel shows "Waiting for the system sun schedule…" and does nothing. This is
the single most likely reason a fresh install looks broken.

## 5. Start it at login (optional, but it needs to run to do anything)

```bash
osascript -e 'tell application "System Events" to make login item at end with properties {path:"'"$PWD"'/build/NightShifter.app", hidden:true}'
```

The app must be running for the schedule to apply — it is the thing driving the ramp. To remove it
later:

```bash
osascript -e 'tell application "System Events" to delete login item "NightShifter"'
```

Because the login item points at the build inside the clone, do not move or delete the folder.

## 6. Uninstalling

```bash
osascript -e 'tell application "System Events" to delete login item "NightShifter"' 2>/dev/null
pkill -f "NightShifter.app"
```

Quitting restores the Night Shift mode that was in place before the app engaged. If it was force
killed mid-run and Night Shift is left unscheduled, the user just sets their schedule again in
**System Settings → Displays → Night Shift**. Nothing is permanently changed, and preferences are
never written except when the schedule settles at full warmth.

Then delete the cloned folder.

---

## Notes for the installing agent

- **Do not enable the schedule for the user.** Build, launch, verify, and hand over.
- **Do not "fix" Night Shift by writing settings.** Reads are free; the app owns the writes.
- **You cannot screenshot the panel.** `MenuBarExtra(.window)` dismisses on focus change and does
  not respond to System Events clicks. Ask the user what they see instead of automating it.
- **If the build fails**, capture the first error and stop rather than editing sources — this is a
  fast-moving beta and the fix probably belongs upstream. Report it back.
