#!/usr/bin/env bash
# Test suite for the git-stack plugin. No framework: plain asserts.
# Usage: ./test.sh            run everything
#        ./test.sh token      run one group
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/lib.sh"

GS_T_PASS=0
GS_T_FAIL=0

# gs_assert <description> <expected> <actual>
gs_assert() {
  if [ "$2" = "$3" ]; then
    GS_T_PASS=$((GS_T_PASS + 1))
  else
    GS_T_FAIL=$((GS_T_FAIL + 1))
    printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3" >&2
  fi
}

gs_summary() {
  if [ $((GS_T_PASS + GS_T_FAIL)) -eq 0 ]; then
    printf 'no tests ran for group: %s\n' "$GROUP" >&2
    return 2
  fi
  printf '%s passed, %s failed\n' "$GS_T_PASS" "$GS_T_FAIL"
  [ "$GS_T_FAIL" -eq 0 ]
}

test_token() {
  gs_assert 'root of 3'        '┌1/3'    "$(gs_token 1 3 0)"
  gs_assert 'middle of 3'      '├2/3'    "$(gs_token 2 3 0)"
  gs_assert 'leaf of 3'        '└3/3'    "$(gs_token 3 3 0)"
  gs_assert 'leaf needs restack' '└3/3 󱓎' "$(gs_token 3 3 1)"
  gs_assert 'middle needs restack' '├2/3 󱓎' "$(gs_token 2 3 1)"
  gs_assert 'root of 2'        '┌1/2'    "$(gs_token 1 2 0)"
  gs_assert 'leaf of 2'        '└2/2'    "$(gs_token 2 2 0)"
  # a single-node stack is never rendered
  gs_assert 'size 1 is empty'  ''        "$(gs_token 1 1 0)"
  gs_token 1 1 0 >/dev/null 2>&1
  gs_assert 'size 1 returns 1' '1'       "$?"
  gs_assert 'unknown group exits 2' '2' \
    "$("$DIR/test.sh" definitely-not-a-group >/dev/null 2>&1; echo $?)"
}

# Emits "<branch>\t<commit>" lines from a compact spec: "branch:c1,c2,c3"
gs_t_commits() {
  local spec b list c
  for spec in "$@"; do
    b="${spec%%:*}"; list="${spec#*:}"
    if [ "$list" = "$spec" ] || [ -z "$list" ]; then continue; fi
    printf '%s\n' "$list" | tr ',' '\n' | while IFS= read -r c; do
      [ -n "$c" ] && printf '%s\t%s\n' "$b" "$c"
    done
  done
}

gs_t_infer() { gs_t_commits "$@" | awk -f "$DIR/infer.awk" | sort | tr '\t' ' '; }

# Every fixture git call runs with global and system config neutralized: a
# developer's commit.gpgsign or core.hooksPath would otherwise break these
# commits, and this suite ships to machines we do not control. Per-command
# env, so nothing leaks to other test groups (Task 5's herdr group reads
# $HOME/.config/herdr).
gs_t_git() {
  if [ -z "${GS_T_HOME:-}" ]; then
    printf 'gs_t_git: GS_T_HOME is unset — fixture isolation would be bypassed\n' >&2
    return 1
  fi
  HOME="$GS_T_HOME" \
  GIT_CONFIG_NOSYSTEM=1 \
  GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t \
  GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
  git "$@"
}

test_infer() {
  # healthy chain: a=[a1] b=[a1,b1,b2] c=[a1,b1,b2,c1]
  gs_assert 'linear stack' \
'feat-a - 1 3 0 feat-a
feat-b feat-a 2 3 0 feat-a
feat-c feat-b 3 3 0 feat-a' \
    "$(gs_t_infer 'feat-a:a1' 'feat-b:a1,b1,b2' 'feat-c:a1,b1,b2,c1')"

  # parent advanced by one commit -> equal depth, edge survives on name order,
  # child is flagged because b3 is missing from the child
  gs_assert 'advanced parent flags child' \
'feat-a - 1 3 0 feat-a
feat-b feat-a 2 3 0 feat-a
feat-c feat-b 3 3 1 feat-a' \
    "$(gs_t_infer 'feat-a:a1' 'feat-b:a1,b1,b2,b3' 'feat-c:a1,b1,b2,c1')"

  # parent fully rebased: shares only a1 with the child, but is still the
  # deepest candidate, so the edge holds and the child is flagged
  gs_assert 'rebased parent flags child' \
'feat-a - 1 3 0 feat-a
feat-b feat-a 2 3 0 feat-a
feat-c feat-b 3 3 1 feat-a' \
    "$(gs_t_infer 'feat-a:a1,a2' 'feat-b:a1,a2,b1p,b2p' 'feat-c:a1,b1,b2,c1')"

  # branching stack: both children attach to feat-a
  gs_assert 'branching stack' \
'feat-a - 1 3 0 feat-a
feat-b feat-a 2 3 0 feat-a
feat-c feat-b 3 3 0 feat-a
feat-d feat-a 2 3 0 feat-a' \
    "$(gs_t_infer 'feat-a:a1' 'feat-b:a1,b1,b2' 'feat-c:a1,b1,b2,c1' 'feat-d:a1,d1')"

  # a lone branch off trunk shares nothing, so it forms no stack and is omitted
  gs_assert 'single-node stack omitted' \
'feat-a - 1 2 0 feat-a
feat-b feat-a 2 2 0 feat-a' \
    "$(gs_t_infer 'feat-a:a1' 'feat-b:a1,b1' 'solo:s1')"

  # a branch with no commits beyond trunk produces no input lines at all
  gs_assert 'depth zero omitted' \
'feat-a - 1 2 0 feat-a
feat-b feat-a 2 2 0 feat-a' \
    "$(gs_t_infer 'feat-a:a1' 'feat-b:a1,b1' 'atmain:')"

  # two independent stacks in one repo keep separate roots and counters
  gs_assert 'two stacks' \
'x1 - 1 2 0 x1
x2 x1 2 2 0 x1
y1 - 1 3 0 y1
y2 y1 2 3 0 y1
y3 y2 3 3 0 y1' \
    "$(gs_t_infer 'x1:xa' 'x2:xa,xb' 'y1:ya' 'y2:ya,yb' 'y3:ya,yb,yc')"

  gs_assert 'empty input' '' "$(printf '' | awk -f "$DIR/infer.awk")"
}

# Builds a fixture repo with a 3-branch stack, each branch in a linked worktree.
# Prints the repo root. Caller removes the parent dir.
gs_t_fixture() {
  local base="$1" r="$1/repo"
  gs_t_git init -q -b main "$r"
  ( cd "$r"
    gs_t_c() {
      echo "$1" > "$1.txt"
      gs_t_git add -A || { echo "add failed for $1" >&2; return 1; }
      gs_t_git commit -qm "$1" || { echo "commit failed for $1" >&2; return 1; }
    }
    gs_t_c m1 || return 1
    gs_t_git checkout -qb feat-a || return 1; gs_t_c a1 || return 1
    gs_t_git checkout -qb feat-b || return 1; gs_t_c b1 || return 1
    gs_t_git checkout -qb feat-c || return 1; gs_t_c c1 || return 1
    gs_t_git checkout -q main || return 1
    gs_t_git worktree add -q "$base/wt-a" feat-a || return 1
    gs_t_git worktree add -q "$base/wt-b" feat-b || return 1
    gs_t_git worktree add -q "$base/wt-c" feat-c || return 1
  ) || return 1
  printf '%s\n' "$r"
}

test_git() {
  local base r
  base="$(mktemp -d)"
  # Canonicalize base to match what git stores in .git files (with /private symlink resolved)
  base=$(readlink -f "$base")
  GS_T_HOME="$base"
  r="$(gs_t_fixture "$base")" || { gs_assert 'fixture built' 'yes' 'no'; rm -rf "$base"; return 1; }

  gs_assert 'trunk resolves to main' 'main' "$(gs_trunk "$r")"

  # the main checkout has a .git directory
  gs_assert 'gitdir of main checkout' "$r/.git" "$(gs_gitdir "$r")"
  # a linked worktree has a .git file pointing elsewhere
  gs_assert 'gitdir of linked worktree' "$r/.git/worktrees/wt-b" \
    "$(gs_gitdir "$base/wt-b")"

  gs_assert 'branch of linked worktree' 'feat-b' "$(gs_head_branch "$base/wt-b")"
  gs_assert 'branch of main checkout'   'main'   "$(gs_head_branch "$r")"

  # detached HEAD reports no branch
  ( cd "$base/wt-a" && gs_t_git checkout -q --detach >/dev/null 2>&1 )
  gs_head_branch "$base/wt-a" >/dev/null 2>&1
  gs_assert 'detached HEAD returns 1' '1' "$?"
  ( cd "$base/wt-a" && gs_t_git checkout -q feat-a >/dev/null 2>&1 )

  gs_assert 'not a checkout returns 1' '1' \
    "$(gs_gitdir "$base/nope" >/dev/null 2>&1; echo $?)"

  # malformed .git file: not a gitdir line
  mkdir -p "$base/bad1"
  printf 'not-a-gitdir-line\n' > "$base/bad1/.git"
  gs_gitdir "$base/bad1" >/dev/null 2>&1
  gs_assert 'malformed .git (no prefix) returns 1' '1' "$?"

  # malformed .git file: gitdir prefix but empty path
  mkdir -p "$base/bad2"
  printf 'gitdir: ' > "$base/bad2/.git"
  gs_gitdir "$base/bad2" >/dev/null 2>&1
  gs_assert 'malformed .git (empty path) returns 1' '1' "$?"

  # end to end: commit lines through inference
  gs_assert 'fixture infers a 3-stack' \
'feat-a - 1 3 0 feat-a
feat-b feat-a 2 3 0 feat-a
feat-c feat-b 3 3 0 feat-a' \
    "$(gs_commit_lines "$r" main feat-a feat-b feat-c \
       | awk -f "$DIR/infer.awk" | sort | tr '\t' ' ')"

  # advance feat-b: the child must now be flagged
  ( cd "$base/wt-b" && echo b2 > b2.txt && gs_t_git add -A && gs_t_git commit -qm b2 )
  gs_assert 'advanced parent flags child in fixture' \
'feat-a - 1 3 0 feat-a
feat-b feat-a 2 3 0 feat-a
feat-c feat-b 3 3 1 feat-a' \
    "$(gs_commit_lines "$r" main feat-a feat-b feat-c \
       | awk -f "$DIR/infer.awk" | sort | tr '\t' ' ')"

  # A fixture that fails partway must report failure, not continue silently.
  (
    gs_t_git() { case "$1" in commit) return 1 ;; *) git "$@" ;; esac }
    b2="$(mktemp -d)"
    gs_t_fixture "$b2" >/dev/null 2>&1
    rc=$?
    rm -rf "$b2"
    exit $rc
  )
  gs_assert 'fixture failure propagates' '1' "$?"

  rm -rf "$base"
}

GROUP="${1:-all}"
case "$GROUP" in
  token|all) test_token ;;
esac
case "$GROUP" in
  infer|all) test_infer ;;
esac
case "$GROUP" in
  git|all) test_git ;;
esac
gs_summary
