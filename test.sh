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

# gs_t_infer_p <patch-specs-string> <commit-spec>...
# Same as gs_t_infer but also supplies a patch-id file, enabling the rebase
# fallback. Patch specs use the same "branch:p1,p2" shape.
gs_t_infer_p() {
  local pspec="$1" pf out
  shift
  pf="$(mktemp)"
  # shellcheck disable=SC2086
  gs_t_commits $pspec > "$pf"
  out="$(gs_t_commits "$@" | awk -v patchfile="$pf" -f "$DIR/infer.awk" | sort | tr '\t' ' ')"
  rm -f "$pf"
  printf '%s' "$out"
}

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

  # Tie-break tier 4: two candidates tied on score, containment AND depth, so
  # only the branch-name comparison can decide. feat-a and feat-b each share
  # exactly one commit with feat-z and neither contains it, and both have depth
  # 2. The lexicographically smaller name must win. This is the only assertion
  # that fails if `p < best` is flipped to `p > best` — verified by mutation.
  gs_assert 'tie-break falls through to branch name' \
'feat-a - 1 2 0 feat-a
feat-z feat-a 2 2 1 feat-a' \
    "$(gs_t_infer 'feat-a:a1,x1' 'feat-b:b1,y1' 'feat-z:a1,b1,z1')"

  # A rebased parent rewrites every commit, so parent and child share NO commit
  # ids and the commit-id pass finds no parent at all — the stack vanishes.
  # This is the real-world case: rebasing the root of a two-branch stack.
  gs_assert 'rebased parent: no stack without patch ids' '' \
    "$(gs_t_infer 'feat-a:a2' 'feat-b:a1,b1')"

  # With patch ids the parent is found again, and the edge is ALWAYS a restack:
  # the parent's actual commits are provably absent from the child.
  gs_assert 'rebased parent: patch ids recover the stack, flagged' \
'feat-a - 1 2 0 feat-a
feat-b feat-a 2 2 1 feat-a' \
    "$(gs_t_infer_p 'feat-a:pa feat-b:pa,pb' 'feat-a:a2' 'feat-b:a1,b1')"

  # The fallback must not override a parent the commit-id pass already found,
  # nor invent restack flags on a healthy stack.
  gs_assert 'patch ids do not disturb a healthy stack' \
'feat-a - 1 3 0 feat-a
feat-b feat-a 2 3 0 feat-a
feat-c feat-b 3 3 0 feat-a' \
    "$(gs_t_infer_p 'feat-a:pa feat-b:pa,pb feat-c:pa,pb,pc' 'feat-a:a1' 'feat-b:a1,b1' 'feat-c:a1,b1,c1')"

  # Two branches that merely touch the same lines are not a stack: no shared
  # commit ids AND no shared patch ids means no edge, fallback or not.
  gs_assert 'unrelated branches stay unrelated under the fallback' '' \
    "$(gs_t_infer_p 'feat-a:pa feat-b:pb' 'feat-a:a1' 'feat-b:b1')"

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

  # --- a genuinely rebased root, on real git ---------------------------------
  # main gains a commit, the stack ROOT is rebased onto it, so its commit id is
  # rewritten and the child — still built on the old one — shares NO commit ids
  # with it. This removed a real stack from the sidebar on 2026-08-28. The
  # original suite never covered it: its rebase fixture had a grandparent still
  # supplying shared commits, so the zero-overlap case went untested.
  local rb r2
  rb="$(readlink -f "$(mktemp -d)")"
  r2="$(gs_t_fixture "$rb")" || { gs_assert 'rebase fixture built' 'yes' 'no'; rm -rf "$rb"; return 1; }

  ( cd "$r2" && gs_t_git checkout -q main && echo m2 > m2.txt \
      && gs_t_git add -A && gs_t_git commit -qm m2 ) >/dev/null 2>&1
  ( cd "$rb/wt-a" && gs_t_git rebase -q main ) >/dev/null 2>&1

  gs_assert 'rebased root shares no commit ids with its child' '0' \
    "$(comm -12 <(git -C "$r2" rev-list main..feat-a | sort) \
                <(git -C "$r2" rev-list main..feat-b | sort) | wc -l | tr -d ' ')"

  # Commit ids alone: feat-a drops out entirely, so feat-b/feat-c look like a
  # two-branch stack rooted at feat-b.
  gs_assert 'rebased root: lost by commit ids alone' \
'feat-b - 1 2 0 feat-b
feat-c feat-b 2 2 0 feat-b' \
    "$(gs_commit_lines "$r2" main feat-a feat-b feat-c \
       | awk -f "$DIR/infer.awk" | sort | tr '\t' ' ')"

  # Patch ids recover it: feat-a is the root again and feat-b is flagged for a
  # restack, which is exactly the signal the glyph exists for.
  local pf2
  pf2="$(mktemp)"
  gs_patch_lines "$r2" main feat-a feat-b feat-c > "$pf2"
  gs_assert 'rebased root: recovered by patch ids and flagged' \
'feat-a - 1 3 0 feat-a
feat-b feat-a 2 3 1 feat-a
feat-c feat-b 3 3 0 feat-a' \
    "$(gs_commit_lines "$r2" main feat-a feat-b feat-c \
       | awk -v patchfile="$pf2" -f "$DIR/infer.awk" | sort | tr '\t' ' ')"
  rm -f "$pf2"
  rm -rf "$rb"
}

# gs_t_moves <stacks-newline-string> <order-newline-string>
gs_t_moves() {
  local sf of out
  sf="$(mktemp)"; of="$(mktemp)"
  printf '%s\n' "$1" > "$sf"
  printf '%s\n' "$2" > "$of"
  out="$(awk -f "$DIR/plan_moves.awk" "$sf" "$of")"
  rm -f "$sf" "$of"
  printf '%s' "$out"
}

test_moves() {
  gs_assert 'already contiguous and ordered: no move' '' \
    "$(gs_t_moves 'a b c' 'a
b
c')"

  gs_assert 'reversed, whole list: move to end' '- a b c' \
    "$(gs_t_moves 'a b c' 'c
b
a')"

  gs_assert 'reversed with a trailing outsider: anchor on it' 'z a b c' \
    "$(gs_t_moves 'a b c' 'c
b
a
z')"

  gs_assert 'ordered but interleaved: make contiguous at the landing spot' 'z a b c' \
    "$(gs_t_moves 'a b c' 'a
z
b
c')"

  gs_assert 'outsiders before the stack keep their places' 'q a b c' \
    "$(gs_t_moves 'a b c' 'p
b
q
a
c')"

  gs_assert 'two stacks: only the unordered one moves' '- t1 t2' \
    "$(gs_t_moves 's1 s2
t1 t2' 's1
s2
x
t2
t1')"

  gs_assert 'two stacks both moving, second sees the first applied' 'x s1 s2
- t1 t2' \
    "$(gs_t_moves 's1 s2
t1 t2' 's2
s1
x
t2
t1')"

  gs_assert 'single-member stack is ignored' '' \
    "$(gs_t_moves 'a' 'b
a')"

  gs_assert 'member missing from the order is skipped' '' \
    "$(gs_t_moves 'a b c' 'c
b')"
}

# gs_t_stacks <infer-output-newline-string> <map-newline-string>
# Sorts exactly the way gs_stacks_for_repo does before invoking stacks.awk,
# so the test exercises the real sort+awk contract, not just the awk in
# isolation. Input need not be pre-sorted by the caller.
gs_t_stacks() {
  local mf sf out
  mf="$(mktemp)"; sf="$(mktemp)"
  printf '%s\n' "$2" > "$mf"
  printf '%s\n' "$1" | sort -t"$(printf '\t')" -k6,6 -k3,3n -k1,1 > "$sf"
  out="$(awk -f "$DIR/stacks.awk" "$mf" "$sf")"
  rm -f "$mf" "$sf"
  printf '%s' "$out"
}

test_stacks() {
  # linear three-branch component
  gs_assert 'linear stack, all three in order' 'wA wB wC' \
    "$(gs_t_stacks 'feat-a	-	1	3	0	feat-a
feat-b	feat-a	2	3	0	feat-a
feat-c	feat-b	3	3	0	feat-a' \
'feat-a	wA
feat-b	wB
feat-c	wC')"

  # Regression test for CRITICAL 2: feat-c, feat-d and feat-e are all
  # siblings at position 3 under feat-b. The old pos[root,pos]-keyed awk
  # overwrote same-depth siblings and emitted only 3 of these 5 ids
  # (verified by hand: "wA wB wE", dropping wC and wD). All five must
  # survive, ordered by position then branch name.
  gs_assert 'branching component keeps every sibling' 'wA wB wC wD wE' \
    "$(gs_t_stacks 'feat-a	-	1	3	0	feat-a
feat-b	feat-a	2	3	0	feat-a
feat-e	feat-b	3	3	0	feat-a
feat-c	feat-b	3	3	0	feat-a
feat-d	feat-b	3	3	0	feat-a' \
'feat-a	wA
feat-b	wB
feat-c	wC
feat-d	wD
feat-e	wE')"

  # a single-member component produces no line (stacks.awk's own guard,
  # mirroring infer.awk's contract that a lone branch forms no stack)
  gs_assert 'single-member component is empty' '' \
    "$(gs_t_stacks 'feat-a	-	1	1	0	feat-a' 'feat-a	wA')"

  # a branch in the infer output but absent from the map is skipped; the
  # rest of the component is still emitted
  gs_assert 'branch missing from map is skipped, rest survives' 'wA wC' \
    "$(gs_t_stacks 'feat-a	-	1	3	0	feat-a
feat-b	feat-a	2	3	0	feat-a
feat-c	feat-b	3	3	0	feat-a' \
'feat-a	wA
feat-c	wC')"

  # two independent components produce two lines
  gs_assert 'two independent components, two lines' 'wX1 wX2
wY1 wY2' \
    "$(gs_t_stacks 'y1	-	1	2	0	y1
x1	-	1	2	0	x1
y2	y1	2	2	0	y1
x2	x1	2	2	0	x1' \
'x1	wX1
x2	wX2
y1	wY1
y2	wY2')"
}

test_herdr() {
  if [ "${GIT_STACK_LIVE_TESTS:-}" != "1" ]; then
    printf 'SKIP herdr group: writes to the live herdr session (creates/closes a workspace, writes/clears tokens, reorders the sidebar). Set GIT_STACK_LIVE_TESTS=1 to run it.\n' >&2
    return 0
  fi
  local sock="${HERDR_SOCKET_PATH:-$HOME/.config/herdr/herdr.sock}" ws tok
  if [ ! -S "$sock" ]; then
    printf 'SKIP herdr group: no socket at %s\n' "$sock" >&2
    return 0
  fi

  gs_assert 'socket ping' 'pong' \
    "$(gs_socket ping '{}' | jq -r '.result.type')"

  gs_assert 'unreachable socket returns 1' '1' \
    "$(HERDR_SOCKET_PATH=/tmp/gs-no-such.sock gs_socket ping '{}' >/dev/null 2>&1; echo $?)"

  # Every row must have exactly 4 tab-separated fields and a checkout path that
  # exists on disk. Row count varies by machine, so assert the shape, not a total.
  local bad
  bad="$(gs_workspaces | awk -F'\t' 'NF != 4 { n++ } END { print n+0 }')"
  gs_assert 'gs_workspaces rows have 4 fields' '0' "$bad"
  bad="$(gs_workspaces | awk -F'\t' '{ print $4 }' | while IFS= read -r p; do [ -d "$p" ] || echo x; done | wc -l | tr -d ' ')"
  gs_assert 'gs_workspaces checkout paths exist' '0' "$bad"

  # Throwaway workspace for the write path.
  # ADAPT IF WRONG: the response shape of `workspace create` was never observed
  # live. If this yields an empty id, run the command by hand, read the JSON,
  # and correct the jq path — do not work around it downstream.
  ws="$("${HERDR_BIN_PATH:-herdr}" workspace create --cwd /tmp --label gs-selftest --no-focus \
        | jq -r '.result.workspace.workspace_id // .workspace.workspace_id')"
  gs_assert 'created a test workspace' 'yes' \
    "$([ -n "$ws" ] && [ "$ws" != "null" ] && echo yes || echo no)"

  gs_set_token "$ws" '├2/3 󱓎' 1
  tok="$("${HERDR_BIN_PATH:-herdr}" workspace list \
         | jq -r --arg w "$ws" '(.result.workspaces // .workspaces)[]
                                | select(.workspace_id == $w) | .tokens.stack')"
  gs_assert 'token round trip keeps the glyph' '├2/3 󱓎' "$tok"

  gs_clear_token "$ws" 2
  tok="$("${HERDR_BIN_PATH:-herdr}" workspace list \
         | jq -r --arg w "$ws" '(.result.workspaces // .workspaces)[]
                                | select(.workspace_id == $w) | .tokens.stack')"
  gs_assert 'token cleared' 'null' "$tok"

  gs_assert 'test workspace appears in the order' 'yes' \
    "$(gs_order | grep -qx "$ws" && echo yes || echo no)"

  # Identity reorder: sending the whole current order with anchor "-" moves every
  # workspace to the end in the order it already has. The response must therefore
  # echo the same ids in the same order — a dropped, duplicated or reordered id is
  # a regression in the one function whose job is ordering.
  local of ids got
  of="$(mktemp)"
  gs_order > "$of"
  ids="$(tr '\n' ' ' < "$of")"
  # shellcheck disable=SC2086
  got="$(gs_move_block - $ids | jq -r '.result.workspaces[].workspace_id' | tr '\n' ' ')"
  gs_assert 'move_block preserves ids and order' "$(printf '%s ' $ids)" "$got"
  rm -f "$of"

  "${HERDR_BIN_PATH:-herdr}" workspace close "$ws" >/dev/null 2>&1
  gs_assert 'test workspace closed' 'no' \
    "$(gs_order | grep -qx "$ws" && echo yes || echo no)"
}

test_poll() {
  if [ "${GIT_STACK_LIVE_TESTS:-}" != "1" ]; then
    printf 'SKIP poll group: touches the live herdr session (creates and closes a throwaway workspace, writes/clears a token on it). Set GIT_STACK_LIVE_TESTS=1 to run it.\n' >&2
    return 0
  fi
  local sock="${HERDR_SOCKET_PATH:-$HOME/.config/herdr/herdr.sock}" out
  if [ ! -S "$sock" ]; then
    printf 'SKIP poll group: no socket at %s\n' "$sock" >&2
    return 0
  fi

  # Dry run must never write. It prints "token <ws> <value>", "clear <ws>"
  # and "move <anchor> <ids...>" lines, or nothing when no space is stacked.
  out="$(GIT_STACK_DRYRUN=1 "$DIR/poller-ctl.sh" poll-once 2>&1)"
  gs_assert 'dry run exits clean' '0' "$?"
  gs_assert 'dry run emits only token, clear and move lines' '' \
    "$(printf '%s\n' "$out" | grep -v '^token ' | grep -v '^clear ' | grep -v '^move ' | grep -v '^$')"

  # Shape-only checking would miss a stray un-gated write. Compare live state
  # across the dry run: it must change neither tokens nor sidebar order. A
  # known token on our own throwaway workspace gives the token comparison
  # guaranteed discriminating power, independent of whether the user happens
  # to have stacked branches open right now.
  local pws
  pws="$("${HERDR_BIN_PATH:-herdr}" workspace create --cwd /tmp --label gs-poll-selftest --no-focus \
        | jq -r '.result.workspace.workspace_id // .workspace.workspace_id')"
  gs_assert 'created the poll-group throwaway workspace' 'yes' \
    "$([ -n "$pws" ] && [ "$pws" != "null" ] && echo yes || echo no)"
  # Longer TTL than the default 9s: gs_recompute on a bigger repo could
  # otherwise expire this before the after-snapshot is taken, turning a
  # slow machine into a flaky failure here.
  local saved_ttl="$GS_TTL_MS"
  GS_TTL_MS=60000
  gs_set_token "$pws" '┌1/2' 1
  GS_TTL_MS="$saved_ttl"

  local tok_before tok_after ord_before ord_after
  tok_before="$("${HERDR_BIN_PATH:-herdr}" workspace list 2>/dev/null | jq -r '(.result.workspaces // .workspaces)[] | select(.tokens.stack != null) | "\(.workspace_id)=\(.tokens.stack)"' | sort | tr '\n' ' ')"
  # The comparison below only has guaranteed discriminating power if our own
  # token actually landed — assert that directly rather than trusting it.
  gs_assert 'known token landed before the dry run' 'yes' \
    "$(printf '%s' "$tok_before" | grep -q "$pws=┌1/2" && echo yes || echo no)"
  ord_before="$(gs_order | tr '\n' ' ')"
  GIT_STACK_DRYRUN=1 "$DIR/poller-ctl.sh" poll-once >/dev/null 2>&1
  tok_after="$("${HERDR_BIN_PATH:-herdr}" workspace list 2>/dev/null | jq -r '(.result.workspaces // .workspaces)[] | select(.tokens.stack != null) | "\(.workspace_id)=\(.tokens.stack)"' | sort | tr '\n' ' ')"
  ord_after="$(gs_order | tr '\n' ' ')"
  gs_assert 'dry run writes no tokens' "$tok_before" "$tok_after"
  gs_assert 'dry run does not reorder' "$ord_before" "$ord_after"

  gs_clear_token "$pws" 2
  "${HERDR_BIN_PATH:-herdr}" workspace close "$pws" >/dev/null 2>&1

  gs_assert 'status reports stopped when no pidfile' 'stopped' \
    "$(GIT_STACK_STATE_DIR="$(mktemp -d)" "$DIR/poller-ctl.sh" status)"

  gs_assert 'unknown subcommand exits 2' '2' \
    "$("$DIR/poller-ctl.sh" bogus >/dev/null 2>&1; echo $?)"

  # A pidfile holding a live PID that is NOT our poller must read as stopped,
  # not running — otherwise stop would signal an unrelated process.
  local sd
  sd="$(mktemp -d)"
  echo "$$" > "$sd/poller.pid"
  gs_assert 'foreign live PID reads as stopped' 'stopped' \
    "$(GIT_STACK_STATE_DIR="$sd" "$DIR/poller-ctl.sh" status)"
  rm -rf "$sd"

  # A different plugin's poller-ctl.sh must never be mistaken for ours: same
  # basename, different path. This is a real collision on machines that also
  # run the CI-status plugin.
  local dd dpid
  dd="$(mktemp -d)"
  printf '#!/usr/bin/env bash\nsleep 30\n' > "$dd/poller-ctl.sh"
  chmod +x "$dd/poller-ctl.sh"
  "$dd/poller-ctl.sh" run &
  dpid=$!
  echo "$dpid" > "$dd/poller.pid"
  gs_assert 'another plugin poller-ctl.sh is not ours' 'stopped' \
    "$(GIT_STACK_STATE_DIR="$dd" "$DIR/poller-ctl.sh" status)"
  # kill just $dpid leaves its `sleep 30` child orphaned and running for the
  # full 30s (verified empirically): bash does not propagate SIGTERM to a
  # foreground child it is waiting on. Kill the child first, then the wrapper.
  pkill -P "$dpid" 2>/dev/null
  kill "$dpid" 2>/dev/null
  wait "$dpid" 2>/dev/null
  rm -rf "$dd"

  # A deliberate stop must survive `ensure`, which is what the startup hook runs.
  sd="$(mktemp -d)"
  GIT_STACK_STATE_DIR="$sd" "$DIR/poller-ctl.sh" stop >/dev/null 2>&1
  gs_assert 'ensure respects a deliberate stop' 'stopped' \
    "$(GIT_STACK_STATE_DIR="$sd" "$DIR/poller-ctl.sh" ensure)"
  rm -rf "$sd"
}

# Note: preflight is not unit-tested. `PATH=/nonexistent` cannot reach it,
# because the `#!/usr/bin/env bash` shebang resolves bash through PATH and
# fails at exec with 127 first. Verify it by hand instead, e.g. by temporarily
# renaming nc, or trust it — it is a three-command guard.

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
case "$GROUP" in
  moves|all) test_moves ;;
esac
case "$GROUP" in
  stacks|all) test_stacks ;;
esac
case "$GROUP" in
  herdr|all) test_herdr ;;
esac
case "$GROUP" in
  poll|all) test_poll ;;
esac
gs_summary
