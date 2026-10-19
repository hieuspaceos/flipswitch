# flipswitch — harden + Control-Center UI + full toggle set

## Contract
- **Outcome**: popover <50ms; no subprocess on render; 14 toggles covering
  system, focus, media, power; states probed async once per open.
- **Non-goals**: preferences window, reorder/drag, launch-at-login.
- **Acceptance**: each toggle produces a real, observable system change;
  toggle state survives panel close/open via probe.

## Toggle set — audited against rea/notes/oneswitch.md (One Switch v1.35.4)

| Toggle | Mechanism | Probe |
|---|---|---|
| Hide Desktop Icons | Finder `CreateDesktop` defaults | persistentDomain |
| Show Hidden Files | `AppleShowAllFiles` | persistentDomain |
| Dark Mode | System Events `dark mode` | `.GlobalPreferences` |
| Stage Manager | `com.apple.WindowManager GloballyEnabled` + relog/notify | persistentDomain |
| Hide Dock | `autohide` defaults + cfprefsd flush | persistentDomain |
| Do Not Disturb | `shortcuts` "Turn DND" if user-created; else experimental flag | best-effort |
| Night Shift | requires user-made Shortcut — experimental, tile hidden without it | best-effort |
| Keep Awake | `caffeinate -d` | process running |
| Mute Mic | AVFoundation input volume (no subprocess) | AVFoundation read |
| Mute Speakers | `set volume output muted` | osascript probe |
| Bluetooth | `blueutil` — tile hidden if binary absent | `blueutil -p` |
| Wi-Fi | `networksetup` on detected Wi-Fi interface | `-getairportpower` |
| Empty Pasteboard | `NSPasteboard.general.clearContents()` | action |
| Empty Trash | Finder/`rm ~/.Trash` | action |
| Lock Screen | `CGSession -suspend` | action |
| Sleep Display | `pmset displaysleepnow` | action |
| Low Power Mode | `pmset -a lowpowermode` (needs sudo — mark experimental) | `pmset -g` |

Skipped (per RE spec — private API only): AirPods, TrueTone,
ScreenResolution, ScreenClean, XcodeClean, RecordingSwitch, EjectDisk.
`SwitchItem` gains `available: () -> Bool` — tiles whose dependencies
(blueutil, user shortcut) are missing are hidden, not dead.


## Phases
1. Model: cached `isOn`, `probe()` off-main, optimistic flip. *(done)*
2. UI: `LazyVGrid` tiles, lit-when-ON, no `.id` rebuild. *(done)*
3. Toggle set: extend 8 → 14 per table above; degrade gracefully when
   `blueutil`/shortcuts missing (tile shows but probe returns false).
4. Verify per phase-04 checklist.
