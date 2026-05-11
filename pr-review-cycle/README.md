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
- `bash` 4 or newer.

The bundled `pr-watch.sh` fails fast (exit code 2) with a clear
message if `gh` or `jq` is missing.

## Compatibility

`pr-review-cycle` uses only the portable subset of the skills spec
(`name`, `description`, `allowed-tools`). It should work on any
agent listed in the [skills.sh compatibility
table](https://github.com/vercel-labs/skills#compatibility) that
supports basic skills. Step 5 (background PR watch) needs the host
agent to run a backgrounded bash process and surface its stdout;
most agents do, but the UX of "you get pinged on new PR activity"
quality varies.

## Layout

```
skills/
└── pr-review-cycle/
    ├── SKILL.md
    └── scripts/
        └── pr-watch.sh
```

Each skill is a self-contained directory; bundled scripts live
alongside `SKILL.md` and are referenced relative to it.
