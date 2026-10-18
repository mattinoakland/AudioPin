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
works for debugging but launches without the app's `Info.plist`, so it can't
register as a login item. Use `make run` for the real thing.

If you use Bartender or a similar menu bar organizer, it may file AudioPin's
pushpin icon under a hidden section the first time; move it to the shown
section in that app.

## Using it

Click the pushpin icon in the menu bar. The panel stays open while you click
around in it; it closes when you click anywhere else, press Escape, or click
the icon again.

- **Now playing through** shows the current default output and input.
- **Pinned output** / **Pinned input** list every device. Check one to pin it.
  Checking a device applies it immediately. Uncheck or "Clear ... pin" to stop.
- If a pinned device is unplugged, the menu says "(not connected)" and AudioPin
  leaves macOS's choice alone until the device returns.
- A **volume slider** sits under the pinned output list and a **gain slider**
  under the pinned input list. They move the pinned device's own level, the
  same one the volume keys and Sound settings change. Devices without a
  software level (HDMI displays, for example) show a note instead.
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

## App routing (Phase 2)

Besides the system-wide pins, you can send one app's audio to a specific
device. Open the menu, go to **App routing**, pick an app, and choose a device.
"System default" removes the rule.

- Rules are saved per app and come back when the app relaunches.
- The submenu shows the live state: routing, waiting for the app to play
  audio, device not connected, or an error.
- Apps with a rule are listed first; apps that aren't running show
  "(not running)".
- Each routed app has a **Volume** slider under it. It scales the audio
  AudioPin sends to that device. When a routed device isn't the system output
  (so the volume keys can't reach it), AudioPin turns that device's own level
  up to 100% and scales the app's slider down by the same amount: nothing gets
  louder, but the slider now has headroom. The setting is saved with the rule. It scales the audio
  AudioPin sends to that device, so the Mac's volume keys (which control the
  pinned system output) and the device's own volume wheel both still work on
  top of it. The setting is saved with the rule.
- Quitting AudioPin, removing a rule, or unplugging the target device tears the
  route down, and the app goes back to playing through the system default.

Routed audio has a small delay (a few milliseconds). That doesn't matter for
music. Zoom isn't affected unless you route Zoom itself, so leave Zoom alone
and pick its devices inside Zoom.

## Download

Releases are at https://mattmoglia.com/audiopin and on this repo's Releases
page. Drag `AudioPin.app` to Applications and open it. Releases are signed with
a Developer ID and notarized by Apple, so there's no "unidentified developer"
step. Routing an app asks once for the system audio recording permission.

## Privacy

AudioPin sends one small anonymous ping when it starts and once a day: a
random install ID, the app version, the macOS version, the CPU type, and the
Mac's region setting (a two-letter country code). That's how Matt knows
roughly how many people use it and where, and it's how the app learns a newer
version exists. Nothing about your devices, apps, or audio is sent, ever.
Turn off **Send anonymous usage stats** in the panel to stop the ping; the
update check then runs without an install ID.

## Releasing (for Matt)

One-time setup:

1. In Xcode > Settings > Accounts, select your Apple ID and team, click
   **Manage Certificates**, then **+** > **Developer ID Application**. That
   installs the signing certificate in your keychain.
2. Make an app-specific password at https://account.apple.com (Sign-In and
   Security > App-Specific Passwords), then store it for the notary tool:

   ```bash
   xcrun notarytool store-credentials AudioPin --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID --password THE_APP_SPECIFIC_PASSWORD
   ```

   Your team ID is on https://developer.apple.com/account under Membership.

Every release after that is one command:

```bash
make release VERSION=1.1 NOTES="What changed"
```

It stamps the version, builds a universal app, signs it with the Developer ID
and hardened runtime, sends it to Apple for notarization (a few minutes),
staples the ticket, zips it, tags the commit, and publishes a GitHub release
with the zip attached. The download page and the in-app update banner both
read the latest GitHub release, so publishing is the only step.

For a quick unsigned build on your own Mac, `make run` still works.

## Permissions

Pinning (Phase 1) needs no permission.

App routing captures an app's audio, which macOS treats as system audio
recording. The first time you route an app, macOS asks for permission. If a
route shows "Couldn't tap this app", allow AudioPin under
System Settings > Privacy & Security > Screen & System Audio Recording and pick
the device again.

## How it works

- `AudioDeviceManager.swift` wraps Core Audio: enumerates devices
  (`kAudioHardwarePropertyDevices`), reads names and UIDs, reads and sets the
  default output / input / system-output devices, and registers HAL property
  listeners for device-list, default-device, and process-list changes.
- `AppState.swift` holds the pins (stored by device UID in `UserDefaults`, since
  device IDs change between reconnects), debounces HAL events by 300 ms, and
  applies the rule: if enforcing and a pinned device is connected but not the
  default, set it as the default. It also stores routing rules by bundle ID and
  watches app launches and quits.
- `ProcessTapRouter.swift` builds each route: a process tap on the app
  (`CATapDescription` + `AudioHardwareCreateProcessTap`, muting the app's
  normal output while tapped), a private aggregate device containing the tap
  and the target device, and an IOProc that copies tapped audio to the output.
- `MenuBarController.swift` owns the status item and the panel: a borderless
  `NSPanel` hung under the icon, closed by click-outside/Escape monitors.
  `PanelView.swift` is the SwiftUI content inside it. A panel instead of a
  menu is what lets it stay open after a click.
- `AudioPinApp.swift` is the entry point (an `NSApplicationDelegate`).

## Known limits

- Channel mapping is simple: the tap is a stereo mixdown; on a multichannel
  output only the first two channels carry audio.
- Sample-rate differences between the tapped app and the target device are
  handled by the aggregate device's drift compensation, which has been fine in
  testing but is the first place to look if routed audio ever sounds wrong.
