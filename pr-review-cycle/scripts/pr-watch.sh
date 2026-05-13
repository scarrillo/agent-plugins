#!/usr/bin/env bash
# pr-watch.sh — manage a GitHub PR review-activity watch.
#
# Usage:
#   pr-watch.sh check <owner> <repo> <pr-number>
#   pr-watch.sh start <owner> <repo> <pr-number> [budget-seconds]
#   pr-watch.sh stop  <owner> <repo> <pr-number>
#
# `check` queries the PR state and stops any stale watch if the PR is
# already merged or closed. Output is a single line:
#   PR#<pr> state=OPEN
#   PR#<pr> state=MERGED, stopped active watch (pid=...)
#   PR#<pr> state=CLOSED, stale lockfile removed
#   PR#<pr> state=UNKNOWN, no active watch    (gh lookup failed)
# Always exits 0; callers branch on the parsed state, not exit code.
#
# `start` polls the PR every 120s until the budget elapses, the PR
# merges/closes, or a previous instance for the same PR is killed by
# this fresh `start` (self-deduplicating via lockfile).
#
# Emit shapes (one line per emit, only when activity changes):
#   PR#<pr> baseline: <N> existing event(s) at arm time — ...
#       from a synchronous pre-loop fetch within ~1s of `start`,
#       only when the PR already has activity at arm time
#   PR#<pr>: <N> new event(s) — ...
#       from each subsequent poll when the cumulative count grows
#   PR#<pr> MERGED — watch stopping        (terminal)
#   PR#<pr> CLOSED — watch stopping        (terminal)
#   PR#<pr> <budget>s watch elapsed without merge — stopping (re-arm to continue)
#       (terminal, on budget elapse)
#
# `stop` kills any running watch for the given PR and cleans up the
# lockfile. Exits 0 whether or not a watch was running.
#
# Designed to be paired with the pr-review-cycle skill's Step 5
# (PR watch). The script itself has no opinion on what to do with
# notifications; the caller decides.

set -u

# Fail fast on missing runtime deps. The script polls GitHub via `gh`
# and parses JSON via `jq`; without either it would just emit cryptic
# errors mid-loop. Exit code 2 distinguishes a setup failure from a
# normal lifecycle exit (0).
for dep in gh jq; do
  if ! command -v "$dep" >/dev/null 2>&1; then
    echo "pr-watch.sh: required dependency '$dep' not found on PATH" >&2
    exit 2
  fi
done

action=${1:?usage: pr-watch.sh <start|stop> <owner> <repo> <pr-number> [...]}
shift

owner=${1:?owner}
repo=${2:?repo}
pr=${3:?pr-number}

# Validate args against GitHub's naming rules before they become
# part of the lockfile path:
#   owner: alphanumeric and hyphen, no leading hyphen
#   repo:  alphanumeric, period, underscore, hyphen
#   pr:    positive integer (decimal digits only)
# This keeps the lockfile bounded to `/tmp/pr-watch-<safe>.pid` —
# no path-traversal (`/` or `..`) sneaks in via args, no surprising
# globs, no shell metacharacters reaching the filesystem. Exit
# code 2 matches the deps check above.
case "$owner" in
  ''|-*|*[!A-Za-z0-9-]*)
    echo "pr-watch.sh: invalid owner '$owner' (expected GitHub login: alphanumeric and hyphen, no leading hyphen)" >&2
    exit 2 ;;
esac
case "$repo" in
  ''|*[!A-Za-z0-9._-]*)
    echo "pr-watch.sh: invalid repo '$repo' (expected GitHub repo name: alphanumeric, period, underscore, hyphen)" >&2
    exit 2 ;;
esac
case "$pr" in
  ''|*[!0-9]*|0*)
    # `0*` rejects "0" itself plus any leading-zero form (e.g. "01",
    # "010") — GitHub PR numbers start at 1 and don't carry leading
    # zeros, and the API canonicalizes path components without them.
    echo "pr-watch.sh: invalid pr-number '$pr' (expected positive integer, no leading zeros)" >&2
    exit 2 ;;
esac

# Lockfile path lives in one place — both start and stop derive it the
# same way so they can never disagree on where to look.
lockfile="/tmp/pr-watch-${owner}-${repo}-${pr}.pid"

case "$action" in
  check)
    state=$(gh pr view "$pr" --repo "$owner/$repo" --json state --jq '.state' 2>/dev/null) || state=""
    [ -z "$state" ] && state="UNKNOWN"

    if [ "$state" = "OPEN" ]; then
      echo "PR#$pr state=OPEN"
      exit 0
    fi

    # Settled (or unknown) — stop any active watch as a backstop in case
    # the watch's own state-detection hasn't yet polled.
    if [ -f "$lockfile" ]; then
      pid=$(cat "$lockfile" 2>/dev/null)
      if [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null
        echo "PR#$pr state=$state, stopped active watch (pid=$pid)"
      else
        rm -f "$lockfile"
        echo "PR#$pr state=$state, stale lockfile removed"
      fi
    else
      echo "PR#$pr state=$state, no active watch"
    fi
    exit 0
    ;;

  start)
    budget=${4:-3600}

    # Self-deduplicate: at most one watcher per PR. If a previous
    # instance is still running for this same (owner, repo, pr), kill
    # it before we start. The trap removes the lockfile on any clean
    # exit (SIGKILL is unrecoverable but the OS reaps the file on
    # reboot).
    if [ -f "$lockfile" ]; then
      old_pid=$(cat "$lockfile" 2>/dev/null)
      if [ -n "${old_pid:-}" ] && kill -0 "$old_pid" 2>/dev/null; then
        kill "$old_pid" 2>/dev/null
        sleep 1
      fi
    fi
    echo $$ > "$lockfile"
    trap 'rm -f "$lockfile"' EXIT
    # User-initiated stops (`pr-watch.sh stop` sends SIGTERM via
    # `kill <pid>`; Ctrl-C sends SIGINT) are not failures — they're
    # the documented way to terminate the watcher. Exit 0 so host
    # agents that label non-zero exits as "failed" report a clean
    # completion. The EXIT trap above still fires after this one,
    # so the lockfile is cleaned up either way. Genuine crashes
    # (SIGSEGV, set -u violations, etc.) still exit non-zero.
    trap 'exit 0' TERM INT

    deadline=$(($(date +%s) + budget))

    # Three streams to watch:
    #   /pulls/{n}/comments  — inline review comments on the diff
    #   /pulls/{n}/reviews   — review summaries (Copilot lands here)
    #   /issues/{n}/comments — top-level PR conversation (Codex lands here)

    # Pre-loop baseline fetch: establish prev_total at arm time so
    # the main loop only ever reports true deltas. Done synchronously
    # within ~1s of the `start` invocation, before the 120s polling
    # cadence has any chance to mask incoming activity.
    #
    # If the pre-fetch fails (transient gh error, no network), we
    # leave prev_total=0 with no baseline emit; the first successful
    # poll in the loop will report the entire existing count as "new
    # event(s)". That over-triggers a re-review of nothing-new, but
    # never silently folds genuine new feedback into "baseline" — the
    # safer failure mode.
    prev_total=0
    base_rev=$(gh api "repos/$owner/$repo/pulls/$pr/comments" --jq '. | length' 2>/dev/null) || base_rev=""
    base_reviews=$(gh api "repos/$owner/$repo/pulls/$pr/reviews" --jq '. | length' 2>/dev/null) || base_reviews=""
    base_iss=$(gh api "repos/$owner/$repo/issues/$pr/comments" --jq '. | length' 2>/dev/null) || base_iss=""
    if [ -n "$base_rev" ] && [ -n "$base_reviews" ] && [ -n "$base_iss" ]; then
      prev_total=$((base_rev + base_reviews + base_iss))
      if [ "$prev_total" -gt 0 ]; then
        base_reviewers=$(gh api "repos/$owner/$repo/pulls/$pr/reviews" \
          --jq '.[-3:] | map(.user.login) | unique' 2>/dev/null)
        base_commenters=$(gh api "repos/$owner/$repo/issues/$pr/comments" \
          --jq '.[-3:] | map(.user.login) | unique' 2>/dev/null)
        base_recent=$(echo "$base_reviewers $base_commenters" | jq -s 'add | unique | join(",")' 2>/dev/null)
        echo "PR#$pr baseline: $prev_total existing event(s) at arm time — reviews=$base_reviews rev_comments=$base_rev iss_comments=$base_iss — recent: $base_recent"
      fi
    fi

    while [ "$(date +%s)" -lt "$deadline" ]; do
      # GitHub's PR state field returns OPEN, MERGED, or CLOSED directly —
      # no need to derive from a `merged` boolean (which isn't a valid gh
      # field; using it silently fails and breaks merge detection).
      state=$(gh pr view "$pr" --repo "$owner/$repo" --json state --jq '.state' 2>/dev/null) || true
      if [ -n "${state:-}" ] && [ "$state" != "OPEN" ]; then
        echo "PR#$pr $state — watch stopping"
        exit 0
      fi

      rev_comments=$(gh api "repos/$owner/$repo/pulls/$pr/comments" --jq '. | length' 2>/dev/null) || rev_comments=""
      reviews=$(gh api "repos/$owner/$repo/pulls/$pr/reviews" --jq '. | length' 2>/dev/null) || reviews=""
      iss_comments=$(gh api "repos/$owner/$repo/issues/$pr/comments" --jq '. | length' 2>/dev/null) || iss_comments=""

      if [ -n "$rev_comments" ] && [ -n "$reviews" ] && [ -n "$iss_comments" ]; then
        total=$((rev_comments + reviews + iss_comments))
        if [ "$total" -gt "$prev_total" ]; then
          new=$((total - prev_total))
          latest_reviewers=$(gh api "repos/$owner/$repo/pulls/$pr/reviews" \
            --jq '.[-3:] | map(.user.login) | unique' 2>/dev/null)
          latest_commenters=$(gh api "repos/$owner/$repo/issues/$pr/comments" \
            --jq '.[-3:] | map(.user.login) | unique' 2>/dev/null)
          latest=$(echo "$latest_reviewers $latest_commenters" | jq -s 'add | unique | join(",")' 2>/dev/null)
          echo "PR#$pr: $new new event(s) — reviews=$reviews rev_comments=$rev_comments iss_comments=$iss_comments — recent: $latest"
          prev_total=$total
        fi
      fi

      sleep 120
    done

    echo "PR#$pr ${budget}s watch elapsed without merge — stopping (re-arm to continue)"
    ;;

  stop)
    if [ ! -f "$lockfile" ]; then
      echo "no active watch for $owner/$repo#$pr"
      exit 0
    fi
    pid=$(cat "$lockfile" 2>/dev/null)
    if [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null
      echo "stopped watch for $owner/$repo#$pr (pid=$pid)"
    else
      rm -f "$lockfile"
      echo "stale lockfile for $owner/$repo#$pr removed"
    fi
    ;;

  *)
    echo "Unknown action: $action" >&2
    echo "Usage: pr-watch.sh <check|start|stop> <owner> <repo> <pr-number> [...]" >&2
    exit 1
    ;;
esac
