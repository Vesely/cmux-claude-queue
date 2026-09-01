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
let captureScript = ("~/.local/bin/cmux-claude-queue" as NSString).expandingTildeInPath

final class HotkeyDaemon {
    private var hotKeyRef: EventHotKeyRef?

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
            RegisterEventHotKey(UInt32(kVK_Return), UInt32(optionKey),
                                hotKeyID, GetEventDispatcherTarget(), 0, &hotKeyRef)
        } else if !wanted, let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    fileprivate func fire() {
        // belt and braces: registration should already scope us to the targets
        guard let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              targetBundleIDs.contains(front) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: captureScript)
        p.arguments = ["capture"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        p.environment = env
        try? p.run()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let daemon = HotkeyDaemon()
daemon.start()
app.run()
