# Internals

How the queue is built, and why each part is shaped the way it is. For getting it running,
see the [README](../README.md).

## The problem it works around

Hooks cannot intercept mid-turn input — a message Claude Code consumes mid-turn bypasses them
all, and steering messages never fire `UserPromptSubmit`. So the queue operates one level below,
on the terminal itself, through cmux's control socket.

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
  (queue manager) via Carbon `RegisterEventHotKey` (no Accessibility permission needed), and
  *only while cmux is frontmost*, so both combos behave normally in every other app. It
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
  stale-while-revalidate from a per-session cache, so an expensive chain does not hold up the
  wrapper (see Performance for the one case where it still runs inline). It appends the queue row and doubles as a delivery pump: pressing Esc kills a turn
  without emitting any event, so the periodic refresh fires an invisible retry while the queue
  is non-empty.
- **`notifyhook`** — a cmux notification hook. On every notification (turn complete, or a retry
  tick) it checks whether the turn is really over, types the queued text into the input box and
  presses Enter, then confirms the submit before removing the item from the queue.

The draft is written to its spool file **before** the first clear keystroke goes out, so a crash
or a failed spawn after that point cannot lose the text: worst case it sits on disk and the next
tick replays it. A failed write, or an unreadable spool file, is not covered.

Queue and spool filenames are keyed by cmux surface id, and delivery addresses that same id, so
each Claude session has its own queue.

## Safety properties

- **Submitted only once the session looks idle.** Turn state comes from cmux's Claude hook events:
  a turn counts as running until its `Stop`, and *any* hook event for the session is proof it is
  still alive, so an hour-long turn stays running as long as it keeps emitting. Only a session
  silent for 30 s falls back to the on-screen spinner check, which is what covers Esc-interrupted
  turns — they emit no event at all.
- **Confirmed before it leaves the queue.** Delivery is verified against Claude Code's own
  transcript, which matches the prompt in full at any length, bounded by a timestamp so a
  deliberate repeat is not confirmed by its predecessor. The scan stops after 64 MiB; past that,
  or when the transcript is missing, cmux's `workspace.prompt.submitted` event is the fallback,
  because its 240-character preview still identifies a long prompt. Slash commands emit no submit event at all,
  so they are confirmed by the input box clearing instead.
- **Bounded resends.** A send whose text left the input box is treated as in flight — neither
  re-sent nor counted against the retry cap — because Claude Code's own mid-turn queue swallows
  a submit and emits no event until the turn ends. A late-arriving submit is detected rather than
  re-sent. As a backstop, a line still unconfirmed after three full sends is parked with a
  notification rather than resubmitted forever.
- **Survives the hook being killed mid-pop.** cmux reaps notification-hook processes when their
  notification clears, so the confirmed submit is recorded *before* the item is popped; if the pop
  never lands, the next tick recognizes the record and pops without resending. That covers this one
  window, not every possible crash.
- **Checks the box before typing.** If you start typing while something is queued, delivery backs
  off until the box is free; you can still type into the gap between that check and the keystrokes.
  Claude Code's ghost-text suggestions scrape identically to a typed draft, so they are told apart
  by a reversible one-key probe: a suggestion sits over an empty input buffer, a draft does not.
  If a real draft blocks delivery for ten minutes you get a notification, because otherwise the
  only sign is the statusline row.
- **A nervous double Option+Enter does not enqueue twice.** The daemon debounces for 300 ms, and a
  second capture that races the box clear and scrapes the same text is dropped if it lands within
  3 s. Deliberately re-queueing the same prompt later still works.

## Performance

Delivery is driven by events rather than a poll loop, with two exceptions: confirming a submit
polls for about six seconds after the keys go out, and a non-empty queue allows one retry tick
every 15 s.

- The hotkey daemon measured 0% CPU and ~25 MB RSS on the author's machine: Carbon hotkey plus
  app-activation callbacks, no event tap, no timers.
- Nothing is spawned before the box is clear. The resident daemon holds one warm authenticated
  socket, so the sequence is a handful of round trips, measured here at ~5 ms for the workspace
  lookup, ~1.2 ms per screen read and ~1 ms for the clear, against 3.9 ms of one-time connect and
  auth. Those are medians: sampling `workspace.current` 900 times also gave a p99 of ~90 ms and a
  580 ms maximum when cmux's socket thread was busy.
- The statusline wrapper's hot path is bash builtins almost end to end — the payload is parsed
  with substring expansion, the session→surface lookup is a cached one-line file read. The queue
  row starts `python3` only in the session that owns a non-empty queue.
- The chained statusline normally runs in a detached background job and the wrapper serves its
  cached output, so the wrapper finishes in tens of milliseconds whatever the chain costs. A
  payload with no `session_id` has no cache to serve and falls back to running the chain inline.
  With many sessions open, caching the chain cuts how often it runs at all.
- The notification hook reads the payload with `cat` and echoes it straight back for every foreign
  notification, before doing any work of its own, so it adds no visible delay.
- Delivery attempts are triggered by every cmux notification and by the statusline retry tick
  (one per 15 s, only while a queue is non-empty). With every queue empty the tool schedules no
  work of its own, though Claude Code still runs the statusline on its refresh interval.

## External-editor capture

Claude Code's Ctrl+G (`chat:externalEditor`) writes the current draft to a temp file, opens
`$EDITOR` on it, and restores the box from the file when the editor exits. Pointing that at the
queue turns Ctrl+G into a higher-fidelity capture gesture:

1. `~/.claude/settings.json`: `"env": { "EDITOR": "/Users/<you>/.local/bin/cmux-claude-queue-editor" }`
   — the `env` block does not expand `~`.
2. Save your real editor for passthrough:
   `echo "zed" > ~/.config/cmux-claude-queue/real-editor`.

For sessions started after the change, **Ctrl+G during a running turn** queues the draft without
scraping the screen at all: the text comes from the file the TUI wrote, so wrapping, width and
rendering cannot corrupt it, and the box clears natively when the TUI restores the emptied file.
**Ctrl+G on an idle session** passes through to your real editor, as does every other use of
`$EDITOR` inside a session (`git commit` from `!` bash mode, for instance).

It does not preserve line breaks. Queued prompts are stored one per line, so the editor path runs
`tr '\n' ' '` on the file before appending it, exactly as the screen path does.

The passthrough editor must block: `zed --wait`, not plain `zed`, which exits immediately and
lets the TUI restore the unedited file.

## `!qq` — queue from bash mode

`extras/qq` queues a prompt from inside Claude Code's `!` bash mode: `!qq fix the tests next`.
It works mid-turn and never touches focus. It is not installed for you — copy it yourself:

```sh
install -m 755 extras/qq ~/.local/bin/qq                              # from a clone
install -m 755 "$(npm root -g)/cmux-claude-queue/extras/qq" ~/.local/bin/qq   # from npm
```

The shell parses the text first, so unbalanced quotes, `$` and backticks will not survive.

## Command Palette fallback

You can register a cmux action running `cmux-claude-queue capture` (type `command`, target
`newTabInCurrentPane`) to trigger a capture without the daemon. This opens a short-lived tab; the
hotkey path does not.
