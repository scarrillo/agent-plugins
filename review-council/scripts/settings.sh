#!/usr/bin/env bash
# settings.sh — persistent defaults for review-council.
#
# Precedence (highest first): environment variable → repo file → home file → built-in.
#   repo file: <git toplevel or cwd>/.council/review-council.env
#   home file: ~/.council/review-council.env
# Files are plain KEY=value lines (# comments allowed) and are read as data,
# never sourced. Values are validated against a per-key pattern.
#
# usage: settings.sh show                 table of effective values and where each came from
#        settings.sh get KEY              print the effective value
#        settings.sh set KEY VALUE [--repo]   write to the home file (or the repo file)
#        settings.sh unset KEY [--repo]   remove a key from the home (or repo) file
#        settings.sh path [--repo]        print the file path
set -u

HOME_FILE=${REVIEW_COUNCIL_HOME_FILE:-"$HOME/.council/review-council.env"}
repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
REPO_FILE="$repo_root/.council/review-council.env"

# KEY @@ default @@ allowed-values regex @@ description   (@@-separated: regexes contain |)
SPEC='MEMBERS @@  @@ ^[a-z, ]*$ @@ default members (comma list); empty = every detected CLI
RUN_MODE @@ ask @@ ^(ask|wait|background)$ @@ what to do when neither --wait nor --background is given
REVIEW_TIMEOUT @@ 900 @@ ^[1-9][0-9]*$ @@ seconds per member (positive)
CLAUDE_MODEL @@  @@ ^[A-Za-z0-9._:-]*$ @@ claude -p --model (empty = CLI default)
CODEX_MODEL @@  @@ ^[A-Za-z0-9._:-]*$ @@ codex model (empty = CLI default)
COPILOT_MODEL @@ fusion @@ ^[A-Za-z0-9._:-]*$ @@ copilot --model; fusion = GitHub router; empty = CLI default
COPILOT_AUTO_TIER @@ balance @@ ^(balance|intelligence)$ @@ Fusion profile; balance = app Standard
COPILOT_EFFORT @@ medium @@ ^(none|minimal|low|medium|high|xhigh|max)$ @@ --reasoning-effort for a pinned copilot model
AGY_MODEL @@ gemini-3.8-flash @@ ^[A-Za-z0-9._:-]*$ @@ antigravity --model family (empty = configured default)
AGY_EFFORT @@ high @@ ^(low|medium|high|xhigh|max)$ @@ antigravity --effort (high = agy default)'

spec_field() { printf '%s\n' "$SPEC" | awk -F' @@ ' -v k="$1" -v f="$2" '$1==k{gsub(/^ +| +$/,"",$f); print $f}'; }
spec_keys() { printf '%s\n' "$SPEC" | awk -F' @@ ' '{print $1}'; }
known_key() { [ -n "$(spec_field "$1" 1)" ]; }
file_value() { [ -f "$2" ] && sed -n "s/^[[:space:]]*$1=//p" "$2" | tail -1 | sed 's/[[:space:]]*$//'; }

file_has() { [ -f "$2" ] && grep -Eq "^[[:space:]]*$1=" "$2"; }

validate() {  # key value  (printf adds the newline so an empty value is still one line for grep)
  local re; re=$(spec_field "$1" 3)
  case $2 in *$'\n'*|*$'\r'*) echo "settings.sh: invalid $1: value must be a single line" >&2; return 1 ;; esac
  printf '%s\n' "$2" | grep -Eq "$re" || { echo "settings.sh: invalid $1='$2' (expected $re)" >&2; return 1; }
  # review-fanout.sh always sends --effort with a pinned family, which conflicts with per-effort ids.
  if [ "$1" = AGY_MODEL ]; then case $2 in *-low|*-medium|*-high|*-xhigh|*-max)
    echo "settings.sh: invalid AGY_MODEL='$2': set the model family (e.g. gemini-3.8-flash) and the effort with AGY_EFFORT" >&2; return 1 ;; esac; fi
}

# An explicitly empty value (KEY= in a file, or KEY= in the environment) is a
# real override that restores the CLI default; only an absent key falls through.
effective() {  # key -> prints "value<TAB>source"
  local k=$1 v
  if [ -n "${!k+set}" ]; then
    v=${!k}; if validate "$k" "$v"; then printf '%s\tenv\n' "$v"; return; fi
    echo "settings.sh: ignoring invalid environment override for $k" >&2
  fi
  if file_has "$k" "$REPO_FILE"; then v=$(file_value "$k" "$REPO_FILE"); if validate "$k" "$v"; then printf '%s\trepo\n' "$v"; return; fi; fi
  if file_has "$k" "$HOME_FILE"; then v=$(file_value "$k" "$HOME_FILE"); if validate "$k" "$v"; then printf '%s\thome\n' "$v"; return; fi; fi
  printf '%s\tdefault\n' "$(spec_field "$k" 2)"
}

write_key() {  # mode(set|unset) key value file
  local mode=$1 k=$2 v=$3 f=$4 tmp rc lock i
  mkdir -p "$(dirname "$f")" && touch "$f" || return 1
  # Serialize concurrent updates: a mkdir lock is atomic and portable.
  lock="$f.lock"; local got=0
  for i in $(seq 1 50); do if mkdir "$lock" 2>/dev/null; then got=1; break; fi; sleep 0.1; done
  # Only the call that created the lock may proceed or remove it.
  [ "$got" = 1 ] || { echo "settings.sh: could not lock $f (held by another writer)" >&2; return 1; }
  # RETURN does not fire when a signal ends the script, so clean up on those too.
  trap 'rm -f "${tmp:-}"; rmdir "$lock" 2>/dev/null; exit 130' INT TERM HUP
  trap 'rmdir "$lock" 2>/dev/null; trap - INT TERM HUP RETURN' RETURN
  tmp=$(mktemp) || return 1
  grep -v "^[[:space:]]*$k=" "$f" > "$tmp"; rc=$?
  # grep: 0 = other lines kept, 1 = nothing else in the file; anything higher is
  # a read error and must not turn into an empty replacement.
  [ "$rc" -le 1 ] || { rm -f "$tmp"; echo "settings.sh: could not read $f" >&2; return 1; }
  if [ "$mode" = set ]; then printf '%s=%s\n' "$k" "$v" >> "$tmp" || return 1; fi
  mv "$tmp" "$f"
}

cmd=${1:-show}; shift || true
case $cmd in
  show)
    printf '%-18s %-14s %-8s %s\n' KEY VALUE SOURCE DESCRIPTION
    for k in $(spec_keys); do
      line=$(effective "$k"); v=${line%$'\t'*}; src=${line##*$'\t'}
      printf '%-18s %-14s %-8s %s\n' "$k" "${v:-"(empty)"}" "$src" "$(spec_field "$k" 4)"
    done
    echo; echo "home file: $HOME_FILE$( [ -f "$HOME_FILE" ] || echo ' (absent)')"
    echo "repo file: $REPO_FILE$( [ -f "$REPO_FILE" ] || echo ' (absent)')" ;;
  get)
    known_key "${1:-}" || { echo "settings.sh: unknown key '${1:-}'" >&2; exit 2; }
    effective "$1" | cut -f1 ;;
  set|unset)
    k=${1:-}; known_key "$k" || { echo "settings.sh: unknown key '$k'" >&2; exit 2; }
    if [ "$cmd" = set ]; then [ $# -ge 2 ] || { echo "usage: settings.sh set KEY VALUE [--repo]" >&2; exit 2; }; v=$2; shift 2; validate "$k" "$v" || exit 2
    else v=""; shift; fi
    f=$HOME_FILE; [ "${1:-}" = --repo ] && f=$REPO_FILE
    write_key "$cmd" "$k" "$v" "$f" || { echo "settings.sh: could not write $f" >&2; exit 1; }
    if [ "$cmd" = set ]; then echo "set $k=$v in $f"; else echo "unset $k in $f"; fi ;;
  path) f=$HOME_FILE; [ "${1:-}" = --repo ] && f=$REPO_FILE; echo "$f" ;;
  *) echo "usage: settings.sh show | get KEY | set KEY VALUE [--repo] | unset KEY [--repo] | path [--repo]" >&2; exit 2 ;;
esac
