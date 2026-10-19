# flipswitch

A free One-Switch-style menubar toggle panel for macOS — one click on the
menubar icon opens a grid of system toggles. Menubar agent (no Dock icon),
Swift + SwiftUI, public APIs only, zero dependencies.

## Switches

| Toggle | What it does |
|---|---|
| **Hide Desktop Icons** | `com.apple.finder CreateDesktop` off + Finder restart |
| **Show Hidden Files** | `AppleShowAllFiles` on + Finder restart |
| **Keep Awake** | `caffeinate -d` — display never sleeps while on |
| **Dark Mode** | System appearance via System Events |
| **Mute Microphone** | Input volume → 0, restores previous level |
| **Lock Screen** | `CGSession -suspend` |
| **Sleep Display** | `pmset displaysleepnow` |
| **Empty Trash** | Finder empty trash |

Tiles tint per category, show ON state on a mini switch, hover highlight,
and a search field filters the list live.

## Build & run

```sh
make        # builds Build/flipswitch.app (ad-hoc signed)
make run
make clean
```

macOS 14+, arm64, Xcode toolchain.

## Permissions

- **Automation / Apple Events**: Dark Mode and Empty Trash drive Finder and
  System Events via AppleScript — macOS prompts on first toggle.
- Everything else uses `defaults`, `pmset`, `caffeinate`, or `CGSession`.

## Notes

- v1 covers the public-API subset of One Switch. Dropped: AirPods connect,
  True Tone, Night Shift, resolution cycling, per-switch hotkeys, XPC
  helper — see `../rea/notes/oneswitch.md` for the full inventory.
- Launch at login: add the app in System Settings → Login Items.
