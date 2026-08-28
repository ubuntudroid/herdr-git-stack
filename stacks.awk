# Build the per-component ordered workspace list that plan_moves.awk consumes.
#
# usage: awk -f stacks.awk <map_file> <infer_output>
#   map_file     : "<branch>\t<workspace_id>" lines
#   infer_output : infer.awk's output, "<branch>\t<parent|->\t<pos>\t<size>\t<restack>\t<root>"
#                  PRE-SORTED by root, then pos ascending, then branch
#   output       : one line per component with two or more members,
#                  workspace ids in stack order, space separated
#
# Accumulating in sorted read order is load-bearing. Keying by (root, pos) makes
# same-depth siblings overwrite each other, which drops members and emits a
# parent chain that does not exist — and that chain gets applied as a real move.
BEGIN { FS = "\t" }
NR == FNR { ws[$1] = $2; next }
{
  id = ws[$1]
  if (id == "") next                 # branch has no open workspace: not orderable
  if (!($6 in buf)) { nroots++; roots[nroots] = $6; buf[$6] = id }
  else buf[$6] = buf[$6] " " id
}
END {
  for (i = 1; i <= nroots; i++) if (buf[roots[i]] ~ / /) print buf[roots[i]]
}
