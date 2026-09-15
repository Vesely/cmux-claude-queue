# Internals

How the queue is built, and why each part is shaped the way it is. For getting it running,
see the [README](../README.md).

## The problem it works around

Claude Code cannot intercept mid-turn input — messages typed while a turn runs bypass all of
its hooks, and steering messages never fire `UserPromptSubmit`. So the queue operates one level
below, on the terminal itself, through cmux's control socket.

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
                                                         the submit before removing it from
                                                         the queue
```

## Components

- **`hotkeyd/main.swift`** — the daemon. Registers Opt+Return (capture) and Opt+Shift+Return
  (queue manager) via Carbon `RegisterEventHotKey` *only while cmux is frontmost*, so no
  Accessibility permission is needed and both combos behave normally in every other app. It
  performs the capture in-process over one warm authenticated control-socket connection:
  resolve the session, read the box, spool the draft, clear the box. Spawning a helper for that
  used to cost 100–500 ms of `fork`/`exec` plus interpreter startup before anything visible
  happened. It plays a quiet "Pop" the instant the hotkey fires
  (`touch ~/.config/cmux-claude-queue/no-sound` to disable);
  `touch ~/.config/cmux-claude-queue/no-fastpath` forces every capture back through the script.
- **`spool`** — the deferred half of the capture, spawned once the box is already clear. Parses
  the spooled screen dump (the width-aware join that reconstructs a wrapped draft lives here,
  not in Swift), drops double-press duplicates, appends to the queue file, verifies the clear
  landed, nudges delivery. None of it is on the path the user waits for.
- **`capture`** — the same sequence as a standalone process. Used from the Command Palette and
  as the daemon's fallback whenever the socket is unavailable, auth is refused, or the screen
  does not parse.
- **`statusline`** — a Claude Code `statusLine` wrapper. Serves your previous statusline command
  stale-while-revalidate from a per-session cache, so the wrapper never blocks on an expensive
  chain. It appends the queue row and doubles as a delivery pump: pressing Esc kills a turn
  without emitting any event, so the periodic refresh fires an invisible retry while the queue
  is non-empty.
- **`notifyhook`** — a cmux notification hook. On every notification (turn complete, or a retry
  tick) it checks whether the turn is really over, types the queued text into the input box and
  presses Enter, then confirms the submit before removing the item from the queue.

The draft is written to its spool file **before** the first clear keystroke goes out, so a
crash, a failed spawn or a dead handler can never destroy it — worst case it sits on disk and
the next tick replays it.

Everything is keyed by cmux surface id, so each Claude session has its own isolated queue and a
prompt can only ever be delivered to the surface it was captured from.

## Safety properties

- **Only submitted when the session is idle.** Turn state comes from cmux's Claude hook events:
  a turn counts as running until its `Stop`, and *any* hook event for the session is proof it is
  still alive, so an hour-long turn stays running as long as it keeps emitting. Only a session
  silent for 30 s falls back to the on-screen spinner check, which is what covers Esc-interrupted
  turns — they emit no event at all.
- **Confirmed before it leaves the queue.** Delivery is verified against Claude Code's own
  transcript, which identifies the prompt exactly at any length, bounded by a timestamp so a
  deliberate repeat is not confirmed by its predecessor. Where the transcript is missing or too
  large, cmux's `workspace.prompt.submitted` event is the fallback; its 240-character preview
  does not saturate the way `tool_input_length` does. Slash commands emit no submit event at all,
  so they are confirmed by the input box clearing instead.
- **No duplicates.** A send whose text left the input box is treated as in flight — neither
  re-sent nor counted against the retry cap — because Claude Code's own mid-turn queue swallows
  a submit and emits no event until the turn ends. A late-arriving submit is detected rather than
  re-sent. As a backstop, a line still unconfirmed after three full sends is parked with a
  notification rather than resubmitted forever.
- **Crash-safe.** cmux reaps notification-hook processes when their notification clears, so the
  confirmed submit is recorded *before* the item is popped; if the pop never lands, the next tick
  recognizes the record and pops without resending.
- **Never clobbers your draft.** If you start typing while something is queued, delivery backs
  off until the box is free. Claude Code's ghost-text suggestions scrape identically to a typed
  draft, so they are told apart by a reversible one-key probe — a suggestion sits over an empty
  input buffer, a draft does not. If a real draft blocks delivery for ten minutes you get a
  notification, because otherwise the only sign is the statusline row.
- **A nervous double Opt+Enter cannot enqueue twice.** The second capture can race the box clear
  and scrape the same text again, so an identical line captured within 3 s is dropped.
  Deliberately re-queueing the same prompt later still works.

## Performance

Everything is event-driven; nothing polls.

- The hotkey daemon sits at 0% CPU (Carbon hotkey + app-activation callbacks, no event tap, no
  timers) and ~25 MB RSS.
- The capture hot path creates no processes at all. The resident daemon holds one warm
  authenticated socket, so the sequence is a handful of round trips: ~5 ms workspace lookup,
  ~1.2 ms per screen read, ~1 ms for the clear, against 3.9 ms of one-time connect and auth.
- The statusline wrapper's hot path is bash builtins almost end to end — the payload is parsed
  with substring expansion, the session→surface lookup is a cached one-line file read. An
  interpreter is spawned only in the session that owns a non-empty queue.
- The chained statusline never runs in the foreground: its output comes from a per-session cache
  refreshed by a detached background job. With many sessions open this makes the tool *reduce*
  total statusline load compared to a plain 5 s cadence.
- The notification hook answers cmux with a pure-bash passthrough for every foreign notification,
  so it never delays your notifications.
- Delivery attempts are triggered by turn-complete notifications and by the statusline retry tick
  (one per 15 s, only while a queue is non-empty). With empty queues the tool does no periodic
  work at all.

## External-editor capture

Claude Code's Ctrl+G (`chat:externalEditor`) writes the current draft to a temp file, opens
`$EDITOR` on it, and restores the box from the file when the editor exits. Pointing that at the
queue turns Ctrl+G into a higher-fidelity capture gesture:

1. `~/.claude/settings.json`: `"env": { "EDITOR": "~/.local/bin/cmux-claude-queue-editor" }`
   (expanded path).
2. Save your real editor for passthrough:
   `echo "zed" > ~/.config/cmux-claude-queue/real-editor`.

For sessions started after the change, **Ctrl+G during a running turn** queues the draft exactly
as typed — real newlines and blank lines included, which a screen scrape cannot see — and the box
clears natively, since the TUI restores it from the emptied file. **Ctrl+G on an idle session**
passes through to your real editor, as does every other use of `$EDITOR` inside a session (e.g.
`git commit` from `!` bash mode). Note that queued prompts are stored one per line, so preserved
newlines are currently joined for delivery.

The passthrough editor must block: `zed --wait`, not plain `zed`, which exits immediately and
lets the TUI restore the unedited file.

## Command Palette fallback

You can register a cmux action running `cmux-claude-queue capture` (type `command`, target
`newTabInCurrentPane`) to trigger a capture without the daemon. This opens a short-lived tab; the
hotkey path does not.
