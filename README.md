# cmux-claude-queue

Press `Option+Enter` instead of `Enter`. Your draft leaves the input box, waits on disk, and
goes in as a new turn once the current one has ended.

![Option+Enter queues "now update the README" while Claude is still working; the statusline holds it, and it is submitted as a new turn once the first one finishes](docs/demo.gif)

macOS · [Claude Code](https://claude.com/claude-code) · [cmux](https://cmux.io) · MIT

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

## Requirements

macOS · [cmux](https://github.com/manaflow-ai/cmux) ≥ 0.64.20 · Claude Code ·
Xcode Command Line Tools, for `swiftc` · `python3` on `$PATH` · Node ≥ 18 to install from npm

## Install

```sh
npm i -g cmux-claude-queue
cmux-claude-queue-setup
```

`setup` builds the hotkey daemon, loads its LaunchAgent, and prints two config snippets with
your paths filled in: one for `~/.config/cmux/cmux.json`, one for `~/.claude/settings.json`.
It does not edit either file. Paste both in, then run `cmux reload-config`.

Already have a statusline command? Save it as `~/.config/cmux-claude-queue/statusline-chain`.
It keeps running, and the queue row is appended below its output.

> **Password mode.** The cmux snippet turns on socket password control, so any process that can
> read your `cmux.json` can drive your cmux terminals. Check the file is `chmod 600`. This is a
> wider gate than cmux's default `cmuxOnly` mode, which rejects the hotkey daemon because the
> daemon is not a cmux child process.

### Or let your agent install it

Paste this into Claude Code:

> Install cmux-claude-queue: run `npm i -g cmux-claude-queue && cmux-claude-queue-setup`, apply
> the two snippets it prints to `~/.config/cmux/cmux.json` and `~/.claude/settings.json`, move
> any existing statusLine command to `~/.config/cmux-claude-queue/statusline-chain` first, then
> run `cmux reload-config` and tell me what you changed.

<details>
<summary>From source instead</summary>

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
