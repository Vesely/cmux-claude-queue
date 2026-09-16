<h1 align="center">cmux-claude-queue</h1>

<h4 align="center">
  Press <code>Option+Enter</code> instead of <code>Enter</code>.<br>
  A real queue: your prompt waits outside the session and goes in as the <em>next</em> turn, never into the one already running.
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
queue and delivery targets that same surface — but the capture picks the *active* Claude surface
in the current workspace, so keep one Claude session per workspace.

Both shortcuts are registered only while cmux is frontmost, so they behave normally everywhere
else. From a shell, `cmux-claude-queue list` shows everything queued and
`cmux-claude-queue clear <surface>` drops one (the id is what `list` prints);
`cmux-claude-queue help` lists the rest.

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

Needs macOS, [cmux](https://github.com/manaflow-ai/cmux) ≥ 0.64.20, Claude Code, and the Xcode
Command Line Tools (`xcode-select --install`).

**1. Install**

```sh
npm i -g cmux-claude-queue
```

**2. Build the daemon**

```sh
cmux-claude-queue setup
```

It compiles the hotkey daemon, loads its LaunchAgent, and prints two config snippets with your
paths already filled in.

**3. Paste the two snippets**

One belongs in `~/.config/cmux/cmux.json`, the other in `~/.claude/settings.json`. Then:

```sh
cmux reload-config
```

Setup prints those snippets and nothing more — editing your config files is left to you.

Already using a statusline command? Save it as a shell script at
`~/.config/cmux-claude-queue/statusline-chain` before step 3 — it is run with `/bin/sh` and gets
the statusline JSON on stdin. It keeps running, cached for 180 s, with the queue row appended
below its output.

> **Password mode.** The cmux snippet turns on socket password control (setup generates the
> password and prints it in the snippet), so any process that can read your `cmux.json` can drive
> your cmux terminals — check it is `chmod 600`. This is a wider
> gate than cmux's default `cmuxOnly`, which rejects the hotkey daemon for not being a cmux child
> process.

<details>
<summary>Or let your agent do it</summary>

Paste this into Claude Code:

> Install cmux-claude-queue: run `npm i -g cmux-claude-queue && cmux-claude-queue setup`, apply
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

A clone is copied into `~/.local/bin` — put that on your `PATH` for the shell subcommands; the
hotkey and the LaunchAgent use absolute paths either way. Re-run `./install.sh` after a `git pull`. An npm
install is symlinked, so `npm update -g` updates the script — but not the compiled daemon.
Re-run `cmux-claude-queue setup` for that.

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

First unwire it: remove `notifications.hooks` from `cmux.json`, restore your `statusLine` in
`settings.json`, and — if you turned it on only for this — put `automation.socketControlMode` back
to `cmuxOnly` and delete `automation.socketPassword`. Then:

```sh
launchctl bootout gui/$(id -u)/com.cmux-claude-queue.hotkeyd
rm -f ~/Library/LaunchAgents/com.cmux-claude-queue.hotkeyd.plist
rm -f ~/.local/bin/cmux-claude-queue ~/.local/bin/cmux-claude-queue-hotkeyd \
      ~/.local/bin/qq
rm -rf ~/.claude/prompt-queue ~/.config/cmux-claude-queue
npm uninstall -g cmux-claude-queue   # if installed from npm
```

Doing it in that order matters: between deleting the binaries and unwiring the config, every
cmux notification and every statusline refresh would run a file that is no longer there.

## Internals

[docs/internals.md](docs/internals.md) covers the architecture, what delivery does and does not
guarantee, the performance numbers, and two optional extras: `!qq` and a Command Palette action.

[NOTES.md](NOTES.md) is the field notes: the cmux and Claude Code behaviours that cost time to
find out, kept because they outlive this implementation.

MIT
