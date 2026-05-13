---
name: pr-review-cycle
description: Drive the full GitHub PR review → resolve → watch loop. Summarize a pull request, surface review conversations, prioritize open feedback, optionally commit and reply to resolve threads, then watch the PR for new reviewer activity and re-enter the cycle. Use when the user asks to review, respond to, or monitor a PR by URL or number.
allowed-tools: Bash, Read, Grep, Glob
---

# PR Review Cycle

Drive a GitHub pull request through one full review → resolve →
watch loop. Identify the PR from the user's request (URL or
`#number`); if ambiguous, ask before proceeding. The cycle is:

1. Preflight worktree/branch state
2. Check PR state (open vs. merged/closed)
3. Fetch context (diff, threads, reviews)
4. Summarize and prioritize feedback
5. Resolve threads — commit, push, reply (only when asked)
6. Watch for new activity and re-enter at step 3 when it arrives

## Prerequisites

- `gh` (GitHub CLI) authenticated for the target repo.
- `jq` on `PATH` — the bundled script parses GitHub JSON responses.
- `bash` 4+ in a POSIX-ish environment (lockfile path is `/tmp/...`,
  signals/`kill`/`ps` semantics are assumed Unix).

**Platform support:** macOS and Linux are the tested baseline.
Windows works under WSL2 or Git Bash; a PowerShell-native port of
`pr-watch.sh` is not provided. Flag this to the user if their host
is native Windows so they can choose WSL/Git Bash before the cycle
fails partway through.

The bundled `scripts/pr-watch.sh` exits with code 2 and a clear
message if `gh` or `jq` is missing. If the user hits that, point them
at the install instructions for their platform rather than working
around the failure.

## Resolving the bundled script path

This skill ships a script at `scripts/pr-watch.sh` *relative to this
SKILL.md*. The absolute install path varies by host agent
(`~/.claude/skills/pr-review-cycle/`,
`~/.cursor/skills/pr-review-cycle/`,
`.agents/skills/pr-review-cycle/`, etc.). Before invoking the script,
resolve it to an absolute path — for example via the location of this
file in your file-reading tools — and use that absolute path in every
`bash` invocation below. Do **not** hardcode `~/.claude/` or any
other agent-specific prefix.

## Preflight: Confirm working context

Before doing anything else, run:

```
git status && git branch --show-current && pwd
```

Confirm you're on the right branch and in the right worktree for the
PR you're about to review. The PR's `headRefName` (Step 1) should
match the checked-out branch if the user expects to commit/push
fixes (Step 4). Mismatches are common when juggling worktrees —
pushing fixes from the wrong worktree silently lands them on the
wrong branch.

If anything looks off (wrong branch, wrong repo, dirty working tree,
unexpected path), **stop and ask the user** before continuing.

## Step 0: Check PR state

```
bash <absolute-path-to>/scripts/pr-watch.sh check <owner> <repo> <pr-number>
```

Single deterministic call. Combines the PR state lookup and the
stale-watch cleanup. Always exits 0; branch on the parsed state in
the single-line output:

- `state=OPEN` → continue to Step 1
- `state=MERGED` or `state=CLOSED` → echo the script's line to the
  user and **exit. Do not run any further steps.** Re-fetching
  threads on a settled PR wastes tokens and is misleading. Any stale
  watch on this PR has already been cleaned up by the `check` call.
- `state=UNKNOWN` → the script's `gh` lookup failed transiently.
  Don't gate on it. Fall back to a direct call:
  `gh pr view <pr> --repo <owner>/<repo> --json state`. If that
  confirms `OPEN`, continue normally — and if you reach Step 5,
  arming the watch is still allowed: the `start` subcommand
  tolerates further `UNKNOWN` responses at runtime and only stops
  on a confirmed non-`OPEN` state.

This makes the skill cheap and idempotent for closed PRs — calling
it after merge is a single state-check, not a full re-review, and
any orphan watch gets cleaned up automatically.

## Step 1: Fetch PR Details

Use `gh` CLI to gather context. Substitute the PR identifier the user
gave you for `<pr>`:

```
gh pr view <pr> --json title,body,baseRefName,headRefName,url,number,reviewDecision,state
gh pr diff <pr>
gh api repos/{owner}/{repo}/pulls/{number}/comments
gh api repos/{owner}/{repo}/pulls/{number}/reviews
```

## Step 2: Review Conversations

Review all review comments and conversation threads on the PR. For
each thread:
- Understand what the reviewer is asking or flagging
- Assess whether it has been addressed or is still open
- Skip resolved/closed conversations — focus on what still needs
  attention

## Step 3: Summarize and Prioritize

### Load the active review ruleset

Before drafting your summary, read the rules that govern this step:

1. **Bundled defaults** at `<skill-dir>/rules/default-review-rules.md`
   (alongside this SKILL.md). Always read this.
2. **Project override** (optional) at
   `<repo-root>/review-cycle-rules.md`. The repo root is
   `git rev-parse --show-toplevel` from the worktree you confirmed
   in Preflight. Note this lives in the project being reviewed,
   not in the agent skills directory.
3. If the override exists, honor its frontmatter `mode` field:
   - `mode: append` (the default if the field is absent or unset) —
     the override's rules apply **after** the defaults; both sets are
     active.
   - `mode: replace` — the defaults are ignored entirely; only the
     override is active.

The merged ruleset is what drives the priority analysis below.

### Summarize

Present a summary to the user:
- What the PR does (purpose, scope)
- All review feedback grouped by priority
- Which conversations are resolved vs. still open
- Proposed next steps

Form an objective analysis of the PR feedback — don't assume the
feedback is correct.

Pay particular attention to the categories named in the active
ruleset; skip what the ruleset says to skip. Don't fall back on
priorities or guardrails that aren't in the active ruleset — if a
project removed something via `mode: replace`, that's deliberate.

## Step 4: Resolve Feedback (when asked to)

After resolving review feedback:
1. Commit and push fixes first
2. Then reply to each PR comment with:
   - Robot emoji prefix
   - Status: **Fix** or **Won't Fix**
   - Brief summary of what was done or decided.
3. Resolve each conversation

**Reply dedup (idempotence)**: Before posting a reply on a thread,
fetch that thread's comments and check whether any author matches
`gh api user --jq '.login'`. If yes, skip the thread — you've already
replied during a prior run of this skill. Resolution dedup is
already handled by checking `isResolved` before calling
`resolveReviewThread`.

**Don't end the turn here.** After Step 4 completes — any reply,
resolve, commit, or push — proceed immediately to Step 5. The cycle
is not finished just because you replied to threads; reviewers
typically respond to fixes within minutes, and silently leaving
monitoring inactive is a defect, not a default.

## Step 5: Watch for subsequent activity

Address monitoring before ending the cycle. If Step 4 ran, arm
the watch by default. If the cycle was read-only, ask. Don't end
the cycle silently with monitoring inactive.

- **After Step 4** (you replied, resolved threads, committed, or
  pushed): arm the watch **immediately** unless the user has
  explicitly declined monitoring earlier in the conversation.
  Don't ask — turn-based flow has no in-turn "wait for objection"
  mechanism, and reviewer follow-up within 1–5 minutes of a push
  is the empirical norm.

  Tell the user the watch is running, the budget, and how to stop
  or re-arm. The block below is a *template* — substitute the
  resolved absolute script path and the actual `<owner>`, `<repo>`,
  `<n>` values before showing it to the user. Do not leave any
  `<...>` placeholders literal in user-facing output.

  > "Watch armed for PR #<n> (1h budget). I'll surface any new
  > review activity here. To stop early:
  > `bash <path>/scripts/pr-watch.sh stop <owner> <repo> <n>`.
  > Re-arm with a different window by asking."

- **After Steps 0–3 only** (read-only review, no fixes pushed):
  ask neutrally:

  > "Want me to watch this PR for new reviews/comments? (~1 hour
  > window)"

**Always skip** when the user has explicitly said "no monitoring
this session" earlier in the conversation, when the host agent
genuinely can't background a process (in which case say so), or
when Step 0 already exited because the PR was merged/closed.

If the user declines, say so explicitly ("monitoring off; re-arm
later with…") rather than letting silence imply it.

If they accept (or don't object to a Step-4 default), follow the
steps below.

### Arming the watch

`pr-watch.sh start` polls the PR every 120s and emits a one-line
notification to stdout *only when activity changes*. It is
self-deduplicating via a lockfile at
`/tmp/pr-watch-<owner>-<repo>-<pr>.pid` — a fresh `start` kills
any previous instance for the same PR before taking the lock. It
exits cleanly on PR merge/close or budget elapse.

Default budget is 3600 seconds (1 hour); pass a different value as
the fifth `start` argument (e.g. `... start scarrillo HeartCast 39
1800` for 30 minutes).

#### Operations contract

The script is the **only authority** on watcher state. Operate on
a watch exclusively through three subcommands:

- `start <owner> <repo> <pr> [budget-seconds]` — arm a watch.
- `stop  <owner> <repo> <pr>` — terminate a running watch.
- `check <owner> <repo> <pr>` — query state (used by Step 0;
  also performs stale-watch cleanup on merged/closed PRs).

**Do not:**

- `ps`, `kill`, `pgrep`, or otherwise inspect the watcher process.
- Read or write the lockfile directly.
- Tail script logs if your host already streams stdout.
- Track watch state in your own variables, files, or task lists.
- Implement separate dedup, rate-limiting, or "verify it started"
  checks on top of the script. The script handles all of that.

If you find yourself reaching for one of the above, the contract
is broken — file an issue rather than working around it.

#### Standard invocation per host agent

The script must run beyond the current turn, with stdout capture
that delivers each emitted line to the agent. Use the host's
**native** background-execution primitive — never write your own
`nohup`/`disown`/`&` wrapper unless the host has no native option
(see "Universal fallback" below).

| Host agent | Invocation | Notes |
| --- | --- | --- |
| Claude Code | `Bash` tool with `run_in_background: true` | Stdout streams to a task output file the harness notifies you about on every new line. No `nohup`, no log path, no manual `&`. |
| Codex | (TBD — verify with a test PR) | Likely the same shape as Claude Code; populate this row once tested. |
| Cursor / Windsurf / OpenCode / others | (TBD — verify per agent) | Most expose a backgrounded-shell primitive. Populate as tested. |

#### Universal fallback (no native primitive)

Only when the host genuinely lacks a backgrounded-stdout primitive:

```
nohup bash <abs-path>/scripts/pr-watch.sh start <owner> <repo> <pr> [budget-seconds] \
  > /tmp/pr-watch-<owner>-<repo>-<pr>.log 2>&1 &
```

Then commit to tailing the log file on each notification. This is
strictly worse than the native path — emit lines no longer reach
the agent in real time — but it preserves the operations contract.

#### Stopping manually

```
bash <abs-path>/scripts/pr-watch.sh stop <owner> <repo> <pr>
```

Step 0 also calls `stop` implicitly on merged/closed PRs as a
stale-watch backstop.

### Design notes — read before tweaking

**Why three streams (reviews, review comments, issue comments)**
GitHub PRs have three distinct comment endpoints. Different bots
post to different ones:
- `/pulls/{n}/reviews` — review summaries; **Copilot's overview**
- `/pulls/{n}/comments` — inline diff comments; Copilot/Codex when
  they have line-specific findings
- `/issues/{n}/comments` — top-level conversation; **Codex's verdict**
  comment lands here, as does any human comment in the PR's main
  comment box

Watching only the first two would miss Codex entirely (this happened
once — fixed). The script sums all three.

**Why 120s polling, not 30s or 60s**
Bots typically take 1–5 min to file reviews after a push. Polling
every 30s wastes GitHub API calls during the gap and risks
rate-limit hits if multiple watches are active. 120s is enough
resolution for human timescales and gentle on the API.

**Why selective emit (not periodic heartbeat)**
The script only echoes when the cumulative count *changes*. Most
polls produce silence. Reasoning: every echo becomes a chat
notification on agents that surface stdout lines, and most agent
runtimes auto-throttle or auto-stop processes that emit too many
events. A 1h watch with periodic heartbeats would be 30+
notifications you'd scroll past; selective emit makes silence
meaningful (no news == nothing happened) and the final
timeout/exit message confirms the watch ran to completion.

**Why notify-only on each event (no auto-act)**
PR replies, commits, pushes are shared-state actions. Per project
rules, every such action needs fresh approval per occurrence. The
skill never auto-runs the review flow on a notification — it
surfaces the event and asks. This is intentional, not a feature
gap.

### On each new-activity notification

When a `PR#<PR>: N new event(s) ...` line surfaces from the
background script:

1. **Cross-check the `recent: ...` actor list against your own
   GitHub login** (`gh api user --jq '.login'`). The watcher
   counts every comment/review on the PR, including ones the
   agent posted via `gh api`. If every actor in `recent` is your
   own login, the emit is a self-action footprint, not external
   feedback — say so to the user and stop. Do not re-enter Step 1.
2. If at least one actor is not you, tell the user briefly (who
   reviewed, how many new threads).
3. **Ask** — don't auto-run: *"Want me to re-review PR #<n>?"*
4. If yes, re-enter Step 1 of this skill.

### After completing a re-review cycle

Return to Step 5 and apply the same Step-4-vs-read-only rule:

- If the re-review included Step 4 actions (replies, resolves,
  commits, pushes), re-arm immediately. The new `start` invocation
  kills the previous watcher and resets the counter, so re-emits
  triggered by the just-completed push won't fire spurious
  notifications during the new arm window.
- If the re-review was read-only, ask whether to re-arm.

If the user previously declined monitoring this session, leave the
existing watcher running until its deadline (or until the PR
settles) and don't re-arm.

### When the watch ends

The script's final line is one of:

- `PR#<PR> MERGED — watch stopping` or `CLOSED` → tell the user the
  PR is settled; no re-arm needed.
- `PR#<PR> <budget>s watch elapsed without merge — stopping (re-arm
  to continue)` → ask if they want a fresh window.

If the background process exits without emitting one of the above
(host killed it, machine slept, etc.), tell the user the watch
stopped unexpectedly and ask whether to re-arm. Silence after a
watch ends is a bug — surface the end state in the same turn it
happens, don't wait for the user to ask "is the watch still
running?"
