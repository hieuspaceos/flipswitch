# Phase 3 — Toggle set per rea/notes/oneswitch.md

In scope (public APIs only):
1. **Hide Dock** — `defaults write com.apple.dock autohide -bool` +
   `killall Dock` (or `cfprefsd` flush).
2. **Mute Speakers** — osascript `set volume output muted`, probe
   `output muted of (get volume settings)`.
3. **Wi-Fi** — detect interface once at init via
   `networksetup -listallhardwareports` (port == "Wi-Fi"),
   flip `-setairportpower <dev>`, probe `-getairportpower <dev>` contains On.
4. **Bluetooth** — `blueutil -p toggle`; `available` = `which blueutil`.
   Hidden when absent.
5. **Empty Pasteboard** — `NSPasteboard.general.clearContents()`; action.
6. **Do Not Disturb** — experimental: run `shortcuts run` if a user
   shortcut named "Toggle DND" exists (`shortcuts list` check);
   `available` = that check.
7. **Night Shift** — same pattern via "Toggle Night Shift" shortcut.
8. **Low Power Mode** — `pmset -a lowpowermode` needs sudo;
   experimental tile, probe `pmset -g | grep lowpowermode`.

Model change: `SwitchItem` adds `available: () -> Bool` and
`experimental: Bool`; PanelView filters `toggles.filter { $0.available() }`.
Mute Mic moves from osascript to `AVCaptureDevice` input volume —
`AVCaptureDevice.default(for: .audio)` + `setMasterVolume` — removes the
last render-path-ish subprocess entirely.
