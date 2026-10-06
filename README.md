# agent-plugins

Small, sharp plugins for working with coding agents. Each one fixes a single, everyday annoyance.

`pr-review-cycle` works in any agent that supports skills; `where-were-we` and `release` are Claude Code plugins.

## Install (30-second setup)

### Plugins (Claude Code)

Add the marketplace once, then install the plugins:

```
/plugin marketplace add scarrillo/agent-plugins
/plugin install where-were-we@scarrillo
/plugin install release@scarrillo
```

Update a plugin later with `claude plugin update <plugin>@scarrillo`.

### Skills (Claude Code, Codex, Cursor and other agents)

Skills install with [skills.sh](https://skills.sh), the same way in every agent, Claude Code included:

```bash
npx skills add scarrillo/agent-plugins --skill pr-review-cycle -g
```

Choose the agents to install it for when prompted. This installs the skill as ordinary files you can edit, in a shared skills folder (such as `~/.agents/skills/`) that each agent links to; add `--copy` for an independent copy per agent. Leave out `-g` to install into the current project instead of for your user. Update it with `npx skills update`.

## What's here

### Lost your place in a long session?

**The problem:** a few hours into a session, the scrollback is a wall of output. You can't tell when you asked what, finding an earlier prompt means scrolling and squinting, and coming back the next day you've forgotten where you left off.

**The fix:** [`where-were-we`](where-were-we/), a Claude Code mod.

- Every prompt in the transcript gets a timestamp: `12:21:00 ❯ my prompt`.
- `↑ ↓` in the footer jump between your prompts, and `/where-were-we` lists the recent ones; click one to jump to it (in the fullscreen layout).
- Start a new session and a toast tells you how the last one ended: `Last here yesterday 18:04: "run the tests"`. `/where-were-we last` shows more, with the command to resume it.

### Review feedback landing while you're away?

**The problem:** you open a PR, reviewers and bots comment across three different GitHub streams, and you keep switching tabs to see whether anything new arrived, then stitch it together into what actually needs doing.

**The fix:** [`pr-review-cycle`](pr-review-cycle/), a cross-agent skill.

- Summarizes the PR and every open conversation, then prioritizes the feedback.
- Resolves threads with you: commits, pushes and replies, each only after you approve.
- Watches the PR in the background and pings you when new review activity lands (live in Claude Code), then offers to run the cycle again.

Ask for it in plain words ("review PR #12", "respond to the review comments") or call it by name.

### Shipping an iOS/macOS build is the same chore every time?

**The problem:** bump the version in your Xcode project, tag it, write the changelog and TestFlight notes, then build: a handful of manual steps, any of which is easy to get wrong.

**The fix:** [`release`](https://github.com/scarrillo/release), Xcode release automation for Claude Code.

- `/release:release` bumps the version (SemVer), commits and tags in one step.
- `/release:changelog` writes changelogs in a problem/solution format from your session's work, not from vague commit messages.
- `/release:whattotest` drafts TestFlight notes from the changelog, and `/release:xcbuild` builds the app.
- `/release:decisions` records the why behind choices.

It also releases Claude Code plugins, which is how it ships itself.

## Reference

| Plugin | Kind | Call it with | Works in | Source |
| --- | --- | --- | --- | --- |
| [where-were-we](where-were-we/) | Claude Code mod | `/where-were-we`, footer `↑ ↓` | Claude Code | this repo |
| [pr-review-cycle](pr-review-cycle/) | Skill | asks about a PR, or `/pr-review-cycle` (Claude Code), `$pr-review-cycle` (Codex) | Claude Code, Codex, any skills agent | this repo |
| [release](https://github.com/scarrillo/release) | Claude Code plugin (Xcode release automation) | `/release:release`, `/release:changelog`, … | Claude Code | [scarrillo/release](https://github.com/scarrillo/release) |

## License

[MIT](LICENSE)
