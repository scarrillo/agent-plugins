---
name: pr-review-cycle
description: Drive the full GitHub PR review → resolve → watch loop. Summarize a pull request, surface review conversations, prioritize open feedback, optionally commit and reply to resolve threads, then watch the PR for new reviewer activity and re-enter the cycle. Use when the user asks to review, respond to, or monitor a PR by URL or number.
allowed-tools: Bash, Read, Grep, Glob, Monitor
---

# PR Review Cycle

Drive a GitHub pull request through one full review → resolve →
watch loop. Identify the PR from the user's request (URL or
`#number`); if ambiguous, ask before proceeding. The cycle mirrors
the body headings below:

- **Preflight** — confirm worktree and branch state
- **Step 0** — check PR state (open vs. merged/closed; bail if
  settled)
- **Step 1** — fetch PR details (diff, threads, reviews)
- **Step 2** — review conversations
- **Step 3** — summarize and prioritize feedback
- **Step 4** — resolve threads, commit, push, reply (invoked when
  Step 5's menu picks Address or Both)
- **Step 5** — choose next action (Address / Monitor / Both / Hold)
- On new watcher activity, re-enter **Step 1** to re-fetch and
  loop through the cycle again

## Prerequisites

- `gh` (GitHub CLI) authenticated for the target repo.
- `jq` on `PATH` — the bundled script parses GitHub JSON responses.
- `bash` 4+ in a POSIX-ish environment (lockfile path is `/tmp/...`,
  POSIX signal handling via `kill <pid>` and `trap` used internally
  by the script).

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

## Step 5: Choose next action

Step 3 surfaced the analysis. **No actions on the PR have been
taken yet** — present the user a concise menu of next actions and
let them choose. Don't end the cycle without surfacing this prompt,
even when the menu is trivial.

The available choices depend on whether Step 2 found open feedback:

| Choice | Offered when | What happens |
| --- | --- | --- |
| **Address feedback** | Step 2 found open threads | Run Step 4 (commit/push/reply/resolve); arm the watcher when Step 4 returns |
| **Monitor** | Always | Arm the 1h watcher; make no other changes to the PR |
| **Both** | Step 2 found open threads | Same as Address (Step 4 → arm), included as an explicit menu item so a user who hasn't seen the cycle before doesn't have to infer it |
| **Hold** | Always | End the cycle with no action; tell the user how to re-arm later |

Phrasing template (substitute the resolved absolute script path
and the actual `<owner>`, `<repo>`, `<n>` values; do not leave any
`<...>` placeholders literal in user-facing output):

> "Next steps on PR #<n>:
> - Address open feedback (<N> open thread(s))
> - Monitor for new reviewer activity (~1h watcher)
> - Both — address then monitor
> - Hold (no action; re-arm later with
>   `bash <path>/scripts/pr-watch.sh start <owner> <repo> <n>`)
>
> Which would you like?"

When Step 2 found no open feedback, omit the "Address" and "Both"
rows from the prompt and present just **Monitor** vs **Hold**.

### After the user picks

The table above already describes what each choice does. The one
extra detail the table can't carry is the user-facing phrasing
when arming a watcher — use this template for Address, Both, and
Monitor paths:

> "Watch armed for PR #<n> (1h budget). I'll surface any new
> review activity here. To stop early:
> `bash <path>/scripts/pr-watch.sh stop <owner> <repo> <n>`.
> Re-arm with a different window by asking."

For **Hold**, no watcher is armed — say so explicitly (e.g. "no
action taken; watcher off") and reuse the `pr-watch.sh start`
command from the menu's Hold row as the re-arm reminder.

**Verification re-fetch (Address or Both paths only):** Right
after arming the watcher post-Step-4, re-enter Step 1 once. A
reviewer's reaction to your push can arrive between Step 4
completing and the watcher's pre-loop baseline fetch — this
re-entry catches anything in that race window. If Step 2 sees
new threads compared to its previous iteration, run through Step
3 again. Otherwise the cycle is complete and ongoing
notifications come from the running watcher. The Monitor path
doesn't need this — no push happened, no race window exists.

**Always skip the prompt** when the user has explicitly said "no
monitoring this session" earlier in the conversation, when the
host agent genuinely can't background a process (say so), or when
Step 0 already exited because the PR was merged/closed.

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
- Tail script logs when your host's streaming primitive already
  delivers them as notifications (you'd just be duplicating the
  same content). The capture-only fallback below is the explicit
  exception by design — it has no streaming, so log tailing is
  the only way to surface emits.
- Track watch state in your own variables, files, or task lists.
- Implement separate dedup, rate-limiting, or "verify it started"
  checks on top of the script. The script handles all of that.

If you find yourself reaching for one of the above, the contract
is broken — file an issue rather than working around it.

#### Standard invocation per host agent

The script must run beyond the current turn, **and the agent must
receive each emitted stdout line as a real-time notification.** An
emit-once-and-tell-me-later mechanism (e.g. completion-only
notifications) defeats the purpose of the watcher — every line
the script produces is something the user needs to know about as
it happens. Pick the primitive that streams; do not write your
own `nohup`/`disown`/`&` wrapper unless the host has nothing
better (see "Capture-only fallback" below).

| Host agent | Streaming primitive | Notes |
| --- | --- | --- |
| Claude Code | `Monitor` tool, `persistent: true`, `timeout_ms: 3600000` | Each stdout line from the script becomes a real-time agent notification — exactly what `pr-watch.sh`'s selective-emit design assumes. Stop with `pr-watch.sh stop` (preferred — keeps the contract), or `TaskStop` as a last resort. **Do not** use `Bash` with `run_in_background: true`: it only notifies the agent on task completion, not per emit, so the watcher's notifications are invisible until the run ends. |
| Codex | Capture-only fallback (see below) | Codex has **no per-emit streaming primitive** — a shell command's stdout returns when the command completes, not line-by-line. Use the `nohup … > log &` form below; the watcher survives across turns as a child of the long-lived Codex session. Read the log file when the user asks "anything new?" (or you suspect a notification landed). **Re-arming is safe and idempotent** — a fresh `start` reliably reaps any prior watcher for the same PR via the lockfile, so you will not accumulate duplicate watchers. **Do not** treat a blocking foreground `start` as the watch: it would stall the turn for the full budget. |
| Cursor / Windsurf / OpenCode / others | (TBD — verify per agent) | Same requirement: real-time stdout streaming. Capture-only mechanisms are second-best. Populate as tested. |

#### Capture-only fallback (no streaming primitive available)

Only when the host genuinely lacks a real-time-stdout primitive:

```
nohup bash <abs-path>/scripts/pr-watch.sh start <owner> <repo> <pr> [budget-seconds] \
  > /tmp/pr-watch-<owner>-<repo>-<pr>.log 2>&1 &
```

Then explicitly read the log file when the user asks "anything
new?" or when you have reason to think a notification may have
arrived. This is **strictly worse** than the streaming path —
emit lines no longer reach the agent in real time, so the
"monitor pings me on new activity" UX is gone — but it preserves
the operations contract. The same downgrade applies to any other
mechanism that notifies on task completion rather than per-emit
(such as Claude Code's `Bash` with `run_in_background: true`);
treat those as capture-only too.

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

### On each emit from the background script

The script emits two kinds of activity lines (see the script's
header comment for the full inventory). Pattern-match the prefix
to decide what to do.

**The script filters self-actions at source.** At `start`, it
fetches the configured `gh` user's login and excludes that user's
comments and reviews from both the count and the `recent:` list.
Emits that surface normally represent external activity, so you
don't need to cross-check `recent` against your own login.

**Degraded-mode caveat:** the script falls back to a no-op filter
if `gh api user` failed at arm time (auth issue, no network). In
that path emits *can* contain self-actions. If you have any reason
to suspect the watcher armed in degraded auth — e.g. earlier `gh`
calls in this session erroring — fall back to the old behavior:
cross-check `recent` against `gh api user --jq '.login'` before
treating an emit as external.

#### `PR#<n> baseline: N existing event(s) at arm time — ...`

Emitted within seconds of `start`, from a pre-loop fetch that
runs before the polling cadence begins. `N` is the count of
external events that already existed on the PR at arm time, not
new feedback. Tell the user briefly:

> "Watch armed for PR #<n>. Baseline: N existing event(s) from
> `<recent>`."

Do **not** re-enter Step 1; nothing has changed since the cycle
that just armed the watcher.

#### `PR#<n>: N new event(s) — ...`

A real external change since the previous emit (or since arm if
there was no baseline). When this surfaces:

1. Tell the user briefly (who reviewed, how many new threads).
2. **Ask** — don't auto-run: *"Want me to re-review PR #<n>?"*
3. If yes, re-enter Step 1 of this skill.

### After completing a re-review cycle

Return to Step 5 and present the menu again. The same rules apply:
the user picks Address/Monitor/Both/Hold, and the cycle proceeds
accordingly. A fresh `start` from the menu's Monitor or Both paths
kills the previous watcher and resets the counter, so re-emits
triggered by the just-completed push won't fire spurious
notifications during the new arm window.

If the user previously declined monitoring this session, suppress
the Monitor and Both menu items entirely — only show Address (if
applicable) and Hold. Leave the existing watcher running until its
deadline (or until the PR settles).

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
