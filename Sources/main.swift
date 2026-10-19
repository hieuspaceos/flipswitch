import Cocoa
import SwiftUI

// flipswitch — free One-Switch-style menubar toggle panel.
// Public APIs only: defaults, AppleScript, pmset, caffeinate, osascript.

// MARK: - Toggle model

struct SwitchItem: Identifiable {
    let id: String
    let name: String
    let icon: String
    var tint: NSColor
    var isOn: () -> Bool
    var flip: (Bool) -> Void
    var desc: String
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
    @Published var refresh = UUID()
    var caffeinate: Process?

    lazy var toggles: [SwitchItem] = [
        SwitchItem(id: "desktop", name: "Hide Desktop Icons", icon: "desktopcomputer",
               tint: .systemIndigo,
               isOn: { UserDefaults.standard.persistentDomain(forName: "com.apple.finder")?["CreateDesktop"] as? Bool == false },
               flip: { on in sh("defaults write com.apple.finder CreateDesktop -bool \(!on) && killall Finder") },
               desc: "Hide every icon on the desktop"),

        SwitchItem(id: "hidden", name: "Show Hidden Files", icon: "eye",
               tint: .systemPurple,
               isOn: { UserDefaults.standard.persistentDomain(forName: "com.apple.finder")?["AppleShowAllFiles"] as? Bool == true },
               flip: { on in sh("defaults write com.apple.finder AppleShowAllFiles -bool \(on) && killall Finder") },
               desc: "Reveal hidden files in Finder"),

        SwitchItem(id: "awake", name: "Keep Awake", icon: "cup.and.saucer.fill",
               tint: .systemBrown,
               isOn: { Switches.shared.caffeinate?.isRunning == true },
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
               },
               desc: "Prevent display sleep"),

        SwitchItem(id: "dark", name: "Dark Mode", icon: "moon.fill",
               tint: .systemBlue,
               isOn: {
                   UserDefaults.standard.persistentDomain(forName: ".GlobalPreferences")?["AppleInterfaceStyle"] as? String == "Dark"
               },
               flip: { on in
                   sh("osascript -e 'tell application \"System Events\" to tell appearance preferences to set dark mode to \(on)'")
               },
               desc: "Toggle dark appearance"),

        SwitchItem(id: "mute", name: "Mute Microphone", icon: "mic.slash.fill",
               tint: .systemOrange,
               isOn: {
                   let (rc, o) = sh("osascript -e 'input volume of (get volume settings)'")
                   return rc == 0 && o.trimmingCharacters(in: .whitespacesAndNewlines) == "0"
               },
               flip: { on in
                   if on {
                       let v = sh("osascript -e 'input volume of (get volume settings)'").1
                       UserDefaults.standard.set(v.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "prevInputVolume")
                       sh("osascript -e 'set volume input volume 0'")
                   } else {
                       let v = UserDefaults.standard.string(forKey: "prevInputVolume") ?? "50"
                       sh("osascript -e 'set volume input volume \(v)'")
                   }
               },
               desc: "Mute / unmute input"),

        SwitchItem(id: "lock", name: "Lock Screen", icon: "lock.fill",
               tint: .systemGray,
               isOn: { false },
               flip: { _ in sh("'/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession' -suspend") },
               desc: "Lock the screen now"),

        SwitchItem(id: "sleep", name: "Sleep Display", icon: "powersleep",
               tint: .systemTeal,
               isOn: { false },
               flip: { _ in sh("pmset displaysleepnow") },
               desc: "Turn the display off"),

        SwitchItem(id: "trash", name: "Empty Trash", icon: "trash",
               tint: .systemRed,
               isOn: { false },
               flip: { _ in
                   sh("osascript -e 'tell application \"Finder\" to empty trash' 2>/dev/null || rm -rf ~/.Trash/*")
               },
               desc: "Empty the Trash"),
    ]

    func flip(_ t: SwitchItem) {
        t.flip(!t.isOn())
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self.refresh = UUID() }
    }
}

// MARK: - Panel UI (One Switch-style rows)

struct PanelView: View {
    @ObservedObject var s = Switches.shared
    @State private var query = ""

    var filtered: [SwitchItem] {
        query.isEmpty ? s.toggles
                      : s.toggles.filter { $0.name.lowercased().contains(query.lowercased()) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // header
            HStack(spacing: 10) {
                Image(systemName: "switch.2").font(.system(size: 15, weight: .semibold))
                Text("flipswitch").font(.system(size: 14, weight: .semibold))
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.tertiary)
                    TextField("Search", text: $query).textFieldStyle(.plain).font(.callout)
                        .frame(width: 120)
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7).fill(.quaternary))
            }
            .padding(.horizontal, 16).padding(.vertical, 12)

            Divider().opacity(0.5)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(filtered) { t in
                        ToggleRow(t: t, on: t.isOn())
                            .onTapGesture { s.flip(t) }
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
            }
            .frame(maxHeight: 420)

            Divider().opacity(0.5)

            // footer
            HStack {
                Text("\(s.toggles.count) switches · public APIs only")
                    .font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.borderless).font(.caption).foregroundStyle(.secondary)
                    .keyboardShortcut("q")
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .frame(width: 340)
        .id(s.refresh)
    }
}

struct ToggleRow: View {
    let t: SwitchItem
    let on: Bool
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: t.tint))
                    .frame(width: 34, height: 34)
                Image(systemName: t.icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(t.name).font(.system(size: 13, weight: .medium))
                Text(t.desc).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(isOn: .constant(on)) {}
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(true)      // row tap flips it
                .allowsHitTesting(false)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(hovered ? Color(nsColor: .controlAccentColor).opacity(0.12) : .clear))
        .onHover { hovered = $0 }
        .help(t.desc)
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
        popover.contentSize = NSSize(width: 340, height: 480)
    }

    @objc func clicked() {
        if popover.isShown { popover.performClose(nil); return }
        if let b = status.button {
            popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
