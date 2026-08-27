# Move planning for the git-stack herdr plugin.
#
# usage: awk -f plan_moves.awk <stacks_file> <order_file>
#   stacks_file: one stack per line, workspace ids space separated, stack order
#   order_file : current sidebar order, one workspace id per line
#   output     : one line per required move: "<anchor|-> <id1> <id2> ..."
#
# Only stack members move. A stack already contiguous and in order emits
# nothing, which is what keeps a steady state free of writes.
NR == FNR { nst++; st[nst] = $0; next }
{ no++; ord[no] = $1 }

END {
  for (s = 1; s <= nst; s++) {
    n = split(st[s], want, " ")
    if (n < 2) continue

    delete inblk
    for (i = 1; i <= n; i++) inblk[want[i]] = 1

    # Current relative order of the members, and where the stack starts.
    cn = 0; landing = 0
    for (i = 1; i <= no; i++) {
      if (ord[i] in inblk) {
        cn++; cur[cn] = ord[i]
        if (landing == 0) landing = i
      }
    }
    if (cn != n) continue        # a member is not on the sidebar: leave it alone

    ordered = 1
    for (i = 1; i <= n; i++) if (cur[i] != want[i]) { ordered = 0; break }

    contig = 1
    for (i = 0; i < n; i++) if (!(ord[landing + i] in inblk)) { contig = 0; break }

    if (ordered && contig) continue

    anchor = "-"
    for (i = landing; i <= no; i++) if (!(ord[i] in inblk)) { anchor = ord[i]; break }

    line = anchor
    for (i = 1; i <= n; i++) line = line " " want[i]
    print line

    # Simulate the move so later stacks plan against the updated order.
    m = 0
    for (i = 1; i <= no; i++) if (!(ord[i] in inblk)) { m++; tmp[m] = ord[i] }
    k = 0
    if (anchor == "-") {
      for (i = 1; i <= m; i++) { k++; nord[k] = tmp[i] }
      for (i = 1; i <= n; i++) { k++; nord[k] = want[i] }
    } else {
      for (i = 1; i <= m; i++) {
        if (tmp[i] == anchor) {
          for (j = 1; j <= n; j++) { k++; nord[k] = want[j] }
        }
        k++; nord[k] = tmp[i]
      }
    }
    no = k
    for (i = 1; i <= no; i++) ord[i] = nord[i]
  }
}
