import Cocoa
import SwiftUI

// flipswitch — free One-Switch-style menubar toggle panel.
// Public APIs only: defaults, AppleScript, pmset, caffeinate, osascript.
// Perf rules: no subprocess on the render path; states refresh async once
// per panel-open; toggle state updates optimistically.

// MARK: - Toggle model

struct SwitchItem: Identifiable {
    let id: String
    let name: String
    let icon: String
    var tint: NSColor
    /// True = transient action (Lock, Sleep, Trash) — no ON state.
    var action = false
    /// Tile hidden when its dependency (blueutil, user shortcut) is absent.
    var available: () -> Bool = { true }
    var experimental = false
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
                       sh("osascript -e 'tell application \"System Events\" to tell appearance preferences to set dark mode to \(on)'")
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
                   experimental: true,
                   probe: { false },
                   flip: { _ in sh("shortcuts run 'Toggle DND' 2>/dev/null") }),
            SwitchItem(id: "nightshift", name: "Night Shift", icon: "moon.stars.fill",
                   tint: .systemYellow,
                   available: { Switches.shared.hasShortcut("Toggle Night Shift") },
                   experimental: true,
                   probe: { false },
                   flip: { _ in sh("shortcuts run 'Toggle Night Shift' 2>/dev/null") }),
            // media
            SwitchItem(id: "mute", name: "Mute Mic", icon: "mic.slash.fill",
                   tint: .systemOrange,
                   probe: {
                       // probe only runs off-main on panel open — subprocess OK
                       let (rc, o) = sh("osascript -e 'input volume of (get volume settings)'")
                       return rc == 0 && o.trimmingCharacters(in: .whitespacesAndNewlines) == "0"
                   },
                   flip: { on in
                       // setMasterVolume via osascript — AVF property write is unreliable
                       if on {
                           let v = sh("osascript -e 'input volume of (get volume settings)'").1
                           UserDefaults.standard.set(v.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "prevInputVolume")
                           sh("osascript -e 'set volume input volume 0'")
                       } else {
                           let v = UserDefaults.standard.string(forKey: "prevInputVolume") ?? "50"
                           sh("osascript -e 'set volume input volume \(v)'")
                       }
                   }),
            SwitchItem(id: "spk", name: "Mute Speakers", icon: "speaker.slash.fill",
                   tint: .systemRed,
                   probe: {
                       let (rc, o) = sh("osascript -e 'output muted of (get volume settings)'")
                       return rc == 0 && o.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
                   },
                   flip: { on in sh("osascript -e 'set volume output muted \(on)'") }),
            SwitchItem(id: "bt", name: "Bluetooth", icon: "antenna.radiowaves.left.and.right",
                   tint: .systemBlue,
                   available: { Switches.shared.has("blueutil") },
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
                       sh("osascript -e 'tell application \"Finder\" to empty trash' 2>/dev/null || rm -rf ~/.Trash/*")
                   }),
            SwitchItem(id: "lock", name: "Lock", icon: "lock.fill",
                   tint: .systemGray, action: true,
                   flip: { _ in sh("'/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession' -suspend") }),
            SwitchItem(id: "sleep", name: "Sleep", icon: "powersleep",
                   tint: .systemTeal, action: true,
                   flip: { _ in sh("pmset displaysleepnow") }),
        ]

    }

    /// Re-probe real states off the main thread, publish once.
    /// Called on panel open — the only moment subprocesses run.
    func refresh() {
        let items = toggles
        DispatchQueue.global(qos: .userInitiated).async {
            var states: [String: Bool] = [:]
            for t in items where t.probe != nil { states[t.id] = t.probe!() }
            DispatchQueue.main.async {
                for i in self.toggles.indices {
                    if let v = states[self.toggles[i].id] { self.toggles[i].isOn = v }
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
        let vis = s.toggles.filter { $0.available() }
        return query.isEmpty ? vis
               : vis.filter { $0.name.lowercased().contains(query.lowercased()) }
    }

    let cols = [GridItem(.fixed(126), spacing: 10), GridItem(.fixed(126), spacing: 10)]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "switch.2").font(.system(size: 15, weight: .semibold))
                Text("flipswitch").font(.system(size: 14, weight: .semibold))
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.tertiary)
                    TextField("Search", text: $query).textFieldStyle(.plain).font(.callout)
                        .frame(width: 110)
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7).fill(.quaternary))
            }
            .padding(.horizontal, 16).padding(.vertical, 12)

            Divider().opacity(0.5)

            ScrollView {
                LazyVGrid(columns: cols, spacing: 10) {
                    ForEach(filtered) { t in Tile(t: t).onTapGesture { s.flip(t) } }
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
        .frame(width: 290)
    }
}

/// Control-Center tile: tinted circle icon, name under it; lit when ON.
struct Tile: View {
    let t: SwitchItem
    @State private var hovered = false

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(t.isOn ? Color(nsColor: t.tint)
                                 : Color(nsColor: .quaternaryLabelColor))
                    .frame(width: 46, height: 46)
                Image(systemName: t.icon)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(t.isOn ? .white : .secondary)
            }
            Text(t.name)
                .font(.system(size: 11, weight: .medium))
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
