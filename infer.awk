# Stack inference for the git-stack herdr plugin.
#
# in : "<branch>\t<commit>" — one line per commit in trunk..branch
# out: "<branch>\t<parent|->\t<pos>\t<size>\t<restack 0|1>\t<root>"
#      emitted only for branches in a stack of two or more branches
#
# POSIX awk only. Two-key arrays use "a SUBSEP b".
BEGIN { FS = "\t"; OFS = "\t" }

{
  dep[$1]++
  owners[$2] = owners[$2] SUBSEP $1
}

END {
  # Shared-commit counts for every ordered branch pair.
  for (cm in owners) {
    n = split(owners[cm], who, SUBSEP)
    for (i = 1; i <= n; i++) {
      if (who[i] == "") continue
      for (j = 1; j <= n; j++) {
        if (j == i || who[j] == "") continue
        inter[who[i] SUBSEP who[j]]++
      }
    }
  }

  # Parent selection.
  for (ch in dep) {
    best = ""; bs = 0; bc = 0; bd = 0
    for (p in dep) {
      if (p == ch) continue
      # Strict total order on (depth, name) keeps the result a forest.
      if (!(dep[p] < dep[ch] || (dep[p] == dep[ch] && p < ch))) continue
      sc = inter[p SUBSEP ch] + 0
      if (sc == 0) continue
      ct = (sc == dep[p]) ? 1 : 0
      if (best == "" || sc > bs \
          || (sc == bs && ct > bc) \
          || (sc == bs && ct == bc && dep[p] > bd) \
          || (sc == bs && ct == bc && dep[p] == bd && p < best)) {
        best = p; bs = sc; bc = ct; bd = dep[p]
      }
    }
    parent[ch] = best
    # The parent holds commits the child lacks: the child needs a restack.
    restack[ch] = (best != "" && bs != dep[best]) ? 1 : 0
  }

  # Components, depth within the component, component size.
  for (b in dep) {
    r = b; hops = 1
    while (parent[r] != "") { r = parent[r]; hops++ }
    root[b] = r; pos[b] = hops; members[r]++
    if (hops > size[r]) size[r] = hops
  }

  for (b in dep) {
    r = root[b]
    if (members[r] < 2) continue
    print b, (parent[b] == "" ? "-" : parent[b]), pos[b], size[r], restack[b], r
  }
}
