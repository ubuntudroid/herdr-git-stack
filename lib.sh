#!/usr/bin/env bash
# Shared helpers for the git-stack herdr plugin.
# bash 3.2 compatible: no associative arrays, no mapfile.

GS_SOURCE="git-stack"

# herdr renders a token only if the user's ui.sidebar.spaces.rows asks for it by
# name, and every plugin's tokens share ONE name space. Ours are prefixed
# "gstk_" so they cannot collide with another plugin's — or with the bare
# `stack`/`stack_tail`/`stack_bar_*` names this plugin published before 0.3.0.
# GIT_STACK_TOKEN_PREFIX overrides the prefix; set it empty for those bare
# names. Whatever it is must be mirrored in rows.
GS_TOKEN_PREFIX="${GIT_STACK_TOKEN_PREFIX-gstk_}"
GS_TOKEN_NAME="${GS_TOKEN_PREFIX}stack"
GS_BAR_TOKEN_PREFIX="${GS_TOKEN_PREFIX}stack_bar_"
GS_TAIL_TOKEN_NAME="${GS_TOKEN_PREFIX}stack_tail"
GS_GLYPH_RESTACK="󱓎"
GS_GLYPH_BAR="│"
GS_CONFIG_DIR="${GIT_STACK_CONFIG_DIR:-${HERDR_PLUGIN_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr/plugins/config/ubuntudroid.git-stack}}"

# A space occupies several sidebar rows, so the bracket is drawn by a token per
# row: `gstk_stack` heads the first, `gstk_stack_tail` closes the last, and an
# optional `gstk_stack_bar_<name>` carries the line through each row between.
# Together they turn what used to be one glyph per space into a single unbroken
# line running down the whole stack, opening above the root and closing below
# the deepest member.
#
# The middle bars are opt-in, and each one is CONDITIONAL, because a bar on a
# row whose other tokens are all empty would make that row appear -- herdr draws
# a row when any one of its tokens resolves, so an unconditional bar turns every
# otherwise-blank middle row into a bare `│`. Each bar therefore names the
# tokens that fill its row, and is published only for spaces that carry one.
# See gs_bar_groups for the file that declares them.

# gs_token <pos> <size> <restack 0|1>
# The head: bracket glyph plus position, for the space's FIRST sidebar row.
# `└` is deliberately absent here -- it belongs to gs_token_tail, because the
# bracket closes below the deepest branch's last row, not beside its first.
# Returns 1 with no output for a single-node stack, which must never be
# rendered.
gs_token() {
  local pos="$1" size="$2" restack="$3" glyph
  [ "$size" -ge 2 ] || return 1
  if [ "$pos" -eq 1 ]; then
    glyph='┌'
  else
    glyph='├'
  fi
  if [ "$restack" = "1" ]; then
    printf '%s%s/%s %s\n' "$glyph" "$pos" "$size" "$GS_GLYPH_RESTACK"
  else
    printf '%s%s/%s\n' "$glyph" "$pos" "$size"
  fi
}

# gs_token_tail <size> <closes 0|1>
# The tail: the connector for the space's LAST sidebar row. Every member
# continues the line with `│`; the one member that closes it gets `└`. Same
# single-node contract as gs_token.
#
# `closes` is decided by SIDEBAR ORDER, not by depth. In a branching stack two
# members can share the deepest position, and closing on depth would then draw
# `└` twice, mid-block, with the line carrying on underneath it. The caller
# passes 1 for whichever member the move planner puts last.
gs_token_tail() {
  local size="$1" closes="$2"
  [ "$size" -ge 2 ] || return 1
  if [ "$closes" = "1" ]; then
    printf '└\n'
  else
    printf '%s\n' "$GS_GLYPH_BAR"
  fi
}

# gs_trunk <repo_root>
# The branch stacks are measured against. Prints the ref name; returns 1 when
# the repo has no recognizable trunk, in which case the repo is skipped.
gs_trunk() {
  local root="$1" t
  t=$(git -C "$root" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)
  if [ -n "$t" ]; then
    printf '%s\n' "$t"
    return 0
  fi
  for t in origin/main origin/master main master develop trunk; do
    if git -C "$root" rev-parse --verify --quiet "$t^{commit}" >/dev/null 2>&1; then
      printf '%s\n' "$t"
      return 0
    fi
  done
  return 1
}

# gs_trunk_local <trunk>
# The local branch name behind a trunk ref: "origin/main" -> "main",
# "main" -> "main". A space sitting on the trunk is not a stack member. Without
# this, a trunk that is momentarily identical to a feature branch — a
# fast-forward merge, in the seconds before the push lands — has the same depth
# and the same commits as that branch, so the equal-depth tie-break makes one
# the parent of the other and a phantom two-branch stack appears.
#
# By name, never by tip: at the moment that happens the local trunk is AHEAD of
# the remote trunk it is measured against, so comparing tips would not catch it.
gs_trunk_local() {
  case "$1" in
    */*) printf '%s\n' "${1#*/}" ;;
    *)   printf '%s\n' "$1" ;;
  esac
}

# gs_gitdir <checkout_path>
# A linked worktree's .git is a FILE containing "gitdir: <path>", not a
# directory, so HEAD does not live at <checkout>/.git/HEAD.
gs_gitdir() {
  local p="$1" line
  if [ -d "$p/.git" ]; then
    printf '%s\n' "$p/.git"
  elif [ -f "$p/.git" ]; then
    line=$(<"$p/.git")
    case "$line" in
      "gitdir: "*) line="${line#gitdir: }" ;;
      *) return 1 ;;
    esac
    [ -n "$line" ] || return 1
    printf '%s\n' "$line"
  else
    return 1
  fi
}

# gs_head_branch <checkout_path>
# Reads HEAD directly: $(<file) is a bash builtin, so a poll tick costs no
# forks for this. Returns 1 for a detached HEAD.
gs_head_branch() {
  local gd head
  gd=$(gs_gitdir "$1") || return 1
  [ -f "$gd/HEAD" ] || return 1
  head=$(<"$gd/HEAD")
  case "$head" in
    "ref: refs/heads/"*) printf '%s\n' "${head#ref: refs/heads/}" ;;
    *) return 1 ;;
  esac
}

# gs_commit_lines <repo_root> <trunk> <branch>...
# One "<branch>\t<commit>" line per commit in trunk..branch. One git process
# per branch; branch names are passed through awk -v, never interpolated into
# a sed or shell expression.
gs_commit_lines() {
  local root="$1" trunk="$2" b
  shift 2
  for b in "$@"; do
    git -C "$root" rev-list "$trunk..$b" 2>/dev/null \
      | awk -v b="$b" '{ print b "\t" $0 }'
  done
}

GS_TTL_MS="${GIT_STACK_TTL_MS:-9000}"
GS_HERDR="${HERDR_BIN_PATH:-herdr}"

# gs_socket <method> <params_json>
# The socket API has no CLI wrapper for workspace.move_block. Transport is
# newline-delimited JSON and the server closes the connection after replying,
# so plain `nc -U` terminates on its own.
# Return 0 means only "a reply arrived" — a JSON-RPC error response is a
# valid non-empty reply and still returns 0. Callers must inspect the body.
gs_socket() {
  local sock="${HERDR_SOCKET_PATH:-$HOME/.config/herdr/herdr.sock}" out
  [ -S "$sock" ] || return 1
  out=$(printf '{"id":"gs","method":"%s","params":%s}\n' "$1" "$2" | nc -U -w 5 "$sock" 2>/dev/null)
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

# gs_workspaces -> "<ws_id>\t<repo_key>\t<repo_root>\t<checkout_path>"
# Only spaces with worktree provenance; a space with no repo cannot be stacked.
gs_workspaces() {
  "$GS_HERDR" workspace list 2>/dev/null | jq -r '
    (.result.workspaces // .workspaces)[]
    | select(.worktree != null)
    | [.workspace_id, .worktree.repo_key, .worktree.repo_root, .worktree.checkout_path]
    | @tsv'
}

# gs_order -> current sidebar order, one workspace id per line
gs_order() {
  "$GS_HERDR" workspace list 2>/dev/null | jq -r '
    (.result.workspaces // .workspaces)[] | .workspace_id'
}

# gs_bar_groups
# One line per configured middle-row connector, as "<name>\t<trigger tokens>".
# Read from $GS_CONFIG_DIR/bars.conf, whose format is one
#
#     <name>: <metadata token name>...
#
# per line, or `<name>: always` for a row that is never empty. Blank lines and
# `#` comments are ignored, and a name outside [A-Za-z0-9_] is skipped rather
# than pasted into a token name. Prints nothing when the file is absent, which
# is the two-row default: no bars, nothing published, nothing to configure.
gs_bar_groups() {
  local f="$GS_CONFIG_DIR/bars.conf" line name rest
  [ -f "$f" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    case "$line" in *:*) ;; *) continue ;; esac
    name="${line%%:*}"; rest="${line#*:}"
    name="$(printf '%s' "$name" | tr -d '[:space:]')"
    case "$name" in ''|*[!A-Za-z0-9_]*) continue ;; esac
    rest="$(printf '%s' "$rest" | tr -s '[:space:]' ' ')"
    rest="${rest# }"; rest="${rest% }"
    [ -n "$rest" ] || continue
    printf '%s\t%s\n' "$name" "$rest"
  done < "$f"
}

# gs_bar_args <present token names, space separated>
# The --token/--clear-token pairs for every configured bar, given the tokens a
# space already carries. Cleared rather than omitted when a trigger is absent:
# a space that stops being, say, a Coder space would otherwise keep its bar for
# the rest of the TTL.
gs_bar_args() {
  local present=" $1 " name triggers t hit
  while IFS=$'\t' read -r name triggers; do
    hit=0
    if [ "$triggers" = "always" ]; then
      hit=1
    else
      for t in $triggers; do
        case "$present" in *" $t "*) hit=1; break ;; esac
      done
    fi
    if [ "$hit" = 1 ]; then
      printf '%s\n%s\n' '--token' "$GS_BAR_TOKEN_PREFIX$name=$GS_GLYPH_BAR"
    else
      printf '%s\n%s\n' '--clear-token' "$GS_BAR_TOKEN_PREFIX$name"
    fi
  done
}

# gs_ws_tokens -> "<ws_id>\t<name> <name> ..." for spaces carrying metadata
# tokens. Non-empty values only: herdr drops an empty one on the way in, but a
# listing read mid-write should not be trusted to have done so.
gs_ws_tokens() {
  "$GS_HERDR" workspace list 2>/dev/null | jq -r '
    (.result.workspaces // .workspaces)[]
    | select((.tokens // {}) | length > 0)
    | [.workspace_id,
       (.tokens | to_entries | map(select(.value != "") | .key) | join(" "))]
    | @tsv'
}

# gs_set_token <ws_id> <head> <tail> <seq> [extra report-metadata args...]
# Every part of the bracket goes in one report: a space that showed a head with
# no tail for even one tick would draw a line that stops in mid-air.
# TTL means a dead daemon's tokens disappear on their own within a few ticks.
gs_set_token() {
  local ws="$1" head="$2" tail="$3" seq="$4"
  shift 4
  "$GS_HERDR" workspace report-metadata "$ws" \
    --source "$GS_SOURCE" \
    --token "$GS_TOKEN_NAME=$head" \
    --token "$GS_TAIL_TOKEN_NAME=$tail" \
    "$@" \
    --seq "$seq" \
    --ttl-ms "$GS_TTL_MS" >/dev/null 2>&1
}

# gs_clear_token <ws_id> <seq>
gs_clear_token() {
  local name triggers
  local -a extra=()
  while IFS=$'\t' read -r name triggers; do
    extra+=(--clear-token "$GS_BAR_TOKEN_PREFIX$name")
  done < <(gs_bar_groups)
  "$GS_HERDR" workspace report-metadata "$1" \
    --source "$GS_SOURCE" \
    --clear-token "$GS_TOKEN_NAME" \
    --clear-token "$GS_TAIL_TOKEN_NAME" \
    "${extra[@]+"${extra[@]}"}" \
    --seq "$2" >/dev/null 2>&1
}

# gs_move_block <anchor|-> <ws_id>...
gs_move_block() {
  local anchor="$1" ids params
  [ "$#" -ge 2 ] || return 1     # anchor plus at least one id
  shift
  ids=$(printf '%s\n' "$@" | jq -R . | jq -s -c .)
  if [ "$anchor" = "-" ]; then
    params=$(jq -n -c --argjson ids "$ids" '{workspace_ids: $ids}')
  else
    params=$(jq -n -c --argjson ids "$ids" --arg a "$anchor" \
      '{workspace_ids: $ids, before_workspace_id: $a}')
  fi
  gs_socket workspace.move_block "$params"
}

GS_PATCHID_MAX="${GIT_STACK_PATCHID_MAX:-100}"

# gs_patch_lines <repo_root> <trunk> <branch>...
# "<branch>\t<patchid>" per commit in trunk..branch. Patch ids survive a rebase,
# which commit ids do not, so this is what still finds a parent that was rebased
# out from under its child. Branches with more than GS_PATCHID_MAX commits beyond
# trunk are skipped: computing patch ids means diffing every commit, and a branch
# that long is not a stack member in practice.
gs_patch_lines() {
  local root="$1" trunk="$2" b n
  shift 2
  for b in "$@"; do
    n=$(git -C "$root" rev-list --count "$trunk..$b" 2>/dev/null) || continue
    case "$n" in ''|*[!0-9]*) continue ;; esac
    [ "$n" -gt 0 ] || continue
    [ "$n" -le "$GS_PATCHID_MAX" ] || continue
    git -C "$root" log --format='commit %H' -p --no-color "$trunk..$b" 2>/dev/null \
      | git patch-id --stable 2>/dev/null \
      | awk -v b="$b" 'NF { print b "\t" $1 }'
  done
}

# gs_birth_lines <repo_root> <branch>...
# "<branch>\t<unixtime>" from the oldest surviving reflog entry, which is when
# the branch was created. Two branches holding the same commit set carry no
# ancestry evidence in the graph at all, so infer.awk breaks that tie by birth:
# the branch created later is the child. Birth survives a restack — that rewrites
# commits, never the ref's first reflog entry. A pruned or absent reflog emits
# nothing and the tie falls back to branch name, as before.
gs_birth_lines() {
  local root="$1" b
  shift
  for b in "$@"; do
    git -C "$root" reflog show --date=unix "$b" 2>/dev/null | tail -1 \
      | awk -v b="$b" 'match($0, /@\{[0-9]+\}/) \
          { print b "\t" substr($0, RSTART + 2, RLENGTH - 3) }'
  done
}

# gs_behind_upstreams <repo_root>
# "<branch>\t<upstream>" for every local branch strictly behind its upstream.
#
# A branch whose local ref is behind the ref it tracks is the wrong thing to
# measure a stack from: a stacking tool that rebases and force-pushes cannot move
# a local ref that is checked out in a linked worktree, so the branch keeps
# pointing at its pre-rebase commit. That commit shares no commit id with the
# rebased stack, and a rebase that also resolved a conflict changes the diff, so
# it shares no patch id either — the branch drops out of its stack entirely.
# Measuring the upstream instead puts it back.
#
# trackshort is "<" (behind) or "<>" (diverged); both mean the local ref is
# missing commits the upstream has. ">" (ahead only) and "=" are left alone, as
# are branches with no upstream. Reads %(upstream), never a hardcoded "origin/",
# so a fork or a second remote resolves correctly. One git process per repo.
gs_behind_upstreams() {
  # %09, not \t: for-each-ref emits a backslash-t literally, which would put the
  # whole line in $1 and silently match nothing.
  git -C "$1" for-each-ref \
      --format='%(refname:short)%09%(upstream:short)%09%(upstream:trackshort)' \
      refs/heads 2>/dev/null \
    | awk -F'\t' '$2 != "" && ($3 == "<" || $3 == "<>") { print $1 "\t" $2 }'
}

# gs_fork_edges <repo_root> <trunk> <orphan_file> <branch>...
# "<child>\t<parent>" for orphans whose parent can still be identified through the
# reflog. This is the only tier that survives a rebase which ALSO resolved
# conflicts, because that changes the diff and so defeats patch ids too.
#
# Each edge is proved twice before it is emitted: `--fork-point` returns a commit
# that was a former tip of the candidate, and it must also be an ancestor of the
# child. Two independent constraints have to agree, which is why this cannot
# fabricate a relationship the way matching on commit subjects can. A fork point
# that is merely on trunk is not a stack edge and is discarded.
gs_fork_edges() {
  local root="$1" trunk="$2" orphans="$3" child cand fp best bestd d
  shift 3
  [ -s "$orphans" ] || return 0
  while IFS= read -r child; do
    [ -n "$child" ] || continue
    best=""; bestd=0
    for cand in "$@"; do
      [ "$cand" != "$child" ] || continue
      fp=$(git -C "$root" merge-base --fork-point "$cand" "$child" 2>/dev/null) || continue
      [ -n "$fp" ] || continue
      git -C "$root" merge-base --is-ancestor "$fp" "$child" 2>/dev/null || continue
      d=$(git -C "$root" rev-list --count "$trunk..$fp" 2>/dev/null) || continue
      case "$d" in ''|*[!0-9]*) continue ;; esac
      [ "$d" -gt "$bestd" ] && { best="$cand"; bestd="$d"; }
    done
    [ -n "$best" ] && printf '%s\t%s\n' "$child" "$best"
  done < "$orphans"
}
