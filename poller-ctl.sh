#!/usr/bin/env bash
# Always-live poller: reflects each space's position in its git branch stack as
# a metadata token in the herdr spaces sidebar, and keeps each stack contiguous
# in sidebar order. Never touches labels, never calls the network.
#
# Control: start | stop | toggle | ensure | status | poll-once | run
#
# Env:
#   GIT_STACK_REFRESH   poll interval seconds (default 3)
#   GIT_STACK_TTL_MS    token TTL in ms (default 9000)
#   GIT_STACK_DRYRUN    if set, print intended writes instead of applying them
#   GIT_STACK_STATE_DIR override the state directory (tests)
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/lib.sh"

# When herdr launches us it injects HERDR_PLUGIN_STATE_DIR. When a human runs
# this from a shell it is unset, and falling back to $DIR/.state would put state
# under the plugin root (which the design forbids) AND give the shell a different
# state dir from the running daemon — so `stop` would print "stopped" and do
# nothing. Fall back to the same XDG location herdr itself uses.
STATE_DIR="${GIT_STACK_STATE_DIR:-${HERDR_PLUGIN_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/herdr/plugins/git-stack}}"
PIDFILE="$STATE_DIR/poller.pid"
LOGFILE="$STATE_DIR/poller.log"
STOPFILE="$STATE_DIR/stopped"
INTERVAL="${GIT_STACK_REFRESH:-3}"
# A zero or non-numeric refresh would turn the loop into a hot spin hammering
# the herdr CLI every iteration.
case "$INTERVAL" in ''|*[!0-9]*|0) INTERVAL=3 ;; esac
DRYRUN="${GIT_STACK_DRYRUN:-}"
mkdir -p "$STATE_DIR" 2>/dev/null || true

gs_preflight() {
  local missing=""
  command -v git >/dev/null 2>&1 || missing="$missing git"
  command -v jq  >/dev/null 2>&1 || missing="$missing jq"
  command -v nc  >/dev/null 2>&1 || missing="$missing nc"
  if [ -n "$missing" ]; then
    printf 'git-stack: missing required commands:%s\n' "$missing" >&2
    return 1
  fi
  # BSD/OpenBSD netcat speaks -U; GNU nc.traditional does not.
  # `nc -h` itself exits 1 on BSD nc regardless of the grep match, and with
  # pipefail active that would fail this check even when -U is supported —
  # so nc's own exit status is discarded here, only grep's counts.
  if ! { nc -h 2>&1 || true; } | grep -q -- '-U'; then
    printf 'git-stack: this nc has no -U (unix socket) support; install BSD netcat or socat\n' >&2
    return 1
  fi
  return 0
}

# gs_stacks_for_repo <repo_root> <trunk> <ws_tsv_for_this_repo>
# Writes "<ws_id>\t<token>" to $STATE_DIR/tokens.txt and one stack per line
# ("<ws1> <ws2> ...", stack order) to $STATE_DIR/stacks.txt.
gs_stacks_for_repo() {
  local root="$1" trunk="$2" wsfile="$3"
  local map="$STATE_DIR/map.tsv" res="$STATE_DIR/infer.tsv" branches=""
  : > "$map"

  # "<branch>\t<ws_id>", first space wins if two spaces share a branch
  local id rk r path branch
  while IFS=$'\t' read -r id rk r path; do
    branch=$(gs_head_branch "$path") || continue
    awk -F'\t' -v b="$branch" '$1 == b { found = 1 } END { exit !found }' "$map" && continue
    printf '%s\t%s\n' "$branch" "$id" >> "$map"
  done < "$wsfile"

  branches=$(awk -F'\t' '{print $1}' "$map")
  [ -n "$branches" ] || return 0

  # shellcheck disable=SC2086
  gs_commit_lines "$root" "$trunk" $branches | awk -f "$DIR/infer.awk" > "$res"
  [ -s "$res" ] || return 0

  # tokens
  local b par pos size restack rootb tok wsid
  while IFS=$'\t' read -r b par pos size restack rootb; do
    tok=$(gs_token "$pos" "$size" "$restack") || continue
    wsid=$(awk -F'\t' -v b="$b" '$1 == b { print $2; exit }' "$map")
    [ -n "$wsid" ] && printf '%s\t%s\n' "$wsid" "$tok" >> "$STATE_DIR/tokens.txt"
  done < "$res"

  # stacks, ordered by position within each component. Sort first (root, then
  # position numerically, then branch name) so stacks.awk can accumulate in
  # read order instead of keying by (root, pos), which drops same-depth
  # siblings — see stacks.awk for why that matters.
  sort -t"$(printf '\t')" -k6,6 -k3,3n -k1,1 "$res" \
    | awk -f "$DIR/stacks.awk" "$map" - >> "$STATE_DIR/stacks.txt"
}

# Recompute structure and apply moves. Gated on the fingerprint by gs_run,
# because this is the expensive half.
gs_recompute() {
  local snap="$STATE_DIR/ws.tsv" repos="$STATE_DIR/repos.tsv"
  local orderf="$STATE_DIR/order.txt" perrepo="$STATE_DIR/repo-ws.tsv"

  gs_workspaces > "$snap" || return 0
  : > "$STATE_DIR/tokens.txt"
  : > "$STATE_DIR/stacks.txt"

  awk -F'\t' '{ print $2 "\t" $3 }' "$snap" | sort -u > "$repos"

  local rk root trunk
  while IFS=$'\t' read -r rk root; do
    [ -n "$root" ] || continue
    trunk=$(gs_trunk "$root") || continue
    awk -F'\t' -v k="$rk" '$2 == k' "$snap" > "$perrepo"
    gs_stacks_for_repo "$root" "$trunk" "$perrepo"
  done < "$repos"

  # Moves.
  [ -s "$STATE_DIR/stacks.txt" ] || return 0
  gs_order > "$orderf"
  local anchor ids line
  awk -f "$DIR/plan_moves.awk" "$STATE_DIR/stacks.txt" "$orderf" | while IFS= read -r line; do
    anchor="${line%% *}"
    ids="${line#* }"
    if [ -n "$DRYRUN" ]; then
      printf 'move %s %s\n' "$anchor" "$ids"
    else
      # shellcheck disable=SC2086
      gs_move_block "$anchor" $ids >/dev/null
    fi
  done
}

# Publish the cached tokens. Runs EVERY tick, not only on change: tokens carry
# a TTL, so herdr expires them a few seconds after the last write. Re-reporting
# the same value refreshes the TTL and keeps the sidebar populated while the
# repo is quiet. The TTL then does its real job — clearing tokens when the
# daemon dies.
#
# seq is epoch seconds, not a per-start counter: herdr ignores a report whose
# seq is less than or equal to the last one accepted for this source, so a
# counter restarting at 0 would have every write after a daemon restart
# silently dropped.
gs_publish() {
  local seq="${1:-$(date +%s)}"
  local snap="$STATE_DIR/ws.tsv" wsid tok rk root path
  [ -f "$snap" ] || return 0

  while IFS=$'\t' read -r wsid tok; do
    if [ -n "$DRYRUN" ]; then
      printf 'token %s %s\n' "$wsid" "$tok"
    else
      gs_set_token "$wsid" "$tok" "$seq"
    fi
  done < "$STATE_DIR/tokens.txt"

  while IFS=$'\t' read -r wsid rk root path; do
    awk -F'\t' -v w="$wsid" '$1 == w { found = 1 } END { exit !found }' \
      "$STATE_DIR/tokens.txt" && continue
    if [ -n "$DRYRUN" ]; then
      printf 'clear %s\n' "$wsid"
    else
      gs_clear_token "$wsid" "$seq"
    fi
  done < "$snap"
}

# Fingerprint: cheap enough to run every tick, so inference only runs on change.
# Deliberately calls gs_workspaces a second time when gs_recompute also runs
# (it refreshes $STATE_DIR/ws.tsv there too): the fingerprint must be known
# before deciding whether to recompute, and ws.tsv has to be current on every
# tick regardless, since gs_publish's stale-token clearing pass reads it. Not
# an oversight to be "optimized" into one call.
#
# Deliberately sensitive to the LINE ORDER of gs_workspaces' snapshot, not
# just its contents (the per-workspace loop below is printed in snapshot
# order, unsorted). That is what makes "a manual drag is undone on the next
# tick" true: dragging a workspace changes nothing about its branch or
# commits, but it does change this snapshot's line order, so the fingerprint
# string changes, gs_recompute runs, and its move planning puts the stack
# back. Sorting these lines "for stability" would make a drag invisible to
# the fingerprint and silently kill that behavior.
gs_fingerprint() {
  local snap="$STATE_DIR/ws.tsv" id rk root path branch
  gs_workspaces > "$snap" 2>/dev/null || return 0
  while IFS=$'\t' read -r id rk root path; do
    branch=$(gs_head_branch "$path") || branch="-"
    printf '%s %s %s\n' "$id" "$rk" "$branch"
  done < "$snap"
  awk -F'\t' '{ print $3 }' "$snap" | sort -u | while IFS= read -r root; do
    git -C "$root" for-each-ref --format='%(refname:short) %(objectname)' refs/heads 2>/dev/null
  done
}

gs_run() {
  local last="" now
  while :; do
    now=$(gs_fingerprint)
    if [ "$now" != "$last" ]; then
      gs_recompute
      last="$now"
    fi
    # Always republish: the TTL would otherwise blank the sidebar while idle.
    gs_publish "$(date +%s)"
    sleep "$INTERVAL"
  done
}

gs_running() {
  [ -f "$PIDFILE" ] || return 1
  local pid
  pid=$(<"$PIDFILE")
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  # PIDs are recycled, and other herdr plugins ship a script with this same
  # basename — the CI-status plugin's poller is literally called poller-ctl.sh.
  # Match this plugin's absolute path so we can never report, or signal,
  # someone else's process.
  ps -p "$pid" -o command= 2>/dev/null | grep -qF "$DIR/poller-ctl.sh run" || return 1
  return 0
}

case "${1:-}" in
  run)
    gs_preflight || exit 1
    gs_run
    ;;
  start)
    gs_preflight || exit 1
    rm -f "$STOPFILE"
    if gs_running; then echo running; exit 0; fi
    nohup "$DIR/poller-ctl.sh" run < /dev/null >> "$LOGFILE" 2>&1 &
    echo $! > "$PIDFILE"
    echo started
    ;;
  stop)
    touch "$STOPFILE"
    if gs_running; then kill "$(<"$PIDFILE")" 2>/dev/null; fi
    rm -f "$PIDFILE"
    echo stopped
    ;;
  toggle)
    if gs_running; then "$DIR/poller-ctl.sh" stop; else "$DIR/poller-ctl.sh" start; fi
    ;;
  ensure)
    # Respect a deliberate stop; otherwise bring the daemon back.
    [ -f "$STOPFILE" ] && { echo stopped; exit 0; }
    gs_running && { echo running; exit 0; }
    "$DIR/poller-ctl.sh" start
    ;;
  status)
    gs_preflight || exit 1
    if gs_running; then echo running; else echo stopped; fi
    ;;
  poll-once)
    gs_preflight || exit 1
    gs_recompute
    gs_publish "$(date +%s)"
    ;;
  *)
    echo "usage: $0 {start|stop|toggle|ensure|status|poll-once|run}" >&2
    exit 2
    ;;
esac
