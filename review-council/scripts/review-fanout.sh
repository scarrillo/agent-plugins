#!/usr/bin/env bash
# review-fanout.sh — run every review-council member in parallel against a prepared
# review packet. The lead agent builds the packet (see ../SKILL.md); this
# script only invokes the members, captures replies, and records status.
#
# usage: review-fanout.sh <session-dir> <member>...        (run from the project dir)
# settings (env var, or persisted via settings.sh — run `settings.sh show`):
#        REVIEW_TIMEOUT, CLAUDE_MODEL, CODEX_MODEL, COPILOT_MODEL,
#        COPILOT_AUTO_TIER, COPILOT_EFFORT, AGY_MODEL, AGY_EFFORT.
#
# Expects in <session-dir>:
#   target.env            MODE=uncommitted|unpushed|branch|pr  BASE_REF=<ref>  CODEX_NATIVE=0|1
#                         (plain KEY=value lines, read as data; not sourced)
#   prompts/<member>.md   one prompt per member
# Writes:
#   replies/<member>.md   the member's reply (may be empty on failure)
#   logs/<member>.log     stderr / progress output
#   logs/<member>.problem one-line failure a reply parser found (claude, copilot)
#   logs/<member>.model   the model the CLI reports having used (authoritative where
#                         the CLI exposes it; "unknown" otherwise)
#   status.md             one line per member: name, status, duration, model, reply path
set -u
# Must run on macOS /bin/bash 3.2: optional-argument arrays are expanded as
# ${arr[@]+"${arr[@]}"} because a plain "${arr[@]}" on an empty array is an
# unbound-variable error there.

SESSION=${1:-}
[ -n "$SESSION" ] && [ -d "$SESSION" ] || { echo "usage: review-fanout.sh <session-dir> <member>..." >&2; exit 2; }
shift
[ $# -gt 0 ] || { echo "review-fanout.sh: no members given" >&2; exit 2; }
[ -f "$SESSION/target.env" ] || { echo "review-fanout.sh: missing $SESSION/target.env" >&2; exit 2; }

# Read target.env as data, not shell: BASE_REF may derive from a branch name.
read_key() { sed -n "s/^$1=//p" "$SESSION/target.env" | head -1; }
MODE=$(read_key MODE); MODE=${MODE:-uncommitted}
BASE_REF=$(read_key BASE_REF)
CODEX_NATIVE=$(read_key CODEX_NATIVE); CODEX_NATIVE=${CODEX_NATIVE:-0}
case $BASE_REF in *[\$\`\;\|\&\<\>\(\)]*|-*) echo "review-fanout.sh: refusing suspicious BASE_REF: $BASE_REF" >&2; exit 2 ;; esac
# Settings: env var → repo .council/review-council.env → ~/.council/review-council.env → default.
SETTINGS="$(dirname "$0")/settings.sh"
[ -f "$SETTINGS" ] || { echo "review-fanout.sh: missing $SETTINGS" >&2; exit 2; }
setting() { bash "$SETTINGS" get "$1"; }
TIMEOUT=$(setting REVIEW_TIMEOUT)
case $TIMEOUT in ''|*[!0-9]*|0) echo "review-fanout.sh: REVIEW_TIMEOUT must be a positive integer (got '$TIMEOUT')" >&2; exit 2 ;; esac
CLAUDE_MODEL=$(setting CLAUDE_MODEL)
CODEX_MODEL=$(setting CODEX_MODEL)
COPILOT_MODEL=$(setting COPILOT_MODEL)
COPILOT_EFFORT=$(setting COPILOT_EFFORT)
COPILOT_AUTO_TIER=$(setting COPILOT_AUTO_TIER)
AGY_MODEL=$(setting AGY_MODEL)
AGY_EFFORT=$(setting AGY_EFFORT)

# Pre-flight: every named member needs its prompt before anything is launched.
# (A lead-side shell slip once produced a single file named after all members.)
missing=""
for m in "$@"; do [ -s "$SESSION/prompts/$m.md" ] || missing="$missing $m"; done
if [ -n "$missing" ]; then
  echo "review-fanout.sh: missing or empty prompt file for:$missing" >&2
  echo "review-fanout.sh: prompts present: $(ls "$SESSION/prompts" 2>/dev/null | tr '\n' ' ')" >&2
  exit 2
fi

# The session holds full diffs and replies: keep it owner-only regardless of
# the caller's umask, and refuse to continue if that cannot be guaranteed.
(umask 077 && mkdir -p "$SESSION/replies" "$SESSION/logs") && chmod 700 "$SESSION" \
  || { echo "review-fanout.sh: cannot create an owner-only session directory at $SESSION" >&2; exit 2; }
umask 077
rm -f "$SESSION/.cancelled"
: > "$SESSION/status.md"

# macOS has no `timeout`; perl is universal. Runs the member in its own
# process group so a timeout (or cancelling this script) kills helpers and
# workers too. Exit codes: 142 = timeout, 143 = cancelled, 127 = binary could
# not be started, otherwise the member's own.
# claude and copilot are run with JSON output so the model id comes from the
# CLI itself; these pull the reply text out and print the model. JSON::PP has
# been in core perl since 5.14, so this adds no dependency beyond the timeout wrapper.
# A parser that finds a failure writes a one-line status to problem-file, and
# its details to stderr (the member's log).
claude_reply() {  # json-file reply-file problem-file -> prints model
  perl -MJSON::PP -e '
    my ($rf, $pf) = @ARGV;
    sub problem { open my $p, ">", $pf or die; print $p "$_[0]\n"; close $p }
    open my $o, ">:encoding(UTF-8)", $rf or die;
    local $/; my $d = eval { decode_json(<STDIN>) };
    # With verbose on (a global config setting) the CLI prints every event as a
    # list; the outcome is the last "result" event.
    ($d) = reverse grep { ref $_ eq "HASH" && ($_->{type} // "") eq "result" } @$d if ref $d eq "ARRAY";
    unless (ref $d eq "HASH" && ($d->{type} // "result") eq "result") { problem("claude unparsed-json (see log)"); print "unknown"; exit 0 }
    my @m = ref $d->{modelUsage} eq "HASH" ? sort(keys %{ $d->{modelUsage} }) : ();
    my $sub = $d->{subtype} // "success";
    if ($d->{is_error} || $sub ne "success") {
      my $why = $sub ne "success" ? $sub : "api " . ($d->{api_error_status} // "error"); $why =~ s/[^\w. -]/_/g;
      problem("claude error: $why");
      print STDERR "claude result: $why: " . substr(ref $d->{result} ? "" : $d->{result} // "", 0, 300) . "\n";
    } elsif (!defined $d->{result} || ref $d->{result}) {
      problem("claude unparsed-json (see log)");
    } else { print $o $d->{result} }
    close $o; print @m ? join(", ", @m) : "unknown";
  ' "$2" "$3" < "$1"
}
agy_deny_settings() {  # prints the --settings JSON: our read-only deny rules + the user's persisted deny rules
  perl -MJSON::PP -e '
    my @ours = ("command(*)", "unsandboxed(*)", "write_file(*)", "edit_file(*)", "execute_url(*)", "read_url(*)", "mcp(*)");
    my @theirs;
    if (open my $f, "<", "$ENV{HOME}/.gemini/antigravity-cli/settings.json") {
      local $/; my $d = eval { decode_json(<$f>) } || {};
      @theirs = @{ ($d->{permissions} || {})->{deny} || [] } if ref $d eq "HASH";
    }
    my %seen; my @all = grep { !$seen{$_}++ } (@ours, @theirs);
    print JSON::PP->new->canonical->utf8->encode({ permissions => { deny => \@all } });
  '
}
agy_reply() {  # json-file reply-file -> prints "<status>[ denied:<actions>]" or "unparsed-json"; reply is the "response" field
  perl -MJSON::PP -e '
    local $/; my $raw = <STDIN>; my $d = eval { decode_json($raw) };
    unless (ref $d eq "HASH") { open my $o, ">", $ARGV[0] or die; close $o; print "unparsed-json (see log)"; exit 0 }
    open my $o, ">:encoding(UTF-8)", $ARGV[0] or die; print $o ($d->{response} // ""); close $o;
    my @den = map { $_->{action} // "?" } @{ $d->{denied_actions} || [] };
    print(($d->{status} // "?") . (@den ? " denied:" . join(",", @den) : ""));
  ' "$2" < "$1"
}
copilot_reply() {  # jsonl-file reply-file problem-file -> prints model
  perl -MJSON::PP -e '
    my ($rf, $pf) = @ARGV; my (@msgs, $picked, $tier, $err, $untrusted, $events);
    sub problem { open my $p, ">", $pf or die; print $p "$_[0]\n"; close $p }
    while (<STDIN>) { my $e = eval { decode_json($_) }; next unless ref $e eq "HASH"; $events++;
      my $d = ref $e->{data} eq "HASH" ? $e->{data} : {}; my $t = $e->{type} // "";
      push @msgs, $d if $t eq "assistant.message";
      ($picked, $tier) = ($d->{chosenModel}, $d->{autoTier}) if $t eq "session.auto_mode_resolved";
      $err = $d if $t eq "session.error";
      $untrusted = 1 if $t eq "session.warning" && ($d->{warningType} // "") eq "folder_not_trusted"; }
    my @f = grep { ($_->{phase} // "") eq "final_answer" } @msgs; @f = @msgs unless @f;
    open my $o, ">:encoding(UTF-8)", $rf or die;
    print $o $f[-1]{content} if @f && defined $f[-1]{content} && !ref $f[-1]{content}; close $o;
    # Only applied by run_member when the run failed or produced no reply.
    if (!$events) { problem("copilot unparsed-json (see log)") }
    elsif ($err) { my $why = $err->{errorType} // "unknown"; $why =~ s/[^\w. -]/_/g;
      problem($why eq "quota" ? "copilot quota exceeded" : "copilot error: $why");
      print STDERR "copilot session error: " . ($err->{message} // "") . "\n" }
    elsif ($untrusted) { problem("copilot folder not trusted (add it to trustedFolders in ~/.copilot/config.json)") }
    my $m = @f ? ($f[-1]{model} // "unknown") : "unknown";
    $m .= " (Fusion" . ($tier ? "/$tier" : "") . " picked $picked)" if $picked; print $m;
  ' "$2" "$3" < "$1"
}

# Signature of the working tree (tracked edits + untracked files + HEAD); used
# to detect edits made while native codex was reading the live tree.
tree_sig() {
  { git rev-parse HEAD; git status --porcelain --untracked-files=all; git diff HEAD
    git ls-files --others --exclude-standard -z | xargs -0 cksum 2>/dev/null; } 2>/dev/null | cksum
}

# Each wrapper records its pid in logs/<member>.pid. If this script is
# terminated, forward TERM to those wrappers (never to our own process group:
# a background job shares it with the shell that launched us); each wrapper
# then kills its member's process group.
cancel_all() {
  trap - TERM INT HUP
  local f pass
  : > "$SESSION/.cancelled"   # members that have not launched yet check this and stop
  for pass in 1 2; do          # second pass catches a wrapper that registered during the first
    for f in "$SESSION"/logs/*.pid; do [ -f "$f" ] && kill -TERM "$(cat "$f")" 2>/dev/null; done
    [ "$pass" = 1 ] && sleep 1
  done
  wait; echo "review-council: cancelled — $SESSION/status.md"; exit 143
}
trap cancel_all TERM INT HUP
with_timeout() {  # uses $WRAPPER_PIDFILE if set
  perl -e '
    my $t = shift;
    if ($ENV{WRAPPER_PIDFILE}) { if (open(my $fh, ">", $ENV{WRAPPER_PIDFILE})) { print $fh "$$\n"; close $fh } }
    my $pid = fork // die "fork: $!";
    if ($pid == 0) { setpgrp(0, 0); exec {$ARGV[0]} @ARGV or do { print STDERR "cannot exec $ARGV[0]: $!\n"; exit 127 } }
    $SIG{ALRM} = sub { kill TERM => -$pid; sleep 2; kill KILL => -$pid; exit 142 };
    $SIG{TERM} = $SIG{INT} = $SIG{HUP} = sub { kill TERM => -$pid; sleep 1; kill KILL => -$pid; exit 143 };
    alarm $t; waitpid $pid, 0;
    exit(($? & 127) ? 128 + ($? & 127) : $? >> 8);
  ' "$TIMEOUT" "$@"
}

run_member() {
  local m=$1
  local PF="$SESSION/prompts/$m.md" RF="$SESSION/replies/$m.md" LF="$SESSION/logs/$m.log"
  local PROBLEM="$SESSION/logs/$m.problem" problem=""
  local start rc status agy_status tree_before tree_changed=""
  start=$(date +%s)
  : > "$RF"; rm -f "$PROBLEM"
  if [ -e "$SESSION/.cancelled" ]; then
    printf '%s\tcancelled\t0s\tunknown\t%s\n' "$m" "$RF" >> "$SESSION/status.md"; return
  fi
  export WRAPPER_PIDFILE="$SESSION/logs/$m.pid"
  if [ ! -f "$PF" ]; then
    echo "review-fanout.sh: no prompt for $m at $PF" > "$LF"
    printf '%s\tno prompt\t0s\t%s\n' "$m" "$RF" >> "$SESSION/status.md"
    return
  fi
  case $m in
    codex)
      if [ "$CODEX_NATIVE" = 1 ]; then
        # Built-in reviewer (same engine as /codex:review). It refuses a custom
        # prompt alongside --uncommitted/--base, so the prompt file is NOT used
        # here; Codex picks the target from git and uses its own output format.
        # It reads the LIVE working tree while it runs, unlike the other members
        # who review the frozen packet; snapshot the tree before and after so a
        # change during the run is flagged rather than silently mixed in.
        local cm=(); [ -n "$CODEX_MODEL" ] && cm=(-c "model=\"$CODEX_MODEL\"")
        tree_before=$(tree_sig)
        if [ "$MODE" = uncommitted ]; then
          with_timeout codex review ${cm[@]+"${cm[@]}"} --uncommitted < /dev/null > "$RF" 2> "$LF"
        elif [ -z "$BASE_REF" ]; then
          echo "review-fanout.sh: CODEX_NATIVE=1 with MODE=$MODE needs BASE_REF in target.env" > "$LF"; false
        else
          with_timeout codex review ${cm[@]+"${cm[@]}"} --base "$BASE_REF" < /dev/null > "$RF" 2> "$LF"
        fi
        rc=$?; [ "$(tree_sig)" != "$tree_before" ] && tree_changed=1; (exit "$rc")
      else
        # Packet-only review (e.g. a PR that is not checked out here).
        local xm=(); [ -n "$CODEX_MODEL" ] && xm=(-m "$CODEX_MODEL")
        with_timeout codex exec ${xm[@]+"${xm[@]}"} --skip-git-repo-check -s read-only --color never -o "$RF" - < "$PF" > "$LF" 2>&1
      fi ;;
    claude)
      # Fresh process, no session memory. --restricted drops Bash/WebFetch and
      # ignores user/project settings; file tools are confined to cwd + session;
      # --strict-mcp-config with no --mcp-config attaches no MCP servers.
      # JSON output so the model id (modelUsage) comes from the CLI; the reply
      # text is extracted into $RF afterwards. --restricted does not ignore the
      # global config, where verbose=true turns the JSON into an event list, so
      # the single-result shape is pinned with --settings.
      local clm=(); [ -n "$CLAUDE_MODEL" ] && clm=(--model "$CLAUDE_MODEL")
      with_timeout claude -p ${clm[@]+"${clm[@]}"} --restricted --tools Read,Grep,Glob --strict-mcp-config \
        --settings '{"verbose":false}' --no-session-persistence --add-dir "$SESSION" --output-format json < "$PF" > "$LF.json" 2> "$LF" ;;
    copilot)
      # GitHub Copilot CLI, headless. --available-tools limits the model to
      # read-only file tools (this also drops the GitHub MCP tools, so nothing
      # reaches github.com); --no-ask-user prevents blocking prompts;
      # --no-custom-instructions keeps repo AGENTS.md files from steering it.
      # --model fusion lets Copilot's router pick the model per task (it may
      # pick Claude); pin COPILOT_MODEL=gpt-5.6-sol for guaranteed diversity.
      # The router refuses --reasoning-effort, so effort is only sent for a pin;
      # --auto-tier (the router's own profile) is only sent with the router.
      # Empty COPILOT_MODEL = the CLI's own default: no model, tier, or effort flags.
      local tuning=()
      case $COPILOT_MODEL in
        "") ;;
        fusion|auto) tuning=(--model "$COPILOT_MODEL" --auto-tier "$COPILOT_AUTO_TIER") ;;
        *) tuning=(--model "$COPILOT_MODEL" --reasoning-effort "$COPILOT_EFFORT") ;;
      esac
      # JSON output so the model id and Fusion's pick come from the CLI.
      with_timeout copilot -s --no-ask-user --no-custom-instructions --available-tools=view,grep,glob \
        ${tuning[@]+"${tuning[@]}"} --output-format json \
        --add-dir "$SESSION" -p "$(cat "$PF")" < /dev/null > "$LF.json" 2> "$LF" ;;
    antigravity)
      # Google Antigravity CLI. Read-only is enforced by session-only deny rules
      # (agy evaluates Deny > Ask > Allow, so a user's persisted allow rules
      # cannot re-enable commands or writes); --mode plan keeps the model in its
      # read-only investigation posture. Headless agy auto-denies anything that
      # would prompt and then returns an EMPTY response, so the prompt also tells
      # it not to attempt commands. The prompt must be attached to -p= (a bare
      # -p swallows the next flag). Do NOT add --disable-slash-commands: agy
      # warns it turns plan mode off. --effort only with a pinned family: it
      # conflicts with per-effort ids such as gemini-3.8-flash-high.
      local agm=(); [ -n "$AGY_MODEL" ] && agm=(--model "$AGY_MODEL" --effort "$AGY_EFFORT")
      # Session settings replace the persisted permissions arrays rather than
      # appending, so the user's own deny entries are merged in, not dropped.
      # agy accepts --settings "" silently, so never launch without the rules.
      local agy_deny
      if agy_deny=$(agy_deny_settings 2> "$LF") && [ -n "$agy_deny" ]; then
        with_timeout agy -p="$(cat "$PF")" --mode plan --output-format json ${agm[@]+"${agm[@]}"} \
          --settings "$agy_deny" --add-dir "$SESSION" < /dev/null > "$LF.json" 2>> "$LF"
      else
        echo "review-fanout.sh: could not build the antigravity deny settings; not launching" >> "$LF"; false
      fi ;;
    *)
      echo "review-fanout.sh: unknown member '$m'" > "$LF"; false ;;
  esac
  rc=$?
  # Model actually used, as reported by the CLI itself (not by the model).
  local model="unknown"
  case $m in
    codex)  model=$(sed -n 's/^model: *//p' "$LF" | head -1); model=${model:-unknown} ;;
    claude)  [ -s "$LF.json" ] && { model=$(claude_reply "$LF.json" "$RF" "$PROBLEM" 2>> "$LF") || { model="unknown"; echo "claude unparsed-json (see log)" > "$PROBLEM"; }; } ;;
    copilot) [ -s "$LF.json" ] && { model=$(copilot_reply "$LF.json" "$RF" "$PROBLEM" 2>> "$LF") || { model="unknown"; echo "copilot unparsed-json (see log)" > "$PROBLEM"; }; } ;;
    antigravity)
      # agy's JSON has no model field: report the pin, else the configured default.
      # agy ends the turn with an empty response when a tool is auto-denied, so
      # surface its status and any denied actions instead of a bare "empty reply".
      agy_status=""
      if [ -s "$LF.json" ]; then agy_status=$(agy_reply "$LF.json" "$RF" 2>> "$LF") || agy_status=""; fi
      if [ -n "$AGY_MODEL" ]; then model="$AGY_MODEL/$AGY_EFFORT (pinned)"
      else model=$(perl -MJSON::PP -e 'local $/; my $d=eval{decode_json(<STDIN>)}||{}; print $d->{model}//""' < "$HOME/.gemini/antigravity-cli/settings.json" 2>/dev/null); model="${model:-unknown} (agy default)"; fi ;;
  esac
  case "${agy_status:-}" in *denied:*) [ -s "$RF" ] && model="$model; ${agy_status#* }" ;; esac
  printf '%s\n' "$model" > "$SESSION/logs/$m.model"
  [ -s "$PROBLEM" ] && problem=$(cat "$PROBLEM")
  if [ "$rc" -eq 142 ]; then status="timeout after ${TIMEOUT}s"
  elif [ "$rc" -eq 143 ]; then status="cancelled"
  elif [ "$rc" -eq 127 ]; then status="could not start (see log)"
  elif [ "$rc" -ne 0 ]; then status="${problem:-exit $rc}"
  elif [ ! -s "$RF" ]; then
    # agy explains an empty reply in its own status/denied_actions; surface that.
    if [ "$m" = antigravity ] && [ -n "${agy_status:-}" ]; then status="agy $agy_status"; else status="${problem:-empty reply}"; fi
  else status="ok"; fi
  [ -n "$tree_changed" ] && status="$status (working tree changed during review)"
  rm -f "$WRAPPER_PIDFILE"
  printf '%s\t%s\t%ss\t%s\t%s\n' "$m" "$status" "$(( $(date +%s) - start ))" "$model" "$RF" >> "$SESSION/status.md"
}

for m in "$@"; do run_member "$m" & done
wait
echo "review-council: all members finished — $SESSION/status.md"
cat "$SESSION/status.md"
# Non-zero if no member produced a usable reply, so background runners notice.
grep -Eq $'\tok(\t| )' "$SESSION/status.md"
