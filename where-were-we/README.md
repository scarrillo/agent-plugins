# where-were-we

A Claude Code mod that timestamps your prompts and keeps a history of them.

## Install

```
/plugin marketplace add scarrillo/agent-plugins
/plugin install where-were-we@scarrillo
```

Requires Claude Code 2.1.288 or later. Mods use Claude Code's function-hooks API, which is early access.

## What it does

- **Timestamps every prompt** in the transcript: `12:21:00 ❯ my prompt` for today, `2026-10-02 18:04:11 ❯ …` for older prompts, including prompts from resumed sessions.
- **Lists your recent prompts** with their dates and times: `/where-were-we`.
- **Recaps the previous session** in the project, with the command to resume it: `/where-were-we last`.

## Commands

| Command | Does |
| --- | --- |
| `/where-were-we` | List recent prompts |
| `/where-were-we last` | Show the previous session's last prompts and its resume command |
| `/where-were-we count [n]` | Show or set how many prompts are listed (default 6) |
| `/where-were-we order [chron\|reverse]` | Show or set the list order (default `chron`, newest last) |
| `/where-were-we greeting [on\|off]` | Show or set the startup recap toast (default on) |
| `/where-were-we up\|down\|newest` | Jump between prompts (fullscreen layout); also `↑ ↓` in the footer |
| `/where-were-we status` | Print state and recent log lines |

## Data access

- Reads this session's transcript, to recover prompt times.
- Reads this project's entries in `~/.claude/history.jsonl`, prompt text only, never pasted content.
- Keeps its settings in its own store under `~/.claude/`.

No network access, and no changes to your files or `settings.json`.
