# pr-review-cycle

A cross-agent skill built to the [agentskills.io](https://agentskills.io)
spec: drive the full GitHub PR review → resolve → watch loop. It
preflights context, summarizes changes, surfaces review conversations,
prioritizes open feedback, commits and replies to resolve threads, then
watches for new reviewer activity and offers to run the cycle again.

## Install

Install with [skills.sh](https://skills.sh), the same way in every agent
(Claude Code, Codex, Cursor and others):

```bash
npx skills add scarrillo/agent-plugins --skill pr-review-cycle -g
```

Choose the agents to install it for when prompted. `-g` installs it for
your user (in a shared folder such as `~/.agents/skills/`, linked into
each agent); without it, the install is project-local (e.g.
`.agents/skills/`, `.claude/skills/`). See the [skills CLI
docs](https://github.com/vercel-labs/skills#readme) for agent
targeting and source formats.

## Invoking it

It triggers on its own when you ask about a PR ("review PR #12",
"respond to the review comments"). To call it by name:

| Agent | Call it with |
| --- | --- |
| Claude Code | `/pr-review-cycle` |
| Codex | `$pr-review-cycle` in your prompt |

## Prerequisites

The `pr-review-cycle` skill shells out to:

- [`gh`](https://cli.github.com/) — authenticated to the repo whose
  PRs you'll review.
- [`jq`](https://jqlang.github.io/jq/) — JSON parsing.
- `bash` 4 or newer in a POSIX-ish environment.

The bundled `pr-watch.sh` fails fast (exit code 2) with a clear
message if `gh` or `jq` is missing.

**Platform support:** macOS and Linux are the tested baseline.
Windows works under WSL2 or Git Bash; a PowerShell-native port of
`pr-watch.sh` is not provided.

## Compatibility

`pr-review-cycle` uses only the portable subset of the skills spec
(`name`, `description`, `allowed-tools`). It should work on any
agent listed in the [skills.sh compatibility
table](https://github.com/vercel-labs/skills#compatibility) that
supports basic skills.

Step 5 (the background PR watch) needs the host agent to run a
backgrounded bash process **and surface each stdout line to the
agent as a real-time notification** (not just write it to a log
file the agent reads later — that defeats the "ping me on new
activity" UX the script is designed for). Per-agent streaming
primitives:

| Host agent | Streaming primitive |
| --- | --- |
| Claude Code | `Monitor` tool (`persistent: true`, `timeout_ms: 3600000`) |
| Codex | None per-emit — use the capture-only fallback below |
| Cursor / Windsurf / OpenCode / others | TBD — verify per agent |

Hosts that lack a real-time-stdout primitive can fall back to
`nohup … > /tmp/pr-watch-….log 2>&1 &` plus log tailing on
demand. That preserves the operations contract but degrades the
UX to passive recording — the agent has to explicitly check the
log when the user asks "anything new?" The same downgrade
applies to mechanisms that notify on task completion rather than
per-emit (e.g. Claude Code's `Bash` with `run_in_background:
true`). See SKILL.md's "Arming the watch" section for the full
operations contract.

## Design notes

- **Three comment streams.** PRs expose reviews, inline comments,
  and issue comments on separate endpoints, and reviewers (human or
  bot) may land in any of them. The watcher sums all three.
- **Detector, not fetcher.** The watcher only counts events and
  reports *that* something changed (a delta count plus who acted) —
  it never pulls diffs or comment bodies. On a change it pings the
  agent, which asks the user and only then re-runs Step 1 to fetch
  and analyze the actual content. This is why the poll can stay a
  cheap 120s count loop instead of re-pulling the PR every cycle.
- **120s poll, selective emit.** Bots file 1–5 min after a push; the
  watcher polls every 120s and emits only when the cumulative count
  changes, so silence is meaningful.
- **Notify-only.** Each emit surfaces activity and asks; the skill
  never auto-acts, since replies/commits/pushes need per-occurrence
  approval.

## Customizing `pr-review-cycle`

Review priorities are layered, so each project keeps its own
guardrails without forking the skill:

1. **Built-in defaults** (always loaded) —
   `rules/default-review-rules.md`. Ships
   with the skill: Security, Performance, Error handling,
   Accessibility & platform conventions, Behavioral regressions.
2. **Project override** (optional) —
   `<your-project>/review-cycle-rules.md` at the target repo's
   root (resolved via `git rev-parse --show-toplevel` from the
   worktree being reviewed). Lives in the project being reviewed,
   not in this skills directory. Frontmatter `mode` controls how
   it combines with the defaults:
   - `mode: append` (default if frontmatter is absent or `mode` is
     unset) — your rules apply **after** the defaults; both sets
     are active.
   - `mode: replace` — the defaults are ignored entirely; only
     your override is active.

The example below is illustrative — substitute your team's real
priorities (a database team's list looks nothing like a frontend
team's):

```yaml
---
mode: append    # default; can be omitted
---

## Pay particular attention to

# Examples — substitute your team's real review priorities here.
5. **Multi-tenant isolation** — flag any query touching shared
   tables without an explicit tenant filter.
6. **Migration safety** — for changes touching tables >1M rows,
   require a backfill plan and locking analysis.
```

Whether to commit `review-cycle-rules.md` is a team decision: commit
when the rule set reflects shared engineering standards; gitignore
when it's a personal customization for one reviewer.

A copy-and-edit reference lives at
[`rules/example-review-cycle-rules.md`](rules/example-review-cycle-rules.md).

## Layout

```
pr-review-cycle/
├── SKILL.md
├── README.md
├── rules/
│   ├── default-review-rules.md
│   └── example-review-cycle-rules.md
└── scripts/
    └── pr-watch.sh
```

The skill is a self-contained directory; the bundled script and
rule files live alongside `SKILL.md` and are referenced relative
to it, so they travel with every install. In the Claude Code
marketplace it's packaged as a plugin by its entry in
[`../.claude-plugin/marketplace.json`](../.claude-plugin/marketplace.json);
the folder itself has nothing Claude-specific.
