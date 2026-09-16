<h1 align="center">cmux-claude-queue</h1>

<h4 align="center">
  Press <code>Option+Enter</code> instead of <code>Enter</code>.<br>
  Your draft leaves the input box, waits on disk, and goes in as a new turn once the current one has ended.
</h4>

<p align="center">
  <a href="https://www.npmjs.com/package/cmux-claude-queue"><img src="https://img.shields.io/npm/v/cmux-claude-queue" alt="npm version"></a>
  <img src="https://img.shields.io/badge/platform-macOS-lightgrey" alt="macOS only">
  <a href="https://github.com/manaflow-ai/cmux"><img src="https://img.shields.io/badge/requires-cmux-black" alt="requires cmux"></a>
</p>

<p align="center">
  <img alt="Option+Enter queues a draft while Claude is working; it is submitted as a new turn once that turn finishes" src="docs/demo.gif">
</p>

<p align="center">
  For <a href="https://claude.com/claude-code">Claude Code</a> running in <a href="https://cmux.io">cmux</a>.
</p>

## Why not the built-in queue

Claude Code already queues what you type mid-turn. The catch is *when* it hands it over:

> if you queue a message while Claude is running tool calls, Claude Code passes it to Claude **as
> soon as those tool calls finish, within the same turn**
>
> — [Claude Code docs](https://code.claude.com/docs/en/interactive-mode#when-claude-code-sends-what-you-queued)

So "do this next" can land in the middle of the work it was meant to follow. Codex CLI behaves
the same way: its hint reads *"Messages to be submitted after next tool call"*.

This tool keeps the draft outside Claude Code, on disk, one queue per cmux surface. It submits
only once the session looks idle — a `Stop` hook event, or a silent session plus an idle
screen — and it checks the prompt arrived before dropping it from the queue.

The 205-👍 request for a queue,
[#50246](https://github.com/anthropics/claude-code/issues/50246), was closed when the native one
shipped. The thread carried on anyway: *"half of the time claude read them before finishing
current task … This makes it super unreliable."* Still open:
[#33323](https://github.com/anthropics/claude-code/issues/33323) and
[#63190](https://github.com/anthropics/claude-code/issues/63190).

## Use it

| Key | What happens |
| --- | --- |
| `Option+Enter` | Queues the draft. The box clears at once; the statusline shows `⏳ Queue: …` |
| `Option+Shift+Enter` | Opens the queue manager: `↑↓` select, `e` edit, `d` delete, `q` close |

On an idle session `Option+Enter` acts like plain `Enter`. Each cmux surface has its own FIFO
queue, and delivery targets that same surface.

Both shortcuts are registered only while cmux is frontmost, so they behave normally everywhere
else.

<details>
<summary>Or pick your own keys</summary>

```sh
echo 'ctrl+shift+enter' > ~/.config/cmux-claude-queue/hotkey-capture
echo 'ctrl+shift+m'     > ~/.config/cmux-claude-queue/hotkey-manage
```

Modifiers are `cmd`, `opt`, `ctrl` and `shift`; keys are `enter`, `space`, `tab`, `esc`, `a`–`z`,
`0`–`9` and `f1`–`f12`. At least one modifier is required, so a bare key cannot be swallowed
inside cmux. A combo the daemon cannot parse is ignored in favour of the default, with a line in
`~/.claude/prompt-queue/hotkeyd.err.log`.

The change applies the next time cmux comes to the front. No restart, and nothing to reload.

</details>

## Setup

Needs macOS, [cmux](https://github.com/manaflow-ai/cmux) ≥ 0.64.20, Claude Code, `python3`, and
the Xcode Command Line Tools for `swiftc`.

**1. Install**

```sh
npm i -g cmux-claude-queue
cmux-claude-queue-setup
```

`setup` builds the hotkey daemon, loads its LaunchAgent, and prints two config snippets with
your paths filled in. It does not edit either file for you.

**2. Paste the cmux snippet** into `~/.config/cmux/cmux.json`, then run `cmux reload-config`.

**3. Paste the Claude Code snippet** into `~/.claude/settings.json`.

Already have a statusline command? Save it as `~/.config/cmux-claude-queue/statusline-chain`
first. Its output is cached for 180 s, and the queue row is appended below it.

> **Password mode.** Step 2 turns on socket password control, so any process that can read your
> `cmux.json` can drive your cmux terminals. Check the file is `chmod 600`. This is a wider gate
> than cmux's default `cmuxOnly` mode, which rejects the hotkey daemon because the daemon is not
> a cmux child process.

<details>
<summary>Or let your agent do it</summary>

Paste this into Claude Code:

> Install cmux-claude-queue: run `npm i -g cmux-claude-queue && cmux-claude-queue-setup`, apply
> the two snippets it prints to `~/.config/cmux/cmux.json` and `~/.claude/settings.json`, move
> any existing statusLine command to `~/.config/cmux-claude-queue/statusline-chain` first, then
> run `cmux reload-config` and tell me what you changed.

</details>

<details>
<summary>Or install from source</summary>

```sh
git clone https://github.com/Vesely/cmux-claude-queue
cd cmux-claude-queue && ./install.sh
```

A clone is copied into `~/.local/bin`, so re-run `./install.sh` after a `git pull`. An npm
install is symlinked, so `npm update -g` updates the scripts — but not the compiled daemon.
Re-run `cmux-claude-queue-setup` for that.

</details>

## Limitations

- One Claude session per cmux workspace: capture targets that workspace's active Claude surface.
- Newlines in a draft become spaces. Queued prompts are stored one per line.
- A cmux restart regenerates surface ids. Anything still queued stays under the old id in
  `~/.claude/prompt-queue/` and is not delivered.
- Delivery stops after three unconfirmed sends and notifies you, rather than resending forever.
  The text survives — in the input box, the queue or the log — but you finish it yourself.
- Every queued prompt is also written to `~/.claude/prompt-queue/log.txt`, which is never
  rotated. That log is how a parked prompt is recovered, so check it before sharing it.
- cmux only. Ghostty has no capture backend.

## Uninstall

Your previous statusline command is in `~/.config/cmux-claude-queue/statusline-chain`. Copy it
back into Claude Code's `settings.json` before you delete that directory.

```sh
launchctl bootout gui/$(id -u)/com.cmux-claude-queue.hotkeyd
rm -f ~/Library/LaunchAgents/com.cmux-claude-queue.hotkeyd.plist
rm -f ~/.local/bin/cmux-claude-queue ~/.local/bin/cmux-claude-queue-hotkeyd \
      ~/.local/bin/qq
rm -rf ~/.claude/prompt-queue ~/.config/cmux-claude-queue
npm uninstall -g cmux-claude-queue   # if installed from npm
```

Then, by hand: remove `notifications.hooks` from `cmux.json`, restore `statusLine` in
`settings.json`, and — if you turned it on only for this — put `automation.socketControlMode`
back to `cmuxOnly` and delete `automation.socketPassword`.

## Internals

[docs/internals.md](docs/internals.md) covers the architecture, what delivery does and does not
guarantee, the performance numbers, and two optional extras: `Ctrl+G` capture and `!qq`.

[NOTES.md](NOTES.md) is the field notes: the cmux and Claude Code behaviours that cost time to
find out, kept because they outlive this implementation.

MIT
