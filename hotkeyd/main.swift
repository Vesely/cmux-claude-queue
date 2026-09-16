// cmux-claude-queue-hotkeyd: global hotkeys scoped to supported terminals.
//
// While a supported terminal (cmux) is the frontmost app, two system hotkeys
// are registered:
//   Opt+Return        -> capture the draft (queue it)
//   Opt+Shift+Return  -> `cmux-claude-queue manage-open`  (queue manager pane)
// Both are defaults; ~/.config/cmux-claude-queue/hotkey-capture and
// hotkey-manage override them (see parseHotkey).
// No action tab, no focus change. In every other app both combos are
// unregistered, so they behave normally there.
//
// Uses Carbon RegisterEventHotKey, so no accessibility permission is needed;
// the system consumes the keystroke before it reaches the app.
//
// Capture runs in-process over a WARM control socket (see ControlSocket): the
// spawned `cmux-claude-queue capture` used to cost 100-500 ms of fork/exec +
// python cold start under load before anything visible happened. This daemon
// is resident anyway, so the latency-critical prefix — resolve target, read
// the box, spool the draft, clear the box — costs one socket round trip each
// and no process creation at all. Everything after the clear (the width-aware
// box parse, the double-press guard, the queue append, the verify re-clear and
// the delivery tick) is NOT latency-critical and stays in the script, spawned
// as `cmux-claude-queue spool <surfaceId>`.
//
// Ordering is load-bearing: the raw screen dump is spooled to disk BEFORE the
// first clear keystroke goes out. Killed anywhere in between, the draft exists
// both in the spool and in the box; the script (or the notifyhook's orphan
// sweep) recovers it. Clearing first would destroy a draft whose handoff never
// landed.
//
// Any failure before the spool write falls through to spawning `capture`,
// exactly as before — the fast path mutates nothing up to that point, so the
// script can redo the whole sequence. Touch
// ~/.config/cmux-claude-queue/no-fastpath to force that route permanently.
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

enum Paths {
    static func tilde(_ p: String) -> String { (p as NSString).expandingTildeInPath }
    static let queueDir = tilde("~/.claude/prompt-queue")
    static let store = tilde("~/.cmuxterm/claude-hook-sessions.json")
    static let events = tilde("~/.cmuxterm/events.jsonl")
    static let cmuxState = tilde("~/.local/state/cmux")
    static let cmuxConfig = tilde("~/.config/cmux/cmux.json")
    // Instant audible ack: even the fast path is not visible until the box
    // clears. Touch this file to disable the sound.
    static let soundOptOut = tilde("~/.config/cmux-claude-queue/no-sound")
    // Escape hatch: forces every capture back through the spawned script.
    static let fastPathOptOut = tilde("~/.config/cmux-claude-queue/no-fastpath")
    // One combo per file, e.g. `echo ctrl+shift+enter > hotkey-capture`.
    // Absent or unparseable means the default. Re-read whenever cmux comes to
    // the front, so an edit takes effect without restarting the daemon.
    static let hotkeyCapture = tilde("~/.config/cmux-claude-queue/hotkey-capture")
    static let hotkeyManage = tilde("~/.config/cmux-claude-queue/hotkey-manage")
    // Written at the keypress itself so the statusline placeholder row can
    // render on its very next refresh, before the capture has a target.
    static let captureStamp = queueDir + "/capturing.stamp"
}

// Constructing a DateFormatter costs about as much as the whole fast path, so
// it is built once. Only ever touched from captureQueue, which is serial.
private let logStamp: DateFormatter = {
    let df = DateFormatter()
    df.dateFormat = "HH:mm:ss"
    return df
}()

func qlog(_ msg: String) {
    let line = logStamp.string(from: Date()) + " " + msg + "\n"
    guard let data = line.data(using: .utf8) else { return }
    let path = Paths.queueDir + "/log.txt"
    // O_APPEND, not seek-then-write: the script's halves (the spool handler,
    // the delivery pump, the statusline) append to this same file at the same
    // time, and a seek+write loses whatever landed in between. The log is not
    // just diagnostics — a prompt dropped after three unconfirmed sends
    // survives only as its line in here.
    let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
    guard fd >= 0 else { return }
    defer { close(fd) }
    _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
}

// MARK: - cmux control socket

enum SockError: Error {
    case unavailable   // no socket, or auth refused — fall back to the script
    case io            // connection died mid-request; retryable once
    case remote(String)
}

// Persistent, authenticated client for the cmux control socket.
//
// One connection serves the whole daemon (the socket is app-scoped, not
// surface-scoped, so many open surfaces cost nothing extra). Every I/O error
// closes the fd; the next call reconnects and re-reads the password, which is
// what makes a cmux restart — new socket path, possibly rotated password —
// self-healing. Read/write timeouts double as the latency budget: a wedged
// cmux fails fast into the spawned-script fallback instead of freezing the
// hotkey. Not thread safe by design; all use is serialized on captureQueue.
final class ControlSocket {
    private var fd: Int32 = -1
    private var buf = [UInt8]()
    private var rid = 0
    private let timeoutMs: Int

    // Tuned against measured cmux behaviour, not guessed. Round trips are
    // ~1 ms at p50 but have a heavy tail: sampling workspace.current 900 times
    // gave p99 ~90 ms and a 580 ms maximum, cmux's socket thread being busy.
    // A timeout inside that tail is the worst outcome available — it discards
    // a connection that was about to answer, retries into the same stall and
    // then escalates to spawning the script, turning a half-second wait into
    // more than a second. So the budget covers the observed tail with headroom
    // and still fails fast on a cmux that is actually gone.
    init(timeoutMs: Int = 800) { self.timeoutMs = timeoutMs }

    func close() {
        if fd >= 0 { Darwin.close(fd) }
        fd = -1
        buf.removeAll(keepingCapacity: true)
    }

    private func candidatePaths() -> [String] {
        var out: [String] = []
        if let raw = try? String(contentsOfFile: Paths.cmuxState + "/last-socket-path",
                                 encoding: .utf8) {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { out.append(t) }
        }
        out.append(Paths.cmuxState + "/cmux-\(getuid()).sock")
        out.append(Paths.cmuxState + "/cmux.sock")
        return out
    }

    private func password() -> String {
        if let raw = try? String(contentsOfFile: Paths.cmuxState + "/socket-control-password",
                                 encoding: .utf8) {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        if let data = FileManager.default.contents(atPath: Paths.cmuxConfig),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let automation = root["automation"] as? [String: Any],
           let pw = automation["socketPassword"] as? String {
            return pw
        }
        return ""
    }

    private func openSocket(_ path: String) -> Int32? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { return nil }
        withUnsafeMutablePointer(to: &addr.sun_path) { raw in
            raw.withMemoryRebound(to: UInt8.self, capacity: capacity) { dst in
                for (i, b) in bytes.enumerated() { dst[i] = b }
                dst[bytes.count] = 0
            }
        }
        let f = socket(AF_UNIX, SOCK_STREAM, 0)
        guard f >= 0 else { return nil }
        // Writing to a peer that went away raises SIGPIPE, whose default
        // disposition is death. The python fast paths never had to think about
        // this — CPython ignores SIGPIPE at interpreter startup — but nothing
        // does that for us here, and a warm connection outliving a cmux restart
        // is the ordinary case, not an edge one. Without this the daemon dies
        // on the write, before any of the reconnect logic below can run.
        var on: Int32 = 1
        setsockopt(f, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: __darwin_time_t(timeoutMs / 1000),
                         tv_usec: __darwin_suseconds_t((timeoutMs % 1000) * 1000))
        setsockopt(f, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(f, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let ok = withUnsafePointer(to: &addr) { p -> Bool in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(f, sa, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        if !ok { Darwin.close(f); return nil }
        return f
    }

    func ensureConnected() throws {
        if fd >= 0 { return }
        let pw = password()
        for path in candidatePaths() {
            guard let f = openSocket(path) else { continue }
            fd = f
            buf.removeAll(keepingCapacity: true)
            do {
                try write("auth \(pw)\n")
                if String(decoding: try readLineBytes(), as: UTF8.self).hasPrefix("OK") { return }
            } catch {}
            close()
        }
        throw SockError.unavailable
    }

    private func write(_ s: String) throws {
        let bytes = Array(s.utf8)
        var off = 0
        while off < bytes.count {
            let n = bytes.withUnsafeBytes { p -> Int in
                Darwin.write(fd, p.baseAddress!.advanced(by: off), bytes.count - off)
            }
            if n <= 0 { throw SockError.io }
            off += n
        }
    }

    private func readLineBytes() throws -> [UInt8] {
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            if let i = buf.firstIndex(of: 0x0a) {
                let line = Array(buf[..<i])
                buf.removeFirst(i + 1)
                return line
            }
            let n = chunk.withUnsafeMutableBytes { p -> Int in
                Darwin.read(fd, p.baseAddress, 65536)
            }
            if n <= 0 { throw SockError.io }
            buf.append(contentsOf: chunk[0..<n])
        }
    }

    private func request(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
        rid += 1
        let req: [String: Any] = ["id": rid, "method": method, "params": params]
        guard let data = try? JSONSerialization.data(withJSONObject: req),
              let line = String(data: data, encoding: .utf8) else { throw SockError.io }
        try write(line + "\n")
        let raw = try readLineBytes()
        guard let obj = try? JSONSerialization.jsonObject(with: Data(raw)) as? [String: Any] else {
            throw SockError.io
        }
        if (obj["ok"] as? Bool) != true {
            throw SockError.remote("\(method): \(obj["error"] ?? "unknown")")
        }
        return obj["result"] as? [String: Any] ?? [:]
    }

    // One request, with a single reconnect+retry on transport failure. A
    // timed-out or half-read connection is always discarded rather than
    // reused: a late reply would otherwise be mis-correlated with the next
    // request on the same fd.
    //
    // `retry` must be false for anything that is not idempotent. A read
    // timeout does not mean the request was not executed — only that the
    // answer did not arrive in time — so retrying a keystroke can send it
    // twice.
    func call(_ method: String, _ params: [String: Any],
              retry: Bool = true) throws -> [String: Any] {
        try ensureConnected()
        do {
            return try request(method, params)
        } catch SockError.remote(let m) {
            throw SockError.remote(m)
        } catch {
            close()
            guard retry else { throw error }
            try ensureConnected()
            return try request(method, params)
        }
    }
}

// MARK: - input box parsing

// The Claude Code input box is the region between the last two full-width
// horizontal rules on screen. The fast path only needs two facts from it: how
// many rows to clear, and whether there is anything to capture at all. The
// width-aware text reconstruction (which decides where a wrapped line joins
// without a space) stays in the script, run against the spooled dump — that
// keeps the subtle part single-sourced.
struct BoxShape {
    let rows: Int
    let hasText: Bool
}

func boxShape(dump: String) -> BoxShape? {
    // read_text renders NBSP where the CLI read-screen renders plain spaces
    let lines = dump.replacingOccurrences(of: "\u{00a0}", with: " ")
        .split(separator: "\n", omittingEmptySubsequences: false)
    var seps: [Int] = []
    for (i, line) in lines.enumerated() where isRule(line) { seps.append(i) }
    guard seps.count >= 2 else { return nil }
    let region = lines[(seps[seps.count - 2] + 1)..<seps[seps.count - 1]]
    var started = false
    var hasText = false
    for line in region {
        if !started {
            guard let rest = afterPrompt(line) else { continue }
            started = true
            if !rest.isEmpty { hasText = true }
        } else {
            var t = Substring(rstrip(line))
            if t.hasPrefix("  ") { t = t.dropFirst(2) }
            if !t.isEmpty { hasText = true }
        }
    }
    return BoxShape(rows: region.count, hasText: hasText)
}

private func isRule(_ line: Substring) -> Bool {
    let t = line.trimmingCharacters(in: .whitespaces)
    if t.count < 20 { return false }
    for ch in t.unicodeScalars where ch != "\u{2500}" { return false }
    return true
}

private func rstrip(_ s: Substring) -> Substring {
    var t = s
    // python's str.rstrip() strips ALL Unicode whitespace, and the handler
    // that re-parses this same dump uses it. Stopping at space and tab would
    // make a box holding only U+3000 (CJK full-width space, one keystroke on
    // a Japanese layout) look non-empty here and empty there — and on the
    // idle branch "non-empty" means pressing Enter on it.
    while let last = t.last, last.unicodeScalars.allSatisfy({
        CharacterSet.whitespacesAndNewlines.contains($0)
    }) { t = t.dropLast() }
    return t
}

// Matches the script's `^ ?[❯>]\s?(.*)$` and returns the trailing text.
private func afterPrompt(_ line: Substring) -> Substring? {
    var t = line
    if t.hasPrefix(" ") { t = t.dropFirst() }
    guard let first = t.first, first == "❯" || first == ">" else { return nil }
    t = t.dropFirst()
    if let next = t.first, next == " " || next == "\t" { t = t.dropFirst() }
    return rstrip(t)
}

// Is the delivery pump mid-send into this surface? The lock is a symlink whose
// target is the owner's pid, so this is two syscalls and no allocation.
func deliveryInFlight(surface: String) -> Bool {
    let link = Paths.queueDir + "/" + surface + ".lock"
    guard let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: link),
          let pid = Int32(dest.trimmingCharacters(in: .whitespacesAndNewlines))
    else { return false }
    return kill(pid, 0) == 0
}

// MARK: - fast capture

// Plain substring search over bytes. Needles here are short ASCII literals,
// so the naive scan beats anything that would first have to build an index.
private func byteSearch(_ hay: ArraySlice<UInt8>, _ needle: [UInt8]) -> Bool {
    guard !needle.isEmpty, hay.count >= needle.count else { return false }
    let first = needle[0]
    let last = hay.endIndex - needle.count
    var i = hay.startIndex
    while i <= last {
        if hay[i] == first {
            var j = 1
            while j < needle.count && hay[i + j] == needle[j] { j += 1 }
            if j == needle.count { return true }
        }
        i += 1
    }
    return false
}

// Heap cell for a result produced concurrently with the code that awaits it.
private final class StoreBox { var root: [String: Any]? }

enum FastResult {
    case handled            // fully done in-process, nothing to spawn
    case spool(String)      // draft spooled + box cleared: spawn `spool <surfaceId>`
    case fallback           // nothing mutated: spawn `capture` and redo it all
}

final class FastCapture {
    private let sock = ControlSocket()

    // Sub-millisecond resolution on purpose: several stages here are around
    // 1 ms, where integer milliseconds report everything as 0 or 1 and hide
    // which one actually costs anything.
    private func elapsedMs(_ since: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - since.uptimeNanoseconds) / 1_000_000
    }

    // Open and authenticate ahead of a keypress. Called at startup and every
    // time cmux comes to the front, so the first capture after a launch or a
    // cmux restart does not pay connect+auth on the path the user waits on.
    func warmUp() {
        try? sock.ensureConnected()
    }

    func run() -> FastResult {
        if FileManager.default.fileExists(atPath: Paths.fastPathOptOut) { return .fallback }
        let started = DispatchTime.now()
        var stages: [String] = []
        var t = DispatchTime.now()
        func mark(_ name: String) {
            stages.append(String(format: "%@:%.1f", name, elapsedMs(t)))
            t = DispatchTime.now()
        }
        // Hoisted so the catch below can clear it too: a transport failure
        // after the target is known would otherwise strand the placeholder row
        // for its full 6 s TTL.
        var surfaceStamp: String? = nil
        defer { if let s = surfaceStamp { try? FileManager.default.removeItem(atPath: s) } }

        do {
            try sock.ensureConnected()
            mark("conn")

            // The daemon is not a cmux child, so there is never a
            // CMUX_WORKSPACE_ID to short-circuit this.
            // The store read does not need the workspace id until the indexing
            // step, so its file read and JSON parse ride along under the socket
            // round trip instead of queueing behind it. Results land in a
            // reference box, not a captured local: the throwing call below can
            // leave this scope while the read is still in flight.
            let store = StoreBox()
            let storeDone = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .userInteractive).async {
                if let data = FileManager.default.contents(atPath: Paths.store) {
                    store.root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                }
                storeDone.signal()
            }

            let wsResult = try sock.call("workspace.current", [:])
            guard let ws = (wsResult["workspace"] as? [String: Any])?["id"] as? String,
                  !ws.isEmpty else { return .fallback }
            mark("ws")

            var target = ""
            var sid = ""
            var running = false
            storeDone.wait()
            if let root = store.root {
                var s = ((root["activeSessionsByWorkspace"] as? [String: Any])?[ws]
                            as? [String: Any])?["sessionId"] as? String ?? ""
                if s.hasPrefix("claude-") { s = String(s.dropFirst(7)) }
                if let sess = (root["sessions"] as? [String: Any])?[s] as? [String: Any],
                   let surface = sess["surfaceId"] as? String, !surface.isEmpty {
                    target = surface
                    sid = s
                    if (sess["agentLifecycle"] as? String) == "running" { running = true }
                }
            }
            mark("store")
            if target.isEmpty {
                // store miss (e.g. right after a cmux restart): live truth
                let list = try sock.call("surface.list", ["workspace_id": ws])
                var best: (Double, String)? = nil
                for case let sr as [String: Any] in (list["surfaces"] as? [Any] ?? []) {
                    guard let binding = sr["resume_binding"] as? [String: Any],
                          (binding["kind"] as? String) == "claude",
                          let id = sr["id"] as? String, !id.isEmpty else { continue }
                    let updated = (binding["updated_at"] as? Double) ?? 0
                    if best == nil || updated > best!.0 { best = (updated, id) }
                }
                guard let pick = best else { return .fallback }
                target = pick.1
                running = true  // lifecycle unknown: queueing beats a blind submit
            }
            if !sid.isEmpty && !running && eventsShowRunning(sid: sid) {
                // the store lags right after a submit; fresh hook events win
                running = true
            }
            mark("events")

            // A delivery is typing into this box right now: what is in it is
            // the pump's own prompt, not a draft of the user's. Scraping it
            // would clear the pump's text mid-send and queue a second copy of
            // a prompt already on its way. Nothing of the user's is lost by
            // declining — there was nothing of theirs in there.
            if deliveryInFlight(surface: target) {
                qlog("capture surface=\(target) delivery in flight, ignoring press")
                return .handled
            }

            // Narrow the transient placeholder row to the captured session.
            // Done as create+remove rather than a rename: moveItem refuses an
            // existing destination, and a failed rename would strand the
            // global stamp, flashing the placeholder in every open session
            // until the statusline's 60 s orphan check fires.
            surfaceStamp = Paths.queueDir + "/capturing-" + target + ".stamp"
            FileManager.default.createFile(atPath: surfaceStamp!, contents: nil)
            try? FileManager.default.removeItem(atPath: Paths.captureStamp)

            let dump = (try sock.call("surface.read_text", ["surface_id": target])["text"]
                            as? String) ?? ""
            guard let shape = boxShape(dump: dump) else { return .fallback }
            mark("read")

            if !shape.hasText { return .handled }
            if !running {
                // Idle: no queueing needed, submit the draft as-is.
                //
                // This is the one mutation with no persisted copy behind it, so
                // it must never be redone blind: a read timeout can mean the
                // Enter landed and only the answer was lost. Retrying it — here
                // or via a `.fallback` respawn — risks submitting the draft the
                // user has already started typing into the now-empty box, which
                // is exactly the mid-turn steering this tool exists to prevent.
                // An Enter that truly never landed costs one re-press: the draft
                // is still sitting in the box.
                do {
                    _ = try sock.call("surface.send_key",
                                      ["surface_id": target, "key": "enter"], retry: false)
                    qlog(String(format: "capture surface=%@ idle, submitted draft via daemon "
                                + "in %.1fms (%@)", target, elapsedMs(started),
                                stages.joined(separator: " ")))
                } catch {
                    sock.close()
                    qlog("capture surface=\(target) idle submit failed, draft left in box: \(error)")
                }
                return .handled
            }

            // Spool BEFORE the first clear keystroke: from here on the draft
            // survives a crash, a failed spawn or a dead handler — the script's
            // orphan sweep picks up anything left behind.
            guard let spoolName = writeSpool(surface: target, dump: dump, rows: shape.rows) else {
                return .fallback
            }
            mark("spool")

            // Ctrl+K (to EOL), Ctrl+U (to line start), Backspace (join up) per
            // row; every key no-ops on an empty box, so overshooting is free.
            // A send failure here is not fatal — the handler re-clears.
            let clear = String(repeating: "\u{0b}\u{15}\u{7f}", count: shape.rows + 2)
            _ = try? sock.call("surface.send_text", ["surface_id": target, "text": clear])
            mark("clear")

            qlog(String(format: "capture surface=%@ cleared in %.1fms via daemon (%@) spool=%@",
                        target, elapsedMs(started), stages.joined(separator: " "), spoolName))
            // the handler owns the placeholder from here — it must stay until
            // the real queue row can render
            surfaceStamp = nil
            return .spool(target)
        } catch SockError.remote {
            // the server answered, it just refused (closed surface, unknown
            // id): the connection is fine, so keep it warm for the next press
            return .fallback
        } catch {
            sock.close()
            return .fallback
        }
    }

    // Last-2MB scan of the hook event log, mirroring the script: the newest
    // UserPromptSubmit/Stop for this session decides whether a turn is really
    // in flight when the store still says idle.
    //
    // Scanned as raw bytes, backwards, stopping at the first match. Decoding
    // the window into a String and splitting it cost 77 ms of the 80 ms idle
    // capture — almost none of it the read itself. Only the newest matching
    // event decides, so the first hit walking backwards is the same line a
    // forward scan would have kept as `last`; the verdict is unchanged, and
    // so is the 2 MB window that defines "recent".
    func eventsShowRunning(sid: String) -> Bool {   // internal: covered by a parity test
        guard let fh = FileHandle(forReadingAtPath: Paths.events) else { return false }
        defer { try? fh.close() }
        let end = fh.seekToEndOfFile()
        fh.seek(toFileOffset: end > 2_097_152 ? end - 2_097_152 : 0)
        let data = [UInt8](fh.readDataToEndOfFile())
        let needle = Array(("claude-" + sid).utf8)
        let submit = Array("agent.hook.UserPromptSubmit".utf8)
        let stop = Array("\"agent.hook.Stop\"".utf8)
        var hi = data.count
        while hi > 0 {
            var lo = hi - 1
            while lo > 0 && data[lo - 1] != 0x0a { lo -= 1 }
            let line = data[lo..<hi]
            if byteSearch(line, needle) {
                if byteSearch(line, submit) { return true }
                if byteSearch(line, stop) { return false }
            }
            hi = lo == 0 ? 0 : lo - 1
        }
        return false
    }

    // `<surfaceId>.<epochMs>.spool`: unique per press so a second capture can
    // never overwrite a handoff still in flight, and lexicographically sorted
    // == press order, which is the order the handler must enqueue them in.
    private func writeSpool(surface: String, dump: String, rows: Int) -> String? {
        let ms = Int(Date().timeIntervalSince1970 * 1000)
        let name = "\(surface).\(ms).spool"
        let final = Paths.queueDir + "/" + name
        let tmp = final + ".tmp"
        let header: [String: Any] = ["v": 1, "surface": surface, "ts": ms, "rows": rows]
        guard let head = try? JSONSerialization.data(withJSONObject: header),
              let headLine = String(data: head, encoding: .utf8),
              let body = (headLine + "\n" + dump).data(using: .utf8) else { return nil }
        do {
            try body.write(to: URL(fileURLWithPath: tmp))
            // the dump is the whole visible screen, so keep it to this account
            chmod(tmp, 0o600)
            try FileManager.default.moveItem(atPath: tmp, toPath: final)
        } catch {
            try? FileManager.default.removeItem(atPath: tmp)
            return nil
        }
        return name
    }
}

// MARK: - daemon

private struct Hotkey {
    let id: UInt32
    let keyCode: UInt32
    let modifiers: UInt32
    let action: String
    let sound: Bool
}

// "opt+enter", "ctrl+shift+k", "cmd+opt+space" — case and spacing free.
// Returns nil for anything it does not fully understand, so a typo falls back
// to the default rather than silently registering something else.
private let namedKeys: [String: Int] = [
    "enter": kVK_Return, "return": kVK_Return, "space": kVK_Space, "tab": kVK_Tab,
    "esc": kVK_Escape, "escape": kVK_Escape,
    "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E,
    "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J,
    "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O,
    "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
    "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y,
    "z": kVK_ANSI_Z,
    "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
    "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
    "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5, "f6": kVK_F6,
    "f7": kVK_F7, "f8": kVK_F8, "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12,
]

private func parseHotkey(_ spec: String) -> (keyCode: UInt32, modifiers: UInt32)? {
    var modifiers = 0
    var keyCode: Int?
    for rawPart in spec.lowercased().split(separator: "+") {
        let part = rawPart.trimmingCharacters(in: .whitespaces)
        switch part {
        case "opt", "option", "alt": modifiers |= optionKey
        case "cmd", "command": modifiers |= cmdKey
        case "ctrl", "control": modifiers |= controlKey
        case "shift": modifiers |= shiftKey
        default:
            // exactly one non-modifier: "opt+enter+k" is a typo, not a combo
            guard keyCode == nil, let code = namedKeys[part] else { return nil }
            keyCode = code
        }
    }
    // a bare key with no modifier would swallow that key system-wide in cmux
    guard let code = keyCode, modifiers != 0 else { return nil }
    return (UInt32(code), UInt32(modifiers))
}

private func configuredHotkey(_ path: String, _ fallback: String) -> (UInt32, UInt32) {
    guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else {
        return parseHotkey(fallback).map { ($0.keyCode, $0.modifiers) }!
    }
    let spec = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if let hk = parseHotkey(spec) { return (hk.keyCode, hk.modifiers) }
    FileHandle.standardError.write(Data(
        "ignoring unparseable hotkey \"\(spec)\" in \(path), using \(fallback)\n".utf8))
    return parseHotkey(fallback).map { ($0.keyCode, $0.modifiers) }!
}

private func currentHotkeys() -> [Hotkey] {
    let capture = configuredHotkey(Paths.hotkeyCapture, "opt+enter")
    let manage = configuredHotkey(Paths.hotkeyManage, "opt+shift+enter")
    return [
        Hotkey(id: 1, keyCode: capture.0, modifiers: capture.1, action: "capture", sound: true),
        // the manager pane is its own visible feedback, no sound needed
        Hotkey(id: 2, keyCode: manage.0, modifiers: manage.1, action: "manage-open", sound: false),
    ]
}

final class HotkeyDaemon {
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var active: [Hotkey] = currentHotkeys()
    private var lastFire = DispatchTime(uptimeNanoseconds: 0)
    private var children = Set<Process>()
    // Serial: two captures must never interleave requests on one connection,
    // and never share the socket with the main thread.
    private let captureQueue = DispatchQueue(label: "cmux-claude-queue.capture")
    private let fastCapture = FastCapture()

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

    // Connect ahead of the keypress. cmux coming to the front is the best
    // possible cue: it is the only way a hotkey can become reachable, it is
    // exactly when a cmux restart would have invalidated the old connection,
    // and it happens far enough ahead of any keystroke that connect+auth is
    // off the path the user waits on. At launch cmux may not be running yet —
    // that attempt just fails and the activation cue picks it up later.
    private func warmSocket() {
        captureQueue.async { [weak self] in self?.fastCapture.warmUp() }
    }

    private func syncRegistration(frontmost: String?) {
        let wanted = frontmost.map(targetBundleIDs.contains) ?? false
        if wanted { warmSocket() }
        if wanted && hotKeyRefs.isEmpty {
            // cmux coming to the front is the only moment a combo can become
            // reachable, so it is also the cheapest moment to notice the
            // config changed: no restart, no watcher, no cost while idle.
            active = currentHotkeys()
            for hk in active {
                var ref: EventHotKeyRef?
                let hotKeyID = EventHotKeyID(signature: OSType(0x4351_4844), id: hk.id) // "CQHD"
                let status = RegisterEventHotKey(hk.keyCode, hk.modifiers,
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
        guard let hk = active.first(where: { $0.id == id }) else { return }
        // belt and braces: registration should already scope us to the targets
        guard let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              targetBundleIDs.contains(front) else { return }
        // debounce a double-tap: two captures racing would read the same
        // screen and enqueue the draft twice
        let now = DispatchTime.now()
        guard now.uptimeNanoseconds - lastFire.uptimeNanoseconds > 300_000_000 else { return }
        lastFire = now
        if hk.sound && !FileManager.default.fileExists(atPath: Paths.soundOptOut) {
            let sound = NSSound(named: "Pop")
            sound?.volume = 0.5
            sound?.play()
        }
        guard hk.action == "capture" else { spawn(hk.action); return }
        // the fast path (or the spawned script) renames, then removes this
        // stamp; a failure that leaves it behind goes stale and the statusline
        // cleans it up
        FileManager.default.createFile(atPath: Paths.captureStamp, contents: nil)
        // Socket I/O never runs on the main thread: a wedged cmux would
        // otherwise freeze hotkey handling itself.
        captureQueue.async { [weak self] in
            guard let self else { return }
            let result = self.fastCapture.run()
            DispatchQueue.main.async {
                switch result {
                case .handled: break
                case .spool(let surface): self.spawn("spool", surface)
                case .fallback: self.spawn("capture")
                }
            }
        }
    }

    private func spawn(_ args: String...) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: captureScript)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        p.environment = env
        // hold a reference until exit so the child is reliably reaped
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async { self?.children.remove(proc) }
        }
        do { try p.run(); children.insert(p) } catch {
            FileHandle.standardError.write(Data("\(args.first ?? "?") spawn failed: \(error)\n".utf8))
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let daemon = HotkeyDaemon()
daemon.start()
app.run()
