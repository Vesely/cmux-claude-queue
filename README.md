# cmux-claude-queue

A real prompt queue for [Claude Code](https://claude.com/claude-code) running inside [cmux](https://cmux.io).

Claude Code has no native message queue: anything you type while a turn is running is injected into the *current* turn as steering. If what you actually wanted was "do this **next**", steering derails the work in progress.

`cmux-claude-queue` fixes that at the terminal level. Type your next prompt into the Claude Code input box as usual and press **Opt+Enter**:

- the box empties within milliseconds, a quiet "Pop" confirms the press, and the statusline shows `⏳ Queuing…` until the real `⏳ Queue: …` row takes over about a second later,
- the draft — all of it, multi-line included — disappears from the input box a couple hundred milliseconds after the press, before Claude ever sees it, and fills in the queue row,
- and the moment the current turn ends it is submitted as a fresh, ordinary prompt.

No new tab, no focus change, no steering. If the session is idle, Opt+Enter simply submits the draft like a plain Enter. Multiple queued prompts are delivered in FIFO order.

**Opt+Shift+Enter** opens the queue manager: a small split pane below the session listing everything waiting. Arrows (or `j`/`k`) select, `Enter`/`e` edits the prompt in place (prefilled, readline editing), `d` deletes it, `q`/`Esc` closes the pane. Edits and deletes share the delivery lock, so racing an in-flight delivery is safe; the list live-refreshes while open.

## How it works

Claude Code cannot intercept mid-turn input (messages typed while a turn runs bypass all its hooks), so the queue operates one level below, on the terminal itself, using cmux's control socket:

```
Opt+Enter
   │
   ▼
hotkeyd ──warm socket──▶ read box ─▶ <surfaceId>.<ms>.spool ─▶ box cleared
 (Carbon hotkey,          (in-process, no spawn — ~10 ms to here)     │
  cmux frontmost                                                     │
  only)                                                              ▼
                                            spool ──▶ ~/.claude/prompt-queue/<surfaceId>.queue
                                         (spawned)              │
                                                                ├──▶ statusline row "⏳ Queue: …"
                                                                │       (+ retry tick while non-empty)
                                                                ▼
                                                         notifyhook (cmux notification hook)
                                                                │  turn ended? draft box empty?
                                                                ▼
                                                         types the text + Enter, then confirms
                                                         the submit in cmux's event log before
                                                         removing it from the queue
```

- **`hotkeyd/main.swift`** — the daemon. Registers Opt+Return (capture) and Opt+Shift+Return (queue manager) as system hotkeys via Carbon `RegisterEventHotKey` *only while cmux is the frontmost app* (no Accessibility permission needed). In every other app both combos behave normally. It also performs the capture itself, in-process, over one warm authenticated control-socket connection: resolve the target session, read the box, spool the draft, clear the box. Spawning a helper for that used to cost 100–500 ms of `fork`/`exec` plus interpreter startup before anything visible happened, which no amount of optimizing inside the helper could fix. It plays a quiet "Pop" the instant the hotkey fires (`touch ~/.config/cmux-claude-queue/no-sound` to disable), and `touch ~/.config/cmux-claude-queue/no-fastpath` forces every capture back through the spawned script.
- **`spool`** — the deferred half of that capture, spawned once the box is already clear. It parses the spooled screen dump (the width-aware join that reconstructs a wrapped draft stays here, not in Swift), drops double-press duplicates, appends to the queue file, verifies the clear landed and nudges delivery. None of it is on the path the user waits for.
- **`capture`** — the same sequence as a standalone process, used from the Command Palette and as the daemon's automatic fallback whenever the socket is unavailable, auth is refused, or the screen does not parse. It talks to the control socket directly too, with a cmux-CLI path behind that.
- The draft is written to its spool file **before** the first clear keystroke goes out, so a crash, a failed spawn or a dead handler can never destroy it — worst case it sits on disk and the next notification (or statusline refresh) replays it. A marker file stamped at the keypress itself makes the statusline show a transient `⏳ Queuing…` placeholder until the real queue row takes over.
- **`statusline`** — a Claude Code `statusLine` wrapper. Serves your previous statusline command (if any) stale-while-revalidate: its last output comes from a per-session cache instantly and a detached background job refreshes the cache when it is older than 10 s, so the wrapper never blocks on an expensive chain (Claude Code kills statusline commands that outlive the refresh interval). It appends the queue row and doubles as a delivery pump: pressing Esc kills a turn without emitting any event, so the periodic statusline refresh fires an invisible retry notification while the queue is non-empty.
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

The installer copies `bin/cmux-claude-queue` into `~/.local/bin` (re-run it after a `git pull` to upgrade; `./install.sh --dev` symlinks instead so repo edits go live), builds the daemon, and loads the `com.cmux-claude-queue.hotkeyd` LaunchAgent. It then prints the two config snippets you need to add yourself:

1. **`~/.config/cmux/cmux.json`** — set `automation.socketControlMode` to `"password"` with a generated `automation.socketPassword` (the hotkey daemon is not a cmux child process, and cmux's default `cmuxOnly` socket mode rejects it; the cmux CLI auto-authenticates using the stored password), and register `cmux-claude-queue notifyhook` under `notifications.hooks`. Run `cmux reload-config` afterwards. Be aware of the trade-off: password mode means any process that can read your `cmux.json` can control your cmux terminals — that file is `600` in your home directory, so this is the same trust boundary as your shell startup files, but it is a wider gate than the default `cmuxOnly` mode.
2. **`~/.claude/settings.json`** — point `statusLine.command` at `cmux-claude-queue statusline` with `refreshInterval: 1`.

If you already had a `statusLine` command, save it as a small shell script at `~/.config/cmux-claude-queue/statusline-chain` (it receives the statusline JSON on stdin); its output stays on top and the queue row is appended below. The chain runs only in a detached background job that refreshes a per-session cache every ~10 s, so the short refresh interval makes the queue row show up fast while your own statusline runs *less* often than the usual 5 s cadence — and a slow statusline can no longer be killed mid-run by the refresh cycle.

## External-editor capture (optional)

Claude Code's Ctrl+G (`chat:externalEditor`) writes the current draft to a temp file, opens `$EDITOR` on it and restores the box from the file when the editor exits. Pointing that at the queue turns Ctrl+G into a second, even higher-fidelity capture gesture:

1. Add to `~/.claude/settings.json`: `"env": { "EDITOR": "~/.local/bin/cmux-claude-queue-editor" }` (expanded path).
2. Save your actual editor command for passthrough: `echo "zed" > ~/.config/cmux-claude-queue/real-editor`.

With that in place (for sessions started after the change), pressing **Ctrl+G during a running turn** queues the draft *exactly as typed* — real newlines and blank lines included (the screen scrape cannot see those), no scrape at all — and the box clears natively, since the TUI itself restores it from the emptied file. Pressing **Ctrl+G on an idle session** passes through to your real editor, exactly like vanilla Claude Code; so does every non-prompt use of `$EDITOR` inside a session (e.g. `git commit` from `!` bash mode). Note: queued prompts are still stored one per line, so the preserved newlines are currently joined for delivery.

## Extras

- **`extras/qq`** — queue a prompt from Claude Code's `!` bash mode instead of the hotkey: `!qq fix the tests next`. Works mid-turn; the text is enqueued and delivered after the turn ends. Copy it into `~/.local/bin` if you want it. Caveat: the shell parses the text first, so unbalanced quotes, `$` or backticks will not survive.
- **Command Palette fallback** — you can additionally register a cmux action that runs `cmux-claude-queue capture` (type `command`, target `newTabInCurrentPane`) to trigger a capture without the daemon, e.g. from the Command Palette. This opens a short-lived tab; the hotkey path does not.

## Performance

The tool is built to be invisible on a busy machine — everything is event-driven, nothing polls:

- The hotkey daemon sits at 0% CPU (Carbon hotkey + app-activation callbacks, no event tap, no timers) and ~25 MB RSS — unchanged by moving the capture in-process, which is the whole reason it lives there rather than in a second resident helper.
- The statusline wrapper's hot path is bash builtins almost end to end: the payload is parsed with substring expansion (no JSON tool), the session→surface lookup is a one-line cached file read, and freshness checks hide behind `[ -f ]` guards. A run costs roughly half of what it did when every refresh paid two `plutil` spawns, which is what makes the 1 s refresh interval a net-zero change in total load. An interpreter is spawned only in the one session that owns a non-empty queue.
- The chained statusline never runs in the foreground: its output is served from a per-session cache (stale-while-revalidate, 10 s TTL, refreshed by a detached background job), so the wrapper finishes in tens of milliseconds regardless of what the chain costs. With many sessions open this makes the tool *reduce* total statusline load compared to a plain 5 s cadence, while the queue row still appears within ~1 s of a capture.
- The capture hot path (hotkey → box cleared) creates no processes at all. The already-resident daemon holds one warm authenticated socket, so the whole sequence is a handful of round-trips: measured ~5 ms for the workspace lookup, ~1.2 ms per screen read, ~1 ms for the clear, against 3.9 ms of one-time connect and auth. That is single-digit milliseconds and, more importantly, it does not degrade under load — the 100–500 ms this used to spend on `fork`/`exec` and interpreter startup was invisible in any in-process measurement and dominated the real experience. Parsing, queueing and clear verification happen afterwards in a spawned helper, where their cost is not felt.
- Everything the daemon adds is in-process: one socket fd and a few hundred bytes of state, no second resident interpreter and nothing per-surface, so many open sessions cost the same as one.
- The notification hook answers cmux with a pure-bash passthrough for every foreign notification, so it never delays your notifications; JSON rewriting runs only for the tool's own invisible retry ticks.
- Delivery attempts are triggered by turn-complete notifications and by the statusline retry tick (rate-limited to one per 15 s, and only while a queue is non-empty). With empty queues the tool does no periodic work at all.

## Safety properties

- A queued prompt is only submitted when the session is idle; the running turn never sees it. Turn state is decided from cmux's Claude hook events: a turn counts as running until its `Stop`, and *any* hook event for the session (a tool call, a permission request…) is proof it is still alive, so an hour-long turn stays running for as long as it keeps emitting. Only a session that has gone completely silent for 30 s falls back to the on-screen spinner check, which is what covers Esc-interrupted turns (they emit no event at all).
- Delivery is confirmed against cmux's event log (session id + exact prompt length) before the item leaves the queue; unconfirmed sends are retried, and a late-arriving submit is detected instead of re-sent (no duplicates). Modern Claude Code has its own mid-turn queue that swallows a submit and emits no event until the turn ends, so a send whose text left the input box is treated as in flight: it is neither re-sent nor counted against the retry cap until the event finally lands. Slash commands (`/compact`, `/clear`, skills…) run inside the Claude Code TUI and emit no submit event, so they are confirmed by the input box clearing instead. As a backstop, a line still unconfirmed after three full sends is dropped with a notification (and kept in the log) rather than resubmitted forever.
- Delivery is crash-safe against the process being killed mid-flight (cmux reaps notification-hook processes when their notification clears): the confirmed submit is recorded *before* the item is popped, so if the pop never lands the next tick recognizes the recorded submit and pops without resending.
- If you start typing a new draft while something is queued, delivery backs off until the box is free — your draft is never overwritten. Claude Code's ghost-text prompt suggestions scrape identically to a typed draft, so they are told apart by a reversible one-key probe (a suggestion sits over an empty input buffer, a draft does not) and never block delivery.
- A nervous double Opt+Enter cannot enqueue the draft twice: the second capture can race the box clear and scrape the same text again, so an identical line captured within 3 s is dropped. Deliberately re-queueing the same prompt later still works.

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
rm -f ~/.local/bin/cmux-claude-queue-editor
rm -rf ~/.claude/prompt-queue ~/.config/cmux-claude-queue
```

(If you installed with `CMUX_CLAUDE_QUEUE_BIN_DIR` set, remove the two binaries from that directory instead of `~/.local/bin`.)

Then remove the `notifications.hooks` entry (and, if you wish, the `automation` block) from `cmux.json` and restore your previous `statusLine` in Claude Code's `settings.json`.

## License

MIT
