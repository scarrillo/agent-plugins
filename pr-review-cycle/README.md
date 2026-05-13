# agent-skills

Cross-agent skills built to the [agentskills.io](https://agentskills.io)
spec, distributed via [skills.sh](https://skills.sh).

## Skills

| Skill | What it does |
| --- | --- |
| [`pr-review-cycle`](skills/pr-review-cycle/SKILL.md) | Drive the full GitHub PR review → resolve → watch loop: preflight context, summarize changes, surface review conversations, prioritize open feedback, commit and reply to resolve threads, then watch for new reviewer activity and re-enter the cycle. |

## Install

Install the whole pack into your active agent(s):

```bash
npx skills add scarrillo/agent-skills
```

Or install a single skill:

```bash
npx skills add scarrillo/agent-skills --skill pr-review-cycle
```

`-g` installs globally (user-level, e.g. `~/.claude/skills/`,
`~/.cursor/skills/`); without it, install is project-local
(e.g. `.claude/skills/`, `.agents/skills/`). See the [skills CLI
docs](https://github.com/vercel-labs/skills#readme) for agent
targeting and source formats.

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
| Codex | TBD — verify with a test PR |
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

## Customizing `pr-review-cycle`

The skill's review priorities (Security, Performance, Error handling,
Accessibility & platform conventions) live in
`skills/pr-review-cycle/rules/default-review-rules.md`, not inlined
in `SKILL.md`. Projects can extend or replace those defaults by
adding a single file at their own repo root:

```
<your-project>/review-cycle-rules.md
```

Optional YAML frontmatter controls how the override merges. The
example below is illustrative — the two priorities shown are
just examples of the kind of rules a team might add; replace them
with whatever your project actually cares about (a database team
might write something completely different than a frontend team):

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

- `mode: append` (the default if the field is absent) — your rules
  apply **after** the defaults; both sets are active.
- `mode: replace` — the defaults are ignored entirely; only your
  override is active.

Whether to commit `review-cycle-rules.md` is a team decision: commit
when the rule set reflects shared engineering standards; gitignore
when it's a personal customization for one reviewer.

A copy-and-edit reference lives at
[`skills/pr-review-cycle/rules/example-review-cycle-rules.md`](skills/pr-review-cycle/rules/example-review-cycle-rules.md).

## Layout

```
skills/
└── pr-review-cycle/
    ├── SKILL.md
    ├── rules/
    │   ├── default-review-rules.md
    │   └── example-review-cycle-rules.md
    └── scripts/
        └── pr-watch.sh
```

Each skill is a self-contained directory; bundled scripts and
rule files live alongside `SKILL.md` and are referenced relative
to it.
