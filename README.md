# Git branch stacks — herdr plugin

Shows where each space sits in its git branch stack, in the spaces sidebar:

```
 ┌1/3 · sven-con2-80-add-th…
 ├2/3 · sven-con2-82-put-the…
 └3/3 󱓎 · sven-con2-85-batch…
```

`┌` root, `├` middle, `└` deepest, `2/3` the position in a three-branch stack.
`󱓎` means the parent branch has moved and this branch needs a restack.

Stack members are also kept contiguous in sidebar order, root first, so a stack
reads top to bottom.

Everything comes from the local commit graph. No network, no forge API, no
stacking tool, and workspace labels are never touched — the CI status plugin
owns those.

## Requirements

`git`, `jq`, and a netcat with unix-socket support (`nc -U`). macOS ships one;
on Linux use BSD/OpenBSD netcat, not GNU `nc.traditional`.

## Install

```bash
herdr plugin link /path/to/herdr-git-stack
```

The `[[startup]]` hook only runs the next time herdr starts, so linking alone
starts nothing visibly. Either restart herdr, or start the poller for the
current session with:

```bash
herdr plugin action invoke git-stack.start
```

Stop it the same way with `herdr plugin action invoke git-stack.stop` (also
available as the optional keybinding below).

Before enabling it, see what it would do to your sidebar without touching
anything:

```bash
GIT_STACK_DRYRUN=1 ./poller-ctl.sh poll-once
```

This prints the token each stacked space would get and any moves that would
be applied, and writes nothing.

## Configure the sidebar

The plugin publishes a `stack` metadata token; herdr only renders it if your
layout asks for it. Add `$stack` to `~/.config/herdr/config.toml`:

```toml
[ui.sidebar.spaces]
rows = [
  ["state_icon", "workspace"],
  [{ token = "$stack", fg = "#89b4fa" }, "branch", "git_status"],
]
```

Then `herdr server reload-config`.

Sharing the branch row costs about 8 columns. To give the token its own row,
add `[{ token = "$stack" }]` as a separate entry instead.

Optional keybinding:

```toml
[[keys.command]]
key = "prefix+shift+s"
type = "plugin_action"
command = "git-stack.toggle"
description = "toggle git stack indicators"
```

## How a parent is found

For every branch checked out in a space, the plugin takes the set of commits in
`trunk..branch`. A branch's parent is the branch sharing the most of those
commits, among branches that come earlier in the `(commit count, name)` order.
A parent holding commits the child lacks means the child needs a restack.

Consequences worth knowing:

- Only branches open in a space participate. An unopened intermediate branch is
  skipped and its children attach to the nearest open ancestor.
- When a parent and child hold the same number of commits beyond trunk, the edge
  survives only if the parent's branch name sorts first.
- Retargeting a pull request's base in a web UI changes nothing locally, so it
  does not show up here.
- Manually dragging a stacked space is undone on the next tick. Unstacked spaces
  are left alone.
- Branching stacks: two branches stacked on the same base both render as
  middle-of-stack (e.g. two `├2/3`s), not as separate leaves, and the counter
  reflects the depth of the deepest chain in the component, not the number of
  members.

## Environment

| Variable | Default | Meaning |
|---|---|---|
| `GIT_STACK_REFRESH` | `3` | poll interval in seconds |
| `GIT_STACK_TTL_MS` | `9000` | token TTL; tokens vanish if the poller dies |
| `GIT_STACK_DRYRUN` | unset | print intended writes instead of applying them |

## Tests

```bash
./test.sh          # everything except herdr and poll
./test.sh infer    # one group: token, infer, git, moves, stacks, herdr, poll
```

`herdr` and `poll` both touch a **live herdr session**: each creates and
closes its own throwaway workspace and writes/clears a real metadata token on
it. `herdr` additionally performs a real identity reorder of the whole
sidebar (moving every workspace to the end in its current order, to verify
moves preserve ids and order — the sidebar ends up exactly where it started,
but it is a genuine write, not a dry run). Because of that both groups are
opt-in and skipped by default, including under plain `./test.sh`. Run them
explicitly with:

```bash
GIT_STACK_LIVE_TESTS=1 ./test.sh          # everything, including the live groups
GIT_STACK_LIVE_TESTS=1 ./test.sh herdr    # just the live herdr-socket group
GIT_STACK_LIVE_TESTS=1 ./test.sh poll     # just the live poller-daemon group
```

Both also skip themselves (regardless of the opt-in) when no herdr server is
running. The `git` and `stacks` groups are pure fixtures — `git` builds a
throwaway repo with linked worktrees under `$TMPDIR`, `stacks` feeds synthetic
input straight to `stacks.awk` — neither touches a real repo or a live herdr
session.
