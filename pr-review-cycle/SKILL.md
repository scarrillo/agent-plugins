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
- `bash` 4+.

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
- `state=UNKNOWN` → API lookup failed; tell the user the script
  couldn't determine state and proceed cautiously to Step 1 (the PR
  likely still exists; a transient `gh` failure shouldn't block).

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

Present a summary to the user:
- What the PR does (purpose, scope)
- All review feedback grouped by priority
- Which conversations are resolved vs. still open
- Proposed next steps

Form an objective analysis of the PR feedback, don't assume the
feedback is correct.

Pay particular attention to:
1. **Security** — secrets exposure, input validation, encryption,
   injection risks
2. **Performance** — main thread work, unnecessary recomputation,
   caching opportunities
3. **Error handling** — silent failures, missing user-facing alerts,
   unhandled edge cases
4. **Accessibility** — VoiceOver/screen readers, dynamic type,
   contrast, touch targets (where applicable to the project's
   platform)

Don't limit your review to these areas — flag anything that looks
wrong, fragile, or could be improved. Consider misuse, edge cases,
and risk. Suggest improvements scoped to the current review —
readability, maintainability, and structure.

**DO NOT** nitpick formatting — defer to project linters.
**DO NOT** introduce unrelated refactors — propose them as a later
todo.

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

## Step 5: Watch for subsequent activity (optional, ask first)

After the initial review (and any fixes/pushes), offer:

> "Want me to watch this PR for new reviews/comments? (~1 hour
> window)"

If the user declines, end here. If yes, follow the steps below.

### Arming the watch

The `start` subcommand of `pr-watch.sh` polls every 120s and emits a
one-line `PR#<n>: N new event(s) ...` notification to stdout
*only when the cumulative comment/review count changes*. It exits
cleanly when the PR merges/closes or the budget elapses.

The script is **self-deduplicating** via a lockfile at
`/tmp/pr-watch-<owner>-<repo>-<pr>.pid`. A fresh `start` invocation
kills any previous instance for the same PR before taking the lock,
so you don't need to track running processes externally.

Arm it by invoking the script as a backgrounded process from your
host agent. The exact mechanism varies per agent — pick whichever
your host exposes:

- A background-bash tool / job (preferred when available — lets the
  agent receive new stdout lines as they're emitted)
- `nohup bash <absolute-path>/scripts/pr-watch.sh start <owner>
  <repo> <pr> [budget-seconds] > /tmp/pr-watch-<owner>-<repo>-<pr>.log
  2>&1 &` followed by tailing the log file for new lines
- Foreground in a separate terminal pane the user can monitor

Default budget is 3600 seconds (1 hour); pass a different value as
the fifth argument to shorten or extend (e.g. `... start scarrillo
HeartCast 39 1800` for 30 minutes).

To stop a running watch manually:

```
bash <absolute-path>/scripts/pr-watch.sh stop <owner> <repo> <pr>
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
1. Tell the user briefly (who reviewed, how many new threads).
2. **Ask** — don't auto-run: *"Want me to re-review PR #<n>?"*
3. If yes, re-enter Step 1 of this skill.

### After completing a re-review cycle

Offer to re-arm: *"Re-arm the watch for another hour?"*

If yes, repeat the "Arming the watch" steps — the previous watcher
gets killed by the new `start` invocation. The counter resets, so
re-emits triggered by the just-completed push won't fire spurious
notifications during the new arm window.

If no, exit. The previous watcher will continue until its existing
deadline (or until the PR merges/closes, whichever first).

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
