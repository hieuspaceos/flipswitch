# flipswitch

A free One-Switch-style menubar toggle panel for macOS. Click the menubar
icon → a Control-Center-style tile grid opens; each tile flips a real
system switch. Menubar agent (no Dock icon), Swift + SwiftUI, public APIs
only, zero dependencies.

## Toggles (15)

| Group | Toggle | Mechanism |
|---|---|---|
| System | **Hide Desktop Icons** | `com.apple.finder CreateDesktop` + Finder restart |
| | **Show Hidden Files** | `AppleShowAllFiles` + Finder restart |
| | **Dark Mode** | System Events appearance |
| | **Stage Manager** | `com.apple.WindowManager GloballyEnabled` |
| | **Hide Dock** | `com.apple.dock autohide` + Dock restart |
| Focus | **Do Not Disturb** | experimental — needs a user Shortcut named `Toggle DND` |
| | **Night Shift** | experimental — needs a user Shortcut named `Toggle Night Shift` |
| Media | **Mute Mic** | input volume → 0, restores previous level |
| | **Mute Speakers** | `set volume output muted` |
| | **Bluetooth** | `blueutil -p toggle` (hidden if not installed) |
| | **Wi-Fi** | `networksetup` on the detected Wi-Fi interface |
| Power | **Keep Awake** | `caffeinate -d` child process |
| | **Low Power** | `pmset -a lowpowermode` (needs admin) |
| Actions | **Clear Clipboard** | `NSPasteboard.clearContents()` |
| | **Lock** | ⌃⌘Q via System Events → fallback `pmset displaysleepnow` |
| | **Sleep** | `pmset displaysleepnow` |
| | **Empty Trash** | Finder empty trash |

Tiles whose dependencies are missing (blueutil, user-made Shortcuts) are
hidden rather than shown dead. Tiles flip with a 180° icon spin on tap;
hover shows a tooltip explaining what each switch does.

## UX

- Tile states probe **async on panel open** — no subprocess on the render
  path; opening the panel is instant.
- Action tiles (lock/sleep/trash/clipboard) never light up — they're
  one-shot, not switches.
- Search field filters tiles live. `⌘Q` quits; click outside closes.

## Build & run

```sh
make        # builds Build/flipswitch.app (ad-hoc signed)
make run
make clean
```

Requires macOS 14+, arm64. No third-party dependencies.

## Demo

`demo.mp4` — rendered by [demoreel](https://github.com/hieuspaceos/demoreel)
(`demos/flipswitch.swift`), deterministic 1080p60.

## Permissions

Mostly none. ⌃⌘Q lock and Dark Mode use System Events → macOS may ask for
**Accessibility** once.
## Security & trust

- **Open source** — every byte of the release binary is produced from the
  commit you can read, by GitHub Actions (see the workflow run linked in
  each release). No opaque build steps.
- **Checksums** — every release ships `flipswitch.dmg.sha256`. Verify:
  ```sh
  shasum -a 256 flipswitch.dmg
  ```
- **No telemetry, no account, no network calls** — the app works fully
  offline; nothing leaves your Mac.
- **Permissions** — flipswitch asks for none required — all toggles are public or user-triggered macOS APIs
  and nothing else.
- **Ad-hoc signed** — not yet notarized (needs a paid Apple Developer
  account). On first launch macOS shows "cannot be opened because the
  developer cannot be verified" — right-click → **Open** once, then it
  runs normally forever after.
- **Prefer building yourself?** `git clone`, `make`, `make run` —
  no external dependencies, readable in one sitting.
