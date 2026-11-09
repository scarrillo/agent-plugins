# agent-plugins

Plugins and skills for coding agents.

- [where-were-we](#where-were-we): Claude Code mod
- [pr-review-cycle](#pr-review-cycle): skill for any agent
- [review-council](#review-council): skill for any agent
- [release](#release): Claude Code plugin

## where-were-we

A Claude Code mod that timestamps your prompts and helps you find your way back through your prompt history.

```
/plugin marketplace add scarrillo/agent-plugins
/plugin install where-were-we@scarrillo
```

- Timestamps every prompt in the transcript: `12:21:00 ❯ my prompt`.
- `/where-were-we` lists your recent prompts; `/where-were-we last` recaps the previous session in the project.

[Docs](where-were-we/)

## pr-review-cycle

A skill that reviews a GitHub PR, resolves feedback with your approval, and watches for new review activity. Works in Claude Code, Codex and any agent that supports skills.

```bash
npx skills add scarrillo/agent-plugins --skill pr-review-cycle -g
```

- Summarizes the PR and prioritizes open feedback.
- Commits, pushes and replies to resolve threads, each after you approve.
- Watches for new review activity (live in Claude Code; logged in other agents) and offers to run the cycle again.

Ask about a PR, or call it with `/pr-review-cycle` (Claude Code) or `$pr-review-cycle` (Codex). [Docs](pr-review-cycle/)

## review-council

A skill that sends your changes to every coding agent CLI installed on your machine (Codex, Claude Code, Copilot CLI, Antigravity) for an independent, fresh-context review, then verifies each finding against the code.

```bash
npx skills add scarrillo/agent-plugins --skill review-council -g
```

- Reviews uncommitted changes, unpushed commits, the whole branch vs. main, or an open PR.
- Each member runs read-only in its own process, with no memory of your session.
- The lead marks every finding Confirmed or Disproved and proposes Fix or Won't fix. It never edits, commits or posts to GitHub.

Call it with `/review-council` (Claude Code) or `$review-council` (Codex). [Docs](review-council/)

## release

A Claude Code plugin for Xcode release automation.

```
/plugin marketplace add scarrillo/agent-plugins
/plugin install release@scarrillo
```

- `/release:release` bumps the version (SemVer), commits and tags.
- `/release:changelog` writes a changelog from your session's work.
- `/release:whattotest` drafts TestFlight notes from the changelog.
- `/release:xcbuild` builds an iOS app for the Simulator.
- `/release:decisions` records the reasoning behind decisions.

[Repo](https://github.com/scarrillo/release)

## License

[MIT](LICENSE)
