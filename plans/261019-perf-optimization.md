---
title: "flipswitch perf optimization"
status: todo
goal: "Idle footprint ≤ 20 MB (from 33 MB), panel render with zero subprocesses"
---

# flipswitch — Performance Optimization

Baseline: ~33 MB idle, 0.4 MB bundle. Memory is fine; the real defect is
subprocesses on the render path.

## Top defect (missed in original plan)

- [ ] **Cache `SwitchItem.available()`** — `PanelView.filtered` calls it in
      every SwiftUI body evaluation; for bt/dnd/nightshift it synchronously
      spawns `/bin/zsh` (`command -v blueutil`, `shortcuts list | grep`) on
      the **main thread during render** — including first render. Evaluate
      once (lazily at first panel open, off-main) and cache on
      `SwitchItem`. Largest real perf win. (`Sources/main.swift:214-218`)

## Confirmed actions

- [ ] **Replace `osascript` with native calls** where a direct API exists:
      dark mode → AppleEvent to System Events; volume/mute →
      `AudioObjectSetPropertyData`; brightness → IOKit. Dark mode, mic,
      speaker, trash, lock all confirmed to go through the zsh `sh()`
      wrapper (spawn ~100-500 ms each).
- [ ] Defer availability probes and any `Process` work to first panel
      open, not launch.

## Stale items — remove

- ~~Cache menubar template images~~ — icon is a single SF Symbol
  (`switch.2`) set once; SF Symbols are already template-rendered.
- ~~Cache/rebuild `NSMenu`~~ — there is no NSMenu; UI is `NSPopover` +
  `NSHostingController(PanelView)`. SwiftUI diffs the tree; refresh probes
  already run off-main per open.

## Goal clarification

Toggle latency: UI is already optimistic (`isOn` flips instantly, work
dispatched to background queue), so perceived latency is ~0 ms. The real
target is **system-effect latency** (osascript spawn → actual state
change), < 150 ms where possible.

## Verify

```sh
PID=$(pgrep -x flipswitch | head -1)
leaks -nostacks $PID
instruments -t "Time Profiler"  # open panel; expect zero Process spawns
```
