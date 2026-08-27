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
gs_socket() {
  local sock="${HERDR_SOCKET_PATH:-$HOME/.config/herdr/herdr.sock}" out
  [ -S "$sock" ] || return 1
  out=$(printf '{"id":"gs","method":"%s","params":%s}\n' "$1" "$2" | nc -U "$sock" 2>/dev/null)
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
