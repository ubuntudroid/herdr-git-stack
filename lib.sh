#!/usr/bin/env bash
# Shared helpers for the git-stack herdr plugin.
# bash 3.2 compatible: no associative arrays, no mapfile.

GS_SOURCE="git-stack"
GS_TOKEN_NAME="stack"
GS_GLYPH_RESTACK="󱓎"

# gs_token <pos> <size> <restack 0|1>
# Prints the sidebar token. Returns 1 with no output for a single-node stack,
# which must never be rendered.
gs_token() {
  local pos="$1" size="$2" restack="$3" glyph
  [ "$size" -ge 2 ] || return 1
  if [ "$pos" -eq 1 ]; then
    glyph='┌'
  elif [ "$pos" -eq "$size" ]; then
    glyph='└'
  else
    glyph='├'
  fi
  if [ "$restack" = "1" ]; then
    printf '%s%s/%s %s\n' "$glyph" "$pos" "$size" "$GS_GLYPH_RESTACK"
  else
    printf '%s%s/%s\n' "$glyph" "$pos" "$size"
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

# gs_set_token <ws_id> <value> <seq>
# TTL means a dead daemon's tokens disappear on their own within a few ticks.
gs_set_token() {
  "$GS_HERDR" workspace report-metadata "$1" \
    --source "$GS_SOURCE" \
    --token "$GS_TOKEN_NAME=$2" \
    --seq "$3" \
    --ttl-ms "$GS_TTL_MS" >/dev/null 2>&1
}

# gs_clear_token <ws_id> <seq>
gs_clear_token() {
  "$GS_HERDR" workspace report-metadata "$1" \
    --source "$GS_SOURCE" \
    --clear-token "$GS_TOKEN_NAME" \
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
