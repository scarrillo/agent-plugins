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

    # Configured GitHub user (the auth identity that's running this
    # script). When non-empty, fetch_stream filters out actions by
    # this user — so emits never fire for the agent's own gh-api
    # activity (replies, resolves, etc.) and the `recent` actor
    # list never contains self. On fetch failure (auth issue, no
    # network), self_login stays empty and the filter degrades to
    # a no-op — script behaves identically to pre-filter versions.
    self_login=$(gh api user --jq '.login' 2>/dev/null) || self_login=""

    # Fetch one stream's (count, recent-actor csv). Echoes "count|csv"
    # on success, empty on failure so callers can detect via
    # [ -n "$result" ]. When self_login is non-empty, items authored
    # by self are filtered out before counting and before the
    # recent-actor list is built.
    #
    # `--paginate` is required: gh api defaults to per_page=30, so
    # without it `length` would freeze at 30 once a stream exceeds
    # one page and the watcher would silently miss all further
    # activity on busy PRs. `jq -s` slurps every page (each is its
    # own JSON array) into an array-of-arrays; `(add // [])` flattens
    # them, defaulting to [] so empty/failed input doesn't crash the
    # downstream filter.
    fetch_stream() {
      gh api --paginate "$1" 2>/dev/null \
        | jq -s -r --arg self "$self_login" \
          '(add // []) | [.[] | select(.user.login != $self)] | "\(length)|\((.[-3:] | map(.user.login) | unique | join(",")))"' \
          2>/dev/null
    }

    # Combine three recent-actor csvs into one deduped csv. Skips
    # empty fields so a stream with no recent actors doesn't insert
    # blanks.
    combine_recent() {
      jq -nr --arg a "$1" --arg b "$2" --arg c "$3" \
        '[$a, $b, $c] | map(split(",")) | add | unique | map(select(length > 0)) | join(",")'
    }

    # Pre-loop baseline: establish prev_total at arm time so the
    # main loop only ever reports true deltas. Done synchronously
    # within ~1s of `start`, before the 120s cadence can mask
    # incoming activity. On pre-fetch failure (transient gh error),
    # prev_total stays 0 and no baseline emit fires; the first
    # successful loop poll then labels everything as "new event(s)"
    # — over-noisy but never silently folds genuine feedback into
    # "baseline."
    prev_total=0
    rev_data=$(fetch_stream "repos/$owner/$repo/pulls/$pr/comments")
    reviews_data=$(fetch_stream "repos/$owner/$repo/pulls/$pr/reviews")
    iss_data=$(fetch_stream "repos/$owner/$repo/issues/$pr/comments")
    if [ -n "$rev_data" ] && [ -n "$reviews_data" ] && [ -n "$iss_data" ]; then
      base_rev=${rev_data%%|*};         rev_recent_csv=${rev_data#*|}
      base_reviews=${reviews_data%%|*}; reviews_recent_csv=${reviews_data#*|}
      base_iss=${iss_data%%|*};         iss_recent_csv=${iss_data#*|}
      prev_total=$((base_rev + base_reviews + base_iss))
      if [ "$prev_total" -gt 0 ]; then
        base_recent=$(combine_recent "$rev_recent_csv" "$reviews_recent_csv" "$iss_recent_csv")
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

      rev_data=$(fetch_stream "repos/$owner/$repo/pulls/$pr/comments")
      reviews_data=$(fetch_stream "repos/$owner/$repo/pulls/$pr/reviews")
      iss_data=$(fetch_stream "repos/$owner/$repo/issues/$pr/comments")

      if [ -n "$rev_data" ] && [ -n "$reviews_data" ] && [ -n "$iss_data" ]; then
        rev_comments=${rev_data%%|*};     rev_recent_csv=${rev_data#*|}
        reviews=${reviews_data%%|*};      reviews_recent_csv=${reviews_data#*|}
        iss_comments=${iss_data%%|*};     iss_recent_csv=${iss_data#*|}
        total=$((rev_comments + reviews + iss_comments))
        if [ "$total" -gt "$prev_total" ]; then
          new=$((total - prev_total))
          latest=$(combine_recent "$rev_recent_csv" "$reviews_recent_csv" "$iss_recent_csv")
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
