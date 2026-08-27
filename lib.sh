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
