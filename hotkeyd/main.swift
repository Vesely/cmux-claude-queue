// cmux-claude-queue-hotkeyd: global hotkeys scoped to supported terminals.
//
// While a supported terminal (cmux) is the frontmost app, two system hotkeys
// are registered:
//   Opt+Return        -> `cmux-claude-queue capture`      (queue the draft)
//   Opt+Shift+Return  -> `cmux-claude-queue manage-open`  (queue manager pane)
// No action tab, no focus change. In every other app both combos are
// unregistered, so they behave normally there.
//
// Uses Carbon RegisterEventHotKey, so no accessibility permission is needed;
// the system consumes the keystroke before it reaches the app.
//
// Build:  swiftc -O main.swift -o ~/.local/bin/cmux-claude-queue-hotkeyd
// Runs as LaunchAgent com.cmux-claude-queue.hotkeyd (KeepAlive).

import AppKit
import Carbon.HIToolbox

let targetBundleIDs: Set<String> = [
    "com.cmuxterm.app",
    // "com.mitchellh.ghostty",  // future: needs a Ghostty capture backend first
]
// The LaunchAgent passes the installed script path as argv[1] (BIN_DIR can be
// customized at install time); the ~/.local/bin default covers manual runs.
let captureScript: String = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : ("~/.local/bin/cmux-claude-queue" as NSString).expandingTildeInPath
// Instant audible ack: the capture itself takes up to ~1 s on a loaded machine
// (three serial cmux socket calls), during which nothing visible happens yet.
// Touch this file to disable the sound.
let soundOptOutPath = ("~/.config/cmux-claude-queue/no-sound" as NSString).expandingTildeInPath

private struct Hotkey {
    let id: UInt32
    let modifiers: UInt32
    let action: String
    let sound: Bool
}

private let hotkeys: [Hotkey] = [
    Hotkey(id: 1, modifiers: UInt32(optionKey), action: "capture", sound: true),
    // the manager pane is its own visible feedback, no sound needed
    Hotkey(id: 2, modifiers: UInt32(optionKey | shiftKey), action: "manage-open", sound: false),
]

final class HotkeyDaemon {
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var lastFire = DispatchTime(uptimeNanoseconds: 0)
    private var children = Set<Process>()

    func start() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, userData in
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            Unmanaged<HotkeyDaemon>.fromOpaque(userData!).takeUnretainedValue().fire(id: hkID.id)
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), nil)

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.syncRegistration(frontmost: app?.bundleIdentifier)
        }
        syncRegistration(frontmost: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }

    private func syncRegistration(frontmost: String?) {
        let wanted = frontmost.map(targetBundleIDs.contains) ?? false
        if wanted && hotKeyRefs.isEmpty {
            for hk in hotkeys {
                var ref: EventHotKeyRef?
                let hotKeyID = EventHotKeyID(signature: OSType(0x4351_4844), id: hk.id) // "CQHD"
                let status = RegisterEventHotKey(UInt32(kVK_Return), hk.modifiers,
                                                 hotKeyID, GetEventDispatcherTarget(), 0, &ref)
                if status != noErr || ref == nil {
                    // e.g. another app owns the combo system-wide; without this
                    // the hotkey would just silently never fire
                    FileHandle.standardError.write(Data("RegisterEventHotKey id \(hk.id) failed: \(status)\n".utf8))
                    continue
                }
                hotKeyRefs.append(ref!)
            }
        } else if !wanted, !hotKeyRefs.isEmpty {
            for ref in hotKeyRefs { UnregisterEventHotKey(ref) }
            hotKeyRefs.removeAll()
        }
    }

    fileprivate func fire(id: UInt32) {
        guard let hk = hotkeys.first(where: { $0.id == id }) else { return }
        // belt and braces: registration should already scope us to the targets
        guard let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              targetBundleIDs.contains(front) else { return }
        // debounce a double-tap: two captures racing would read the same
        // screen and enqueue the draft twice
        let now = DispatchTime.now()
        guard now.uptimeNanoseconds - lastFire.uptimeNanoseconds > 300_000_000 else { return }
        lastFire = now
        if hk.sound && !FileManager.default.fileExists(atPath: soundOptOutPath) {
            let sound = NSSound(named: "Pop")
            sound?.volume = 0.5
            sound?.play()
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: captureScript)
        p.arguments = [hk.action]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        p.environment = env
        // hold a reference until exit so the child is reliably reaped
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async { self?.children.remove(proc) }
        }
        do { try p.run(); children.insert(p) } catch {
            FileHandle.standardError.write(Data("\(hk.action) spawn failed: \(error)\n".utf8))
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let daemon = HotkeyDaemon()
daemon.start()
app.run()
