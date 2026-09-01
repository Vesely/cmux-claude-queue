// cmux-claude-queue-hotkeyd: global Opt+Return hotkey scoped to supported terminals.
//
// While a supported terminal (cmux) is the frontmost app, Opt+Return is
// registered as a system hotkey and runs `cmux-claude-queue capture` directly:
// no action tab, no focus change. In every other app the hotkey is
// unregistered, so Opt+Return behaves normally there.
//
// Uses Carbon RegisterEventHotKey, so no accessibility permission is needed;
// the system consumes the keystroke before it reaches the app.
//
// Build:  swiftc -O main.swift -o ~/.local/bin/cmux-claude-queue-hotkeyd
// Runs as LaunchAgent com.davidvesely.cmux-claude-queue-hotkeyd (KeepAlive).

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

final class HotkeyDaemon {
    private var hotKeyRef: EventHotKeyRef?
    private var lastFire = DispatchTime(uptimeNanoseconds: 0)
    private var children = Set<Process>()

    func start() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, _, userData in
            Unmanaged<HotkeyDaemon>.fromOpaque(userData!).takeUnretainedValue().fire()
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
        if wanted && hotKeyRef == nil {
            let hotKeyID = EventHotKeyID(signature: OSType(0x4351_4844), id: 1) // "CQHD"
            let status = RegisterEventHotKey(UInt32(kVK_Return), UInt32(optionKey),
                                             hotKeyID, GetEventDispatcherTarget(), 0, &hotKeyRef)
            if status != noErr {
                // e.g. another app owns Opt+Return system-wide; without this the
                // hotkey would just silently never fire (err log via LaunchAgent)
                FileHandle.standardError.write(Data("RegisterEventHotKey failed: \(status)\n".utf8))
                hotKeyRef = nil
            }
        } else if !wanted, let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    fileprivate func fire() {
        // belt and braces: registration should already scope us to the targets
        guard let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              targetBundleIDs.contains(front) else { return }
        // debounce a double-tap: two captures racing would read the same
        // screen and enqueue the draft twice
        let now = DispatchTime.now()
        guard now.uptimeNanoseconds - lastFire.uptimeNanoseconds > 300_000_000 else { return }
        lastFire = now
        if !FileManager.default.fileExists(atPath: soundOptOutPath) {
            let sound = NSSound(named: "Pop")
            sound?.volume = 0.5
            sound?.play()
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: captureScript)
        p.arguments = ["capture"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        p.environment = env
        // hold a reference until exit so the child is reliably reaped
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async { self?.children.remove(proc) }
        }
        do { try p.run(); children.insert(p) } catch {
            FileHandle.standardError.write(Data("capture spawn failed: \(error)\n".utf8))
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let daemon = HotkeyDaemon()
daemon.start()
app.run()
