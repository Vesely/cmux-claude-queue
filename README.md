# cmux-claude-queue

A real prompt queue for [Claude Code](https://claude.com/claude-code) running inside [cmux](https://cmux.io).

Claude Code has no native message queue: anything you type while a turn is running is injected into the *current* turn as steering. If what you actually wanted was "do this **next**", steering derails the work in progress.

`cmux-claude-queue` fixes that at the terminal level. Type your next prompt into the Claude Code input box as usual and press **Opt+Enter**:

- the draft disappears from the input box before Claude ever sees it,
- it shows up in the Claude Code statusline as `⏳ queued: …`,
- and the moment the current turn ends it is submitted as a fresh, ordinary prompt.

No new tab, no focus change, no steering. If the session is idle, Opt+Enter simply submits the draft like a plain Enter. Multiple queued prompts are delivered in FIFO order.

## How it works

Claude Code cannot intercept mid-turn input (messages typed while a turn runs bypass all its hooks), so the queue operates one level below, on the terminal itself, using cmux's control socket:

```
Opt+Enter
   │
   ▼
hotkeyd ──spawns──▶ capture ──Ctrl+U──▶ input box cleared
 (Carbon hotkey,       │
  cmux frontmost       └──▶ ~/.claude/prompt-queue/<surfaceId>.queue
  only)                            │
                                   ├──▶ statusline row "⏳ queued: …"
                                   │       (+ retry tick while non-empty)
                                   ▼
                            notifyhook (cmux notification hook)
                                   │  turn ended? draft box empty?
                                   ▼
                            types the text + Enter, then confirms
                            the submit in cmux's event log before
                            removing it from the queue
```

- **`hotkeyd/main.swift`** — a ~70-line daemon. Registers Opt+Return as a system hotkey via Carbon `RegisterEventHotKey` *only while cmux is the frontmost app* (no Accessibility permission needed) and spawns `cmux-claude-queue capture`. In every other app Opt+Enter behaves normally.
- **`capture`** — finds the Claude session in the focused cmux workspace, scrapes the draft from the terminal screen (`cmux read-screen`), clears the box, appends the draft to a per-surface queue file. Idle session: just presses Enter instead.
- **`statusline`** — a Claude Code `statusLine` wrapper. Chains your previous statusline command (if any), appends the queue row, and doubles as a delivery pump: pressing Esc kills a turn without emitting any event, so the periodic statusline refresh fires an invisible retry notification while the queue is non-empty.
- **`notifyhook`** — a cmux notification hook. On every notification (turn complete, or a retry tick) it checks per session whether the turn is really over, types the queued text into the input box and presses Enter, then waits for the matching `UserPromptSubmit` event in cmux's event log before removing the item from the queue. It backs off if you have a new draft in the box, and never injects into a running turn.

Everything is keyed by cmux surface id, so with multiple workspaces each Claude session has its own isolated queue; a prompt can only ever be delivered to the surface it was captured from.

## Requirements

- macOS, [cmux](https://github.com/manaflow-ai/cmux) ≥ 0.64.20, Claude Code
- Xcode Command Line Tools (`swiftc`, for building the daemon)
- `python3` on `$PATH` (macOS system Python is fine)

## Install

```sh
git clone https://github.com/davidvesely/cmux-claude-queue
cd cmux-claude-queue
./install.sh
```

The installer symlinks `bin/cmux-claude-queue` into `~/.local/bin`, builds the daemon, and loads the `com.cmux-claude-queue.hotkeyd` LaunchAgent. It then prints the two config snippets you need to add yourself:

1. **`~/.config/cmux/cmux.json`** — set `automation.socketControlMode` to `"password"` with a generated `automation.socketPassword` (the hotkey daemon is not a cmux child process, and cmux's default `cmuxOnly` socket mode rejects it; the cmux CLI auto-authenticates using the stored password), and register `cmux-claude-queue notifyhook` under `notifications.hooks`. Run `cmux reload-config` afterwards.
2. **`~/.claude/settings.json`** — point `statusLine.command` at `cmux-claude-queue statusline` with `refreshInterval: 5`.

If you already had a `statusLine` command, save it as a small shell script at `~/.config/cmux-claude-queue/statusline-chain` (it receives the statusline JSON on stdin); its output stays on top and the queue row is appended below.

## Extras

- **`extras/qq`** — queue a prompt from Claude Code's `!` bash mode instead of the hotkey: `!qq fix the tests next`. Works mid-turn; the text is enqueued and delivered after the turn ends. Copy it into `~/.local/bin` if you want it. Caveat: the shell parses the text first, so unbalanced quotes, `$` or backticks will not survive.
- **Command Palette fallback** — you can additionally register a cmux action that runs `cmux-claude-queue capture` (type `command`, target `newTabInCurrentPane`) to trigger a capture without the daemon, e.g. from the Command Palette. This opens a short-lived tab; the hotkey path does not.

## Performance

The tool is built to be invisible on a busy machine — everything is event-driven, nothing polls:

- The hotkey daemon sits at 0% CPU (Carbon hotkey + app-activation callbacks, no event tap, no timers) and ~30 MB RSS.
- The statusline wrapper adds about 10 ms of pure bash on top of whatever your own chained statusline costs; an interpreter is spawned only in the one session that owns a non-empty queue (other sessions get a plutil lookup in single-digit milliseconds).
- The capture hot path (hotkey → box cleared) spawns exactly one Python process — session lookup, event-log check, screen scrape and box parse all happen inside it — plus two cmux socket calls. Interpreter startup dominates this path on a loaded machine, which is why it is one process instead of four.
- The notification hook answers cmux with a pure-bash passthrough for every foreign notification, so it never delays your notifications; JSON rewriting runs only for the tool's own invisible retry ticks.
- Delivery attempts are triggered by turn-complete notifications and by the statusline retry tick (rate-limited to one per 15 s, and only while a queue is non-empty). With empty queues the tool does no periodic work at all.

## Safety properties

- A queued prompt is only submitted when the session is idle; the running turn never sees it. Turn state is decided from cmux's Claude hook events, with an on-screen spinner check as the tiebreaker (covers Esc-interrupted turns, which emit no event at all).
- Delivery is confirmed against cmux's event log (session id + exact prompt length) before the item leaves the queue; unconfirmed sends are retried, and a late-arriving submit is detected instead of re-sent (no duplicates).
- If you start typing a new draft while something is queued, delivery backs off until the box is free — your draft is never overwritten.

## Limitations

- One Claude session per cmux workspace is assumed (the capture targets the workspace's active Claude surface).
- A cmux restart regenerates surface ids: prompts still queued at that point are orphaned (never misdelivered, just left behind in `~/.claude/prompt-queue/`).
- Multi-line drafts are joined into a single line when captured off the screen.
- Ghostty support is stubbed in the daemon but needs a capture backend (Ghostty has no read-screen IPC yet).

## Uninstall

```sh
launchctl bootout gui/$(id -u)/com.cmux-claude-queue.hotkeyd
rm ~/Library/LaunchAgents/com.cmux-claude-queue.hotkeyd.plist
rm ~/.local/bin/cmux-claude-queue ~/.local/bin/cmux-claude-queue-hotkeyd
rm -rf ~/.claude/prompt-queue ~/.config/cmux-claude-queue
```

Then remove the `notifications.hooks` entry (and, if you wish, the `automation` block) from `cmux.json` and restore your previous `statusLine` in Claude Code's `settings.json`.

## License

MIT
