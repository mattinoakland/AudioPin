# AudioPin

Tiny macOS menu bar app (Swift, SwiftUI, Core Audio, no dependencies) that pins
default audio output/input devices so macOS can't auto-switch them. See README.md.

- Build: `make run` (SwiftPM + build.sh assembles `build/AudioPin.app`, ad-hoc signed). No .xcodeproj; open Package.swift in Xcode to edit.
- `Resources/Info.plist` is copied into the bundle by build.sh. `LSUIElement` makes it menu-bar only.
- Pins are stored by device UID in UserDefaults (domain `com.mattmoglia.AudioPin`).
- Logs: `make logs` (os_log subsystem `com.mattmoglia.AudioPin`; info level, so `log show` needs `--info`; use `/usr/bin/log`, zsh shadows `log`).
- Phase 2 (per-app routing via process taps) is intentionally not built; see README.
