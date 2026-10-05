# where-were-we

A [Claude Code](https://claude.com/claude-code) mod that timestamps your prompts in the transcript, lets you jump back through them, and recaps where your last session in a project left off.

## Install

```
/plugin marketplace add scarrillo/agent-plugins
/plugin install where-were-we@scarrillo
```

## Requirements

- Claude Code 2.1.288 or later. Mods use Claude Code's function-hooks API, which is early access and can change between releases.
- Jumping to a prompt (footer arrows, clicking a list line) needs the fullscreen layout.

## Features

- **Prompt rows** show when you sent them: `12:21:00 ❯ my prompt` for today, `2026-10-02 18:04:11 ❯ …` for older prompts. Wrapped lines stay aligned under the prompt text.
- **Footer**: `↑ ↓` at the end of the hint line under the prompt. ↑ and ↓ step through your prompts; while navigating it shows your position (`↑ ↓ 2/7`). Sending a prompt resets it.
- **`/where-were-we`** lists your 6 most recent prompts, newest at the bottom; click a line to jump to that prompt.
- **`/where-were-we count [n]`** shows or sets how many prompts the list shows (1–50).
- **`/where-were-we order [chron|reverse]`** shows or sets the list order: `chron` puts the newest last (the default), `reverse` puts it first.
- **`/where-were-we up | down | newest`** steps like the arrows, from the keyboard (works mid-turn).
- **`/where-were-we last`** recaps how the previous session in this project ended: its final prompts (same count and order) and the `claude --resume <id>` command to pick it up. It reads Claude Code's prompt history (`~/.claude/history.jsonl`), skipping slash and `!` commands, and never reads pasted content.
- **Startup greeting**: when you start a fresh session in a project, a toast says how the last one ended: `Last here yesterday 18:04: "run the tests" · /where-were-we last`. Not on `--resume`/`--continue`, `/clear` or compaction, and not in `claude -p`.
- **`/where-were-we greeting [on|off]`** shows or sets whether the startup greeting appears (on by default).
- **`/where-were-we status`** prints the mod's state and recent log lines for troubleshooting.

The count, order and greeting setting are kept in the mod's own store (a JSON file of its own under `~/.claude/`), not in `settings.json`, and last across sessions.

Prompts sent while the mod is loaded are stamped as they're stored. Prompts from before (a `--resume`, or the mod enabled mid-session) and prompts queued mid-turn are read from the session's transcript file.

## What it reads and runs

A mod runs with your permissions, so here is everything this one touches:

- **This session's transcript** (`~/.claude/projects/<project>/<session>.jsonl`), filtered with `grep` to the lines that can be your prompts, to recover their times.
- **Claude Code's prompt history** (`~/.claude/history.jsonl`), filtered with `grep` to this project's lines, for `/where-were-we last` and the startup greeting. Only the prompt text (`display`) is read, never pasted content.
- **Its own store**, a JSON file under `~/.claude/`, for the count, order and greeting settings.

It writes nothing else, sends nothing over the network, and never changes your files or `settings.json`. Run `claude plugin validate <path>` on the mod to see every hook it registers and every API it calls.

## Limitations

- Jumping scrolls the transcript only in the fullscreen layout. On the main screen the history is the terminal's own scrollback, which a mod can't move.
- A row drawn as time-only today keeps that form past midnight until it redraws.
- The prompt list matches listing lines to prompts by second and text, since a command's output row carries no ids. A line that can't be matched draws dim and isn't clickable.
