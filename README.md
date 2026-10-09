# agent-plugins

Plugins and skills for coding agents.

- [where-were-we](#where-were-we): Claude Code mod
- [pr-review-cycle](#pr-review-cycle): skill for any agent
- [release](#release): Claude Code plugin

## where-were-we

A Claude Code mod that timestamps your prompts and keeps a history of them.

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
- Watches for new review activity and offers to run the cycle again.

Ask about a PR, or call it with `/pr-review-cycle` (Claude Code) or `$pr-review-cycle` (Codex). [Docs](pr-review-cycle/)

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
