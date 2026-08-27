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

GROUP="${1:-all}"
case "$GROUP" in
  token|all) test_token ;;
esac
gs_summary
