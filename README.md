# AudioPin

A tiny macOS menu bar app that keeps your audio devices where you put them.

**The problem it solves:** macOS switches the default output to a USB headset
whenever it's plugged in, which moves your music to the headset. AudioPin lets
you *pin* an output device (MacBook Pro Speakers) and an input device (the
headset mic). Whenever macOS changes the defaults or a device reconnects,
AudioPin puts the pinned devices back within about a third of a second.

- No third-party dependencies. Swift + SwiftUI + Core Audio only.
- macOS 14.2 or later, Apple Silicon.
- Menu bar only (no Dock icon). Optional launch at login.

## Build and run

Requires Xcode (command line tools are enough for `swift build`).

```bash
make run
```

That builds `build/AudioPin.app` with SwiftPM, ad-hoc signs it, and opens it.
A speaker icon appears in the menu bar.

To keep it around permanently:

```bash
make install
```

This copies it to `/Applications` and launches it from there. Launch-at-login
works most reliably from `/Applications`.

Other targets: `make stop`, `make uninstall`, `make clean`, `make logs`
(streams the app's log lines via /usr/bin/log, since zsh has a `log` builtin; the same lines are visible in Console.app under
subsystem `com.mattmoglia.AudioPin`).

### Opening in Xcode

Open `Package.swift` in Xcode to browse and edit the code. Running from Xcode
works for debugging but launches without the app's `Info.plist`, so it shows a
Dock icon and can't register as a login item. Use `make run` for the real thing.

## Using it

Click the speaker icon in the menu bar:

- **Now playing through** shows the current default output and input.
- **Pinned output** / **Pinned input** list every device. Check one to pin it.
  Checking a device applies it immediately. Uncheck or "Clear ... pin" to stop.
- If a pinned device is unplugged, the menu says "(not connected)" and AudioPin
  leaves macOS's choice alone until the device returns.
- **Enforce pins** (on by default) is the master switch. Turn it off to let
  macOS do whatever it wants while keeping your pins saved. The icon is filled
  when enforcing, outlined when not.
- **Launch at login** registers AudioPin as a login item. The first time, macOS
  may show a notice that a background item was added; that's expected.
  If the menu says approval is needed, allow it under
  System Settings > General > Login Items & Extensions.
- **Refresh devices** re-reads the device list by hand (rarely needed).

Pins also cover the "sound effects" output, so alerts follow your music.

To change which device you want, pick it in the AudioPin menu rather than in
System Settings. If you switch in System Settings while a pin is set, AudioPin
switches it back.

## Permissions

Phase 1 needs no special permissions. Reading and setting default audio
devices is allowed for any app.

## How it works

- `AudioDeviceManager.swift` wraps Core Audio: enumerates devices
  (`kAudioHardwarePropertyDevices`), reads names and UIDs, reads and sets the
  default output / input / system-output devices, and registers HAL property
  listeners for device-list and default-device changes.
- `AppState.swift` holds the pins (stored by device UID in `UserDefaults`, since
  device IDs change between reconnects), debounces HAL events by 300 ms, and
  applies the rule: if enforcing and a pinned device is connected but not the
  default, set it as the default.
- `MenuBarView.swift` is the dropdown. `AudioPinApp.swift` is the entry point.

## Phase 2 (not built yet)

Per-app routing (send only Apple Music to a specific device) would use the
macOS 14.2 process-tap API (`CATapDescription`, `AudioHardwareCreateProcessTap`)
plus a private aggregate device. It needs the system audio recording
permission, adds a small latency to the routed app's audio, and is a lot more
code. Try Phase 1 first; for the headset-vs-speakers problem it is usually
enough.
