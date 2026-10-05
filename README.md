# agent-plugins

Small, sharp plugins for working with coding agents. Each one fixes a single, everyday annoyance, and I use all of them in my own sessions every day.

## Install (30-second setup)

<details open>
<summary><strong>Claude Code</strong></summary>

Add the marketplace once, then install what you want:

```
/plugin marketplace add scarrillo/agent-plugins
/plugin install where-were-we@scarrillo
/plugin install pr-review-cycle@scarrillo
/plugin install release@scarrillo
```

Update a plugin later with `claude plugin update <plugin>@scarrillo`.

</details>

<details>
<summary><strong>Codex, Cursor and other agents</strong></summary>

`pr-review-cycle` is a plain [agentskills.io](https://agentskills.io) skill, so any agent that supports skills can install it:

```bash
npx skills add scarrillo/agent-plugins --skill pr-review-cycle
```

This copies the skill into your agent's skills folder as ordinary files you can edit. Update it with `npx skills update`.

</details>

Pick one route per plugin. Installing `pr-review-cycle` both ways gives Claude Code the skill twice.

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
- Watches the PR in the background and pings you when new review activity lands (live in Claude Code), then loops back through the cycle.

Ask for it in plain words ("review PR #12", "respond to the review comments") or call it by name.

### Releases are tedious?

**The problem:** bumping versions, tagging, writing changelogs and release notes is the same chore every time, and it's easy to get wrong.

**The fix:** [`release`](https://github.com/scarrillo/release), a Claude Code plugin.

- `/release:release` bumps the version (SemVer), commits and tags in one step.
- `/release:changelog` writes changelogs in a problem/solution format from your session's work, not from vague commit messages.
- `/release:decisions` records the why behind choices, and `/release:whattotest` drafts TestFlight notes from the changelog.

## Reference

| Plugin | Kind | Call it with | Works in | Source |
| --- | --- | --- | --- | --- |
| [where-were-we](where-were-we/) | Claude Code mod | `/where-were-we`, footer `↑ ↓` | Claude Code | this repo |
| [pr-review-cycle](pr-review-cycle/) | Skill | asks about a PR, or `/pr-review-cycle:pr-review-cycle`<br>(`/pr-review-cycle` via skills.sh, `$pr-review-cycle` in Codex) | Claude Code, Codex, any skills agent | this repo |
| [release](https://github.com/scarrillo/release) | Claude Code plugin | `/release:release`, `/release:changelog`, … | Claude Code | [scarrillo/release](https://github.com/scarrillo/release) |

## License

[MIT](LICENSE)
