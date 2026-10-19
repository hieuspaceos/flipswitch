import Cocoa
import SwiftUI
import CoreAudio

// flipswitch — free One-Switch-style menubar toggle panel.
// Public APIs only: defaults, NSAppleScript (in-process AppleEvents),
// CoreAudio HAL, pmset, caffeinate. osascript survives only as last-resort
// fallback on audio devices lacking HAL properties.
// Perf rules: no subprocess on the render path; states + dependency checks
// refresh async once per panel-open; toggle state updates optimistically.

// MARK: - Toggle model

struct SwitchItem: Identifiable {
    let id: String
    let name: String
    let icon: String
    var tint: NSColor
    /// True = transient action (Lock, Sleep, Trash) — no ON state.
    var action = false
    /// Dependency check (blueutil, user shortcut) — may spawn a subprocess;
    /// evaluated once, off-main, on first panel open. Cached in `isAvailable`.
    var available: () -> Bool = { true }
    /// Cached availability — the only thing read on the render path.
    var isAvailable = true
    var experimental = false
    var desc = ""
    var isOn: Bool = false
    /// Reads real system state — may spawn a subprocess; call off-main only.
    var probe: (() -> Bool)?
    var flip: (Bool) -> Void
}

func sh(_ cmd: String) -> (Int32, String) {
    let p = Process(), out = Pipe()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = ["-c", cmd]
    p.standardOutput = out; p.standardError = out
    try? p.run(); p.waitUntilExit()
    return (p.terminationStatus,
            String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
}

/// Runs AppleScript source in-process — AppleEvent without spawning
/// `osascript`. Call off-main; returns the error dict (nil on success) so
/// callers can keep shell-style `||` fallback semantics.
@discardableResult
func applescript(_ source: String) -> NSDictionary? {
    var err: NSDictionary?
    NSAppleScript(source: source)?.executeAndReturnError(&err)
    return err
}

func audioAddr(_ selector: AudioObjectPropertySelector,
               _ scope: AudioObjectPropertyScope,
               _ element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}

func defaultAudioDevice(_ scope: AudioObjectPropertyScope) -> AudioDeviceID {
    var id = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var addr = audioAddr(kAudioHardwarePropertyDefaultOutputDevice,
                         kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain)
    if scope == kAudioDevicePropertyScopeInput {
        addr.mSelector = kAudioHardwarePropertyDefaultInputDevice
    }
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
    return id
}

/// First settable element for `scope` — modern devices expose only the main
/// element (0); older ones carry per-channel properties starting at 1.
func audioElement(_ dev: AudioDeviceID, _ scope: AudioObjectPropertyScope,
                  _ selector: AudioObjectPropertySelector) -> AudioObjectPropertyElement? {
    for el in [kAudioObjectPropertyElementMain, AudioObjectPropertyElement(1)] {
        var addr = audioAddr(selector, scope, el)
        var settable = DarwinBoolean(false)
        if AudioObjectHasProperty(dev, &addr),
           AudioObjectIsPropertySettable(dev, &addr, &settable) == noErr,
           settable.boolValue { return el }
    }
    return nil
}

func outputMuted(_ dev: AudioDeviceID) -> Bool? {
    guard let el = audioElement(dev, kAudioDevicePropertyScopeOutput,
                                kAudioDevicePropertyMute) else { return nil }
    var addr = audioAddr(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput, el)
    var v = UInt32(0), size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &v) == noErr ? v != 0 : nil
}

func setOutputMuted(_ dev: AudioDeviceID, _ muted: Bool) {
    guard let el = audioElement(dev, kAudioDevicePropertyScopeOutput,
                                kAudioDevicePropertyMute) else { return }
    var addr = audioAddr(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput, el)
    var v = UInt32(muted ? 1 : 0)
    AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v)
}

/// Default-input scalar 0–1 — mirrors `input volume of (get volume settings)` / 100.
func inputVolume(_ dev: AudioDeviceID) -> Float? {
    guard let el = audioElement(dev, kAudioDevicePropertyScopeInput,
                                kAudioDevicePropertyVolumeScalar) else { return nil }
    var addr = audioAddr(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeInput, el)
    var v = Float(0), size = UInt32(MemoryLayout<Float>.size)
    return AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &v) == noErr ? v : nil
}

func setInputVolume(_ dev: AudioDeviceID, _ scalar: Float) {
    guard let el = audioElement(dev, kAudioDevicePropertyScopeInput,
                                kAudioDevicePropertyVolumeScalar) else { return }
    var addr = audioAddr(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeInput, el)
    var v = scalar
    AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<Float>.size), &v)
}

final class Switches: ObservableObject {
    static let shared = Switches()
    @Published var toggles: [SwitchItem] = []
    var caffeinate: Process?
    /// Wi-Fi device (en0 typically) — detected once.
    lazy var wifiDev: String = {
        let (_, o) = sh("networksetup -listallhardwareports")
        // "Hardware Port: Wi-Fi\nDevice: en0"
        if let r = o.range(of: "Hardware Port: Wi-Fi"),
           let d = o[r.upperBound...].range(of: "Device: ") {
            let rest = o[d.upperBound...]
            return String(rest.prefix(while: { !$0.isNewline }))
        }
        return "en0"
    }()
    func has(_ bin: String) -> Bool {
        sh("command -v \(bin)").0 == 0
    }
    func hasShortcut(_ name: String) -> Bool {
        let (rc, o) = sh("shortcuts list 2>/dev/null | grep -Fx \(name)")
        return rc == 0 && !o.isEmpty
    }

    private init() {
        let descs: [String: String] = [
            "desktop": "Hide every icon on the desktop",
            "hidden": "Reveal hidden files in Finder",
            "dark": "Toggle dark appearance",
            "stage": "Toggle Stage Manager",
            "dock": "Auto-hide the Dock",
            "dnd": "Toggle Do Not Disturb — needs a Shortcut named 'Toggle DND'",
            "nightshift": "Toggle Night Shift — needs a Shortcut named 'Toggle Night Shift'",
            "mute": "Mute/unmute microphone input",
            "spk": "Mute/unmute speaker output",
            "bt": "Toggle Bluetooth — needs blueutil",
            "wifi": "Toggle Wi-Fi power",
            "awake": "Prevent display sleep",
            "lpm": "Toggle Low Power Mode (needs admin)",
            "clipboard": "Clear the pasteboard",
            "trash": "Empty the Trash",
            "lock": "Lock the screen now",
            "sleep": "Turn the display off",
        ]
        toggles = [
            // system
            SwitchItem(id: "desktop", name: "Desktop", icon: "desktopcomputer",
                   tint: .systemIndigo,
                   probe: { UserDefaults.standard.persistentDomain(forName: "com.apple.finder")?["CreateDesktop"] as? Bool == false },
                   flip: { on in sh("defaults write com.apple.finder CreateDesktop -bool \(!on) && killall Finder") }),
            SwitchItem(id: "hidden", name: "Hidden Files", icon: "eye",
                   tint: .systemPurple,
                   probe: { UserDefaults.standard.persistentDomain(forName: "com.apple.finder")?["AppleShowAllFiles"] as? Bool == true },
                   flip: { on in sh("defaults write com.apple.finder AppleShowAllFiles -bool \(on) && killall Finder") }),
            SwitchItem(id: "dark", name: "Dark Mode", icon: "moon.fill",
                   tint: .systemBlue,
                   probe: { UserDefaults.standard.persistentDomain(forName: ".GlobalPreferences")?["AppleInterfaceStyle"] as? String == "Dark" },
                   flip: { on in
                       // in-process AppleEvent — no osascript spawn
                       applescript("tell application \"System Events\" to tell appearance preferences to set dark mode to \(on)")
                   }),
            SwitchItem(id: "stage", name: "Stage Mgr", icon: "rectangle.3.group",
                   tint: .systemMint,
                   probe: { UserDefaults.standard.persistentDomain(forName: "com.apple.WindowManager")?["GloballyEnabled"] as? Bool == true },
                   flip: { on in
                       sh("defaults write com.apple.WindowManager GloballyEnabled -bool \(on) && killall WindowManager")
                   }),
            SwitchItem(id: "dock", name: "Hide Dock", icon: "dock.rectangle",
                   tint: .systemGray,
                   probe: { UserDefaults.standard.persistentDomain(forName: "com.apple.dock")?["autohide"] as? Bool == true },
                   flip: { on in sh("defaults write com.apple.dock autohide -bool \(on) && killall Dock") }),
            // focus (experimental — need user-created Shortcuts)
            SwitchItem(id: "dnd", name: "Do Not Disturb", icon: "moon.zzz.fill",
                   tint: .systemIndigo,
                   available: { Switches.shared.hasShortcut("Toggle DND") },
                   isAvailable: false,
                   experimental: true,
                   probe: { false },
                   flip: { _ in sh("shortcuts run 'Toggle DND' 2>/dev/null") }),
            SwitchItem(id: "nightshift", name: "Night Shift", icon: "moon.stars.fill",
                   tint: .systemYellow,
                   available: { Switches.shared.hasShortcut("Toggle Night Shift") },
                   isAvailable: false,
                   experimental: true,
                   probe: { false },
                   flip: { _ in sh("shortcuts run 'Toggle Night Shift' 2>/dev/null") }),
            // media
            SwitchItem(id: "mute", name: "Mute Mic", icon: "mic.slash.fill",
                   tint: .systemOrange,
                   probe: {
                       // off-main only; HAL first, osascript fallback for odd devices
                       if let v = inputVolume(defaultAudioDevice(kAudioDevicePropertyScopeInput)) {
                           return v <= 0
                       }
                       let (rc, o) = sh("osascript -e 'input volume of (get volume settings)'")
                       return rc == 0 && o.trimmingCharacters(in: .whitespacesAndNewlines) == "0"
                   },
                   flip: { on in
                       // kAudioDevicePropertyVolumeScalar on default input —
                       // AudioObjectSetPropertyData, no subprocess
                       let dev = defaultAudioDevice(kAudioDevicePropertyScopeInput)
                       if on {
                           if let v = inputVolume(dev) {
                               UserDefaults.standard.set(v, forKey: "prevInputVolume")
                               setInputVolume(dev, 0)
                           } else {
                               let v = sh("osascript -e 'input volume of (get volume settings)'").1
                               UserDefaults.standard.set(v.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "prevInputVolume")
                               sh("osascript -e 'set volume input volume 0'")
                           }
                       } else {
                           // legacy value is a 0–100 string; scalar wants 0–1
                           let v = UserDefaults.standard.float(forKey: "prevInputVolume")
                           setInputVolume(dev, v > 1 ? v / 100 : (v > 0 ? v : 0.5))
                       }
                   }),
            SwitchItem(id: "spk", name: "Mute Speakers", icon: "speaker.slash.fill",
                   tint: .systemRed,
                   probe: {
                       if let m = outputMuted(defaultAudioDevice(kAudioDevicePropertyScopeOutput)) {
                           return m
                       }
                       let (rc, o) = sh("osascript -e 'output muted of (get volume settings)'")
                       return rc == 0 && o.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
                   },
                   flip: { on in
                       setOutputMuted(defaultAudioDevice(kAudioDevicePropertyScopeOutput), on)
                   }),
            SwitchItem(id: "bt", name: "Bluetooth", icon: "antenna.radiowaves.left.and.right",
                   tint: .systemBlue,
                   available: { Switches.shared.has("blueutil") },
                   isAvailable: false,
                   probe: {
                       let (rc, o) = sh("blueutil -p 2>/dev/null")
                       return rc == 0 && o.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
                   },
                   flip: { _ in sh("blueutil -p toggle") }),
            SwitchItem(id: "wifi", name: "Wi-Fi", icon: "wifi",
                   tint: .systemTeal,
                   probe: {
                       let d = Switches.shared.wifiDev
                       let (rc, o) = sh("networksetup -getairportpower \(d) 2>/dev/null")
                       return rc == 0 && o.contains(": On")
                   },
                   flip: { on in
                       let d = Switches.shared.wifiDev
                       sh("networksetup -setairportpower \(d) \(on ? "on" : "off")")
                   }),
            // power
            SwitchItem(id: "awake", name: "Keep Awake", icon: "cup.and.saucer.fill",
                   tint: .systemBrown,
                   probe: { Switches.shared.caffeinate?.isRunning == true },
                   flip: { on in
                       if on {
                           let p = Process()
                           p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
                           p.arguments = ["-d"]
                           try? p.run(); Switches.shared.caffeinate = p
                       } else {
                           Switches.shared.caffeinate?.terminate()
                           Switches.shared.caffeinate = nil
                       }
                   }),
            SwitchItem(id: "lpm", name: "Low Power", icon: "battery.25",
                   tint: .systemGreen, experimental: true,
                   probe: {
                       let (_, o) = sh("pmset -g | grep -i lowpowermode")
                       return o.contains("1")
                   },
                   flip: { on in sh("pmset -a lowpowermode \(on ? 1 : 0) 2>/dev/null") }),
            // actions (no ON state)
            SwitchItem(id: "clipboard", name: "Clear Clipboard", icon: "doc.on.clipboard",
                   tint: .systemGray, action: true,
                   flip: { _ in NSPasteboard.general.clearContents() }),
            SwitchItem(id: "trash", name: "Empty Trash", icon: "trash",
                   tint: .systemRed, action: true,
                   flip: { _ in
                       // Finder AppleEvent in-process; rm fallback when denied
                       if applescript("tell application \"Finder\" to empty trash") != nil {
                           sh("rm -rf ~/.Trash/* 2>/dev/null")
                       }
                   }),
            SwitchItem(id: "lock", name: "Lock", icon: "lock.fill",
                   tint: .systemGray, action: true,
                   flip: { _ in
                       // CGSession was removed in macOS 26 — ⌃⌘Q via System Events
                       // (needs Accessibility); fallback sleeps the display, which
                       // locks on wake when 'require password' is set.
                       if applescript("tell application \"System Events\" to keystroke \"q\" using {command down, control down}") != nil {
                           sh("pmset displaysleepnow")
                       }
                   }),
            SwitchItem(id: "sleep", name: "Sleep", icon: "powersleep",
                   tint: .systemTeal, action: true,
                   flip: { _ in sh("pmset displaysleepnow") }),
        ]
        for i in toggles.indices { toggles[i].desc = descs[toggles[i].id] ?? "" }
    }

    /// Re-probe real states off the main thread, publish once.
    /// Called on panel open — the only moment subprocesses run.
    /// Dependency checks (`available()`) are evaluated exactly once, lazily,
    /// on this first call and cached in `SwitchItem.isAvailable` so the
    /// render path never touches a subprocess.
    private var availabilityProbed = false
    func refresh() {
        let items = toggles
        let probeAvailability = !availabilityProbed
        availabilityProbed = true
        DispatchQueue.global(qos: .userInitiated).async {
            var states: [String: Bool] = [:]
            for t in items where t.probe != nil { states[t.id] = t.probe!() }
            var avail: [String: Bool]? = nil
            if probeAvailability {
                avail = [:]
                for t in items { avail![t.id] = t.available() }
            }
            DispatchQueue.main.async {
                for i in self.toggles.indices {
                    if let v = states[self.toggles[i].id] { self.toggles[i].isOn = v }
                    if let v = avail?[self.toggles[i].id] { self.toggles[i].isAvailable = v }
                }
            }
        }
    }

    func flip(_ t: SwitchItem) {
        guard let i = toggles.firstIndex(where: { $0.id == t.id }) else { return }
        let item = toggles[i]
        let on = item.action ? true : !item.isOn
        if !item.action { toggles[i].isOn = on }   // optimistic UI
        let flip = item.flip
        DispatchQueue.global(qos: .userInitiated).async { flip(on) }
    }
}

// MARK: - Panel UI (Control-Center-style tile grid)

struct PanelView: View {
    @ObservedObject var s = Switches.shared
    @State private var query = ""

    var filtered: [SwitchItem] {
        let vis = s.toggles.filter { $0.isAvailable }
        return query.isEmpty ? vis
               : vis.filter { $0.name.lowercased().contains(query.lowercased()) }
    }

    let cols = [GridItem(.fixed(130), spacing: 10), GridItem(.fixed(130), spacing: 10)]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "switch.2").font(.system(size: 15, weight: .semibold))
                Text("flipswitch").font(.system(size: 13, weight: .semibold))
                    .lineLimit(1).fixedSize()
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.tertiary)
                    TextField("Search", text: $query).textFieldStyle(.plain).font(.callout)
                        .frame(width: 80)
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7).fill(.quaternary))
            }
            .padding(.horizontal, 16).padding(.vertical, 12)

            Divider().opacity(0.5)

            ScrollView {
                LazyVGrid(columns: cols, spacing: 10) {
                    ForEach(filtered) { t in Tile(t: t) }
                }
                .padding(14)
            }
            .frame(maxHeight: 400)

            Divider().opacity(0.5)

            HStack {
                Text("\(s.toggles.count) switches").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.borderless).font(.caption).foregroundStyle(.secondary)
                    .keyboardShortcut("q")
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .frame(width: 300)
    }
}

/// Control-Center tile: tinted circle icon, name under it; lit when ON.
struct Tile: View {
    let t: SwitchItem
    @State private var hovered = false
    @State private var flipped = false   // 180° spin on each tap

    func spin() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { flipped.toggle() }
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(t.isOn ? Color(nsColor: t.tint)
                                 : Color(nsColor: .quaternaryLabelColor))
                    .frame(width: 36, height: 36)
                Image(systemName: t.icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(t.isOn ? .white : .secondary)
            }
            // the name-sake "flip": icon rotates 180° each activation
            .rotation3DEffect(.degrees(flipped ? 180 : 0),
                              axis: (x: 0, y: 1, z: 0))
            Text(t.name)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(t.isOn ? .primary : .secondary)
                .lineLimit(1)
        }

        .frame(maxWidth: .infinity, minHeight: 78)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 12)
            .fill(t.isOn ? Color(nsColor: t.tint).opacity(0.12)
                         : (hovered ? Color.primary.opacity(0.06) : .clear)))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(t.isOn ? Color(nsColor: t.tint).opacity(0.4) : .clear, lineWidth: 1))
        .scaleEffect(hovered ? 1.03 : 1)
        .animation(.easeOut(duration: 0.12), value: hovered)
        .animation(.spring(response: 0.3), value: t.isOn)
        .onHover { hovered = $0 }
        .help(t.desc)
        .contentShape(Rectangle())
        .onTapGesture {
            spin()
            Switches.shared.flip(t)
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    var status: NSStatusItem!
    var popover: NSPopover!

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.image = NSImage(systemSymbolName: "switch.2",
                                       accessibilityDescription: "flipswitch")
        status.button?.action = #selector(clicked)
        status.button?.target = self
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: PanelView())
        popover.contentSize = NSSize(width: 300, height: 480)
    }

    @objc func clicked() {
        if popover.isShown { popover.performClose(nil); return }
        if let b = status.button {
            popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            Switches.shared.refresh()   // probe states once per open, off-main
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
