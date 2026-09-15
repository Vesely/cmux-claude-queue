<h1 align="center">cmux-claude-queue</h1>

<h4 align="center">
  Press <code>Option+Enter</code> instead of <code>Enter</code>.<br>
  Your draft leaves the input box, waits on disk, and goes in as a new turn once the current one has ended.
</h4>

<p align="center">
  <a href="https://www.npmjs.com/package/cmux-claude-queue"><img src="https://img.shields.io/npm/v/cmux-claude-queue" alt="npm version"></a>
  <img src="https://img.shields.io/badge/platform-macOS-lightgrey" alt="macOS only">
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

Requested in
[#50246](https://github.com/anthropics/claude-code/issues/50246) (205 👍),
[#33323](https://github.com/anthropics/claude-code/issues/33323),
[#30677](https://github.com/anthropics/claude-code/issues/30677) and
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
first. It keeps running, and the queue row is appended below its output.

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
install is symlinked, so `npm update -g` takes effect without re-running setup.

</details>

## Limitations

- One Claude session per cmux workspace: capture targets that workspace's active Claude surface.
- Newlines in a draft become spaces. Queued prompts are stored one per line.
- A cmux restart regenerates surface ids. Anything still queued stays under the old id in
  `~/.claude/prompt-queue/` and is not delivered.
- Delivery gives up after three unconfirmed attempts and notifies you, rather than resending
  forever. The text is left in the input box, so nothing is lost, but you press `Enter` yourself.
- cmux only. Ghostty has no capture backend.

## Uninstall

```sh
launchctl bootout gui/$(id -u)/com.cmux-claude-queue.hotkeyd
rm ~/Library/LaunchAgents/com.cmux-claude-queue.hotkeyd.plist
rm -f ~/.local/bin/cmux-claude-queue ~/.local/bin/cmux-claude-queue-hotkeyd \
      ~/.local/bin/cmux-claude-queue-editor
rm -rf ~/.claude/prompt-queue ~/.config/cmux-claude-queue
npm uninstall -g cmux-claude-queue   # if installed from npm
```

Then remove the `notifications.hooks` entry from `cmux.json` and restore your previous
`statusLine` in Claude Code's `settings.json`.

## Internals

[docs/internals.md](docs/internals.md) covers the architecture, what delivery does and does not
guarantee, the performance numbers, and two optional extras: `Ctrl+G` capture and `!qq`.

MIT
