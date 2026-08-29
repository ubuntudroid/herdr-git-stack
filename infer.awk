# Stack inference for the git-stack herdr plugin.
#
# in : "<branch>\t<commit>" — one line per commit in trunk..branch (stdin)
# opt: -v patchfile=FILE — "<branch>\t<patchid>" lines. Used ONLY as a fallback for
#      a branch that has commits beyond trunk but no parent by commit id, which is
#      what a rebased parent looks like: it rewrote every commit, so parent and child
#      share no ids at all and the parent stops being a candidate. Patch ids survive
#      a rebase, so they still find it. An edge found this way is ALWAYS a restack:
#      the parent's actual commits are provably absent from the child, or the
#      commit-id pass would have found them.
# opt: -v forkfile=FILE — "<child>\t<parent>" edges already verified by the caller
#      via `git merge-base --fork-point`. Last resort, for a rebase that ALSO
#      resolved conflicts: that changes the diff, so patch ids no longer match
#      either. The caller proves each edge twice (a former tip of the parent that
#      is also an ancestor of the child), which is why this cannot invent one.
# opt: -v orphanfile=FILE — branches with commits beyond trunk and no parent are
#      written here, so the caller knows which branches to spend git calls on.
# opt: -v birthfile=FILE — "<branch>\t<unixtime>" ref creation times. Only breaks
#      ties in the eligibility order below: two branches holding the same commit
#      set are indistinguishable in the graph, so the one created later is the
#      child. Absent or partial, the order falls back to branch name.
# out: "<branch>\t<parent|->\t<pos>\t<size>\t<restack 0|1>\t<root>"
#      emitted only for branches in a stack of two or more branches
#
# POSIX awk only. Two-key arrays use "a SUBSEP b".
BEGIN {
  FS = "\t"; OFS = "\t"
  if (patchfile != "") {
    while ((getline pline < patchfile) > 0) {
      split(pline, pf, "\t")
      if (pf[1] == "" || pf[2] == "") continue
      pdep[pf[1]]++
      powners[pf[2]] = powners[pf[2]] SUBSEP pf[1]
    }
    close(patchfile)
  }
  if (birthfile != "") {
    while ((getline bline < birthfile) > 0) {
      split(bline, bf, "\t")
      if (bf[1] == "" || bf[2] == "") continue
      birth[bf[1]] = bf[2] + 0
    }
    close(birthfile)
  }
  if (forkfile != "") {
    while ((getline fline < forkfile) > 0) {
      split(fline, ff, "\t")
      if (ff[1] == "" || ff[2] == "") continue
      forkparent[ff[1]] = ff[2]
    }
    close(forkfile)
  }
}

{
  dep[$1]++
  owners[$2] = owners[$2] SUBSEP $1
}

# Strict total order on (depth, birth, name). Only a branch that is strictly
# earlier in it may parent a later one, which is what keeps the result a forest.
# Depth decides almost always; birth only speaks when two branches hold the same
# commit set, where the graph itself says nothing; name is the final fallback.
function earlier(p, c) {
  if (dep[p] != dep[c]) return dep[p] < dep[c]
  if (birth[p] + 0 != birth[c] + 0) return birth[p] + 0 < birth[c] + 0
  return p < c
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

  # Same pair counting over patch ids, for the fallback.
  for (cm in powners) {
    n = split(powners[cm], who, SUBSEP)
    for (i = 1; i <= n; i++) {
      if (who[i] == "") continue
      for (j = 1; j <= n; j++) {
        if (j == i || who[j] == "") continue
        pinter[who[i] SUBSEP who[j]]++
      }
    }
  }

  # Parent selection.
  for (ch in dep) {
    best = ""; bs = 0; bc = 0; bd = 0
    for (p in dep) {
      if (p == ch) continue
      if (!earlier(p, ch)) continue
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
    # Fallback: no parent by commit id, but this branch has work beyond trunk.
    # Retry over patch ids — a rebased parent keeps them. Eligibility still uses
    # the commit-id order, so the result stays a forest either way.
    if (best == "" && dep[ch] > 0 && patchfile != "") {
      for (p in dep) {
        if (p == ch) continue
        if (!earlier(p, ch)) continue
        sc = pinter[p SUBSEP ch] + 0
        if (sc == 0) continue
        ct = (sc == pdep[p]) ? 1 : 0
        if (best == "" || sc > bs \
            || (sc == bs && ct > bc) \
            || (sc == bs && ct == bc && dep[p] > bd) \
            || (sc == bs && ct == bc && dep[p] == bd && p < best)) {
          best = p; bs = sc; bc = ct; bd = dep[p]
        }
      }
      if (best != "") { parent[ch] = best; restack[ch] = 1; continue }
    }

    # Last resort: an edge the caller verified through the reflog. Still subject
    # to the eligibility order, so it cannot introduce a cycle.
    if (best == "" && dep[ch] > 0 && forkfile != "" && (ch in forkparent)) {
      fp = forkparent[ch]
      if (fp in dep && fp != ch && earlier(fp, ch)) {
        parent[ch] = fp; restack[ch] = 1; continue
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

  if (orphanfile != "") {
    for (b in dep) if (dep[b] > 0 && parent[b] == "") print b > orphanfile
    close(orphanfile)
  }

  for (b in dep) {
    r = root[b]
    if (members[r] < 2) continue
    print b, (parent[b] == "" ? "-" : parent[b]), pos[b], size[r], restack[b], r
  }
}
