# review-council

A cross-agent skill built to the [agentskills.io](https://agentskills.io) spec. Delegate code reviews to all of your locally installed Agents. Your active agent acts as the council lead and delegates to each available Agent, which has a fresh context and can be tasked to review your uncommitted changes, unpushed commits vs. remote branch, whole branch vs. main, or an open PR; the lead verifies each finding against the code and proposes next steps.

## How to use

```
/review-council
/review-council unpushed
/review-council branch just codex, antigravity   focus on error handling
/review-council pr 59 --background
/review-council settings
```

### Full Options 
```
/review-council [uncommitted|unpushed|branch|pr <N>|settings] [--base <ref>] [--wait|--background] [just <members>] [focus text]
```
Full settings defined at the bottom of this document. 

## Code Review Results

The report lists each member's findings under its own heading, with the lead's verification and recommendations

```
## codex — NEEDS ATTENTION · model gpt-6-astra
- [P1] Empty optional arrays break on macOS bash 3.2 — review-fanout.sh:79
  Confirmed → Fix: expand as ${arr[@]+"${arr[@]}"}.
- [P2] Inline diff passed as one argv string — review-fanout.sh:117
  Confirmed → Won't fix — accepted risk: only affects CLIs not installed here.

## copilot — APPROVE · model gpt-6-luna (Fusion/balance picked gpt-6-luna)
- No material findings; riskiest untested line: review-fanout.sh:195.

## Fix list
1. [P1] review-fanout.sh:79 — bash-3.2-safe array expansion
Won't fix: 1 (accepted risk). Your call: 0.
```

### How it works
- Each agent works from a separate process with no context from your current session, so you get genuinely independent reads rather than one model agreeing with itself.
- **Verified, not merged.** The council lead checks each finding against the code before recommending anything, and marks it Confirmed, Disproved, or Not checked. Checked findings get a verified recommendation: Fix with the change, or Won't fix with the reason. Not checked findings get no recommendation. It reports per member and records the model each member actually ran on. Agreement between members is shown, never silently collapsed.
- **Review only.** Council members run read-only; the lead never edits, commits, switches branches, or posts to GitHub. Fixes are a separate ask. 
- You choose the code review target: uncommitted, unpushed, branch, or PR. See Code Review Targets below.
- **Everything stays local.** Packets, prompts, replies, and status live under `~/.council/`, one folder per run, so any later session can read them back.

### Supported Agents - Council Members
**Codex, Claude Code, Copilot CLI, Antigravity CLI (Gemini)**.
Detected at run time. The council lead is the model you run the skill with.

| Member        | CLI       | Default model                                                                        | Kept read-only by                                                                          |
| ------------- | --------- | ------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------ |
| `codex`       | `codex`   | The current CLI default or use `CODEX_MODEL` to pin a different model                | the built-in `codex review` on a clean tree, else a read-only `codex exec` over the packet |
| `claude`      | `claude`  | The current CLI default or use `CLAUDE_MODEL` to pin a different model               | `--restricted`, file tools only, no MCP                                                    |
| `copilot`     | `copilot` | Uses Copilot Fusion router at the `balance` tier. Fusion chooses which model to use. | file tools only; GitHub MCP tools removed, nothing reaches github.com                      |
| `antigravity` | `agy`     | first available of Gemini 4 Neon, Gemini 4 Carbon, Gemini 3.8 Flash, at `high` effort | session deny rules for commands, writes, URLs, and MCP (run in plan mode, which only changes the prompt) |

**Copilot Fusion** is GitHub's per-task model router, not a model: it picks
from the models your plan allows, which can include Claude. The council
runs it at `balance`; `intelligence` is the High/Max profile and costs more. Every run records the pick. For a guaranteed non-Anthropic voice, pin one with `COPILOT_MODEL=gpt-5.6-sol`; effort is a per-model setting, so `COPILOT_EFFORT` applies only to a pinned model.

### Code Review Targets

| target        | base                  | use it                                              |
| ------------- | --------------------- | --------------------------------------------------- |
| `uncommitted` | `HEAD`                | Before committing - staged, unstaged, untracked     |
| `unpushed`    | the branch's upstream | Before pushing - commits only                       |
| `branch`      | `origin/main`         | Before opening a PR - Everything the branch changes |
| `pr <N>`      | the PR's base branch  | Review an open PR                                   |


### Report History
Every run leaves its packet, prompts, replies, logs, and a `status.md` under `~/.council/<timestamp>-review-<slug>/`, so a later session can read them back. `status.md` has one line per member with the outcome, duration, and the model the CLI itself reported:

```
copilot      ok  25s   gpt-6.1-sol (Fusion/balance picked gpt-6.1-sol)
claude       ok  77s   claude-fable-5-1
codex        ok  304s  gpt-6-astra
antigravity  ok  340s  gemini-4-neon/high (first available of AGY_MODEL_ORDER)
```

## Install and update

Install with [skills.sh](https://skills.sh), the same way in every agent (Claude Code, Codex, Copilot CLI and others). Choose the agents to install it for when prompted.

```bash
# Global
npx skills add scarrillo/agent-plugins --skill review-council -g

# Single repo, project scope
npx skills add scarrillo/agent-plugins --skill review-council

# Updating
npx skills update review-council -g     # global scope
npx skills update review-council        # project scope, run in the repo

# list skill or remove review-council
npx skills list
npx skills remove review-council
```

In Claude Code you can also install it as a plugin from this repo's marketplace; it is then called `/review-council:review-council`:

```
/plugin marketplace add scarrillo/agent-plugins
/plugin install review-council@scarrillo
```

## Settings

Defaults live in `~/.council/review-council.env`, with an optional per-repo `.council/review-council.env`. Precedence, highest first: environment variable for the run, repo file, home file, built-in default. Say `/review-council settings` to see or change them; a phrase inside a review request ("copilot at intelligence this time") overrides for that run only.

| Key                 | Default            | Meaning                                                                                  |
| ------------------- | ------------------ | ---------------------------------------------------------------------------------------- |
| `MEMBERS`           | all detected       | default member list, e.g. `codex, copilot`                                               |
| `RUN_MODE`          | `ask`              | `wait` or `background` skips the question; `--wait` / `--background` on a run always win |
| `REVIEW_TIMEOUT`    | `900`              | seconds per member                                                                       |
| `CLAUDE_MODEL`      | CLI default        | `claude -p --model`                                                                      |
| `CODEX_MODEL`       | CLI default        | codex model for native and packet runs                                                   |
| `COPILOT_MODEL`     | `fusion`           | router, a pinned id such as `gpt-5.6-sol`, or empty for Copilot's own default            |
| `COPILOT_AUTO_TIER` | `balance`          | Fusion profile; `intelligence` is the higher tier                                        |
| `COPILOT_EFFORT`    | `medium`           | `--reasoning-effort`, sent only for a pinned Copilot model                               |
| `AGY_MODEL`         | `auto`             | `auto` picks from `AGY_MODEL_ORDER`; a family such as `gemini-4-carbon` pins it; empty = agy's configured default |
| `AGY_MODEL_ORDER`   | `gemini-4-neon, gemini-4-carbon, gemini-3.8-flash` | Families `auto` tries, in order |
| `AGY_EFFORT`        | `high`             | Antigravity `--effort`: low, medium, high, xhigh, max. Carbon stops at `high`; Neon at `xhigh` |

With `AGY_MODEL=auto`, the council asks `agy models` which models your Antigravity account offers and uses the first family in `AGY_MODEL_ORDER` available at `AGY_EFFORT`, so accounts without Neon fall back to Carbon, then Flash. If none is available, the antigravity member is skipped and the log lists what agy offers.
