# Git branch stacks — herdr plugin

Shows where each space sits in its git branch stack, in the spaces sidebar:

```
● ┌1/3 · add-the-paywall-cta
  │ · CON2-80
  │ · sven-con2-80-add-th…
● ├2/3 · put-the-cta-behind…
  │ · CON2-82
  │ · sven-con2-82-put-the…
● ├3/3 󱓎 · batch-the-cta-events
  │ · CON2-85
  └ · sven-con2-85-batch…
```

A space fills several sidebar rows, so the bracket is drawn by one token per
row. `gstk_stack` heads the first row: `┌` opens the bracket on the root, `├` marks
every deeper member, and `2/3` is the position in a three-branch stack.
`gstk_stack_tail` closes the last row: `│` carries the line on, `└` ends it under the
deepest branch. An optional `gstk_stack_bar_<name>` carries the line through each row
in between. Together they wrap the whole stack in one unbroken bracket.
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
herdr plugin install ubuntudroid/herdr-git-stack
```

For local development, link a checkout instead:

```bash
herdr plugin link /path/to/herdr-git-stack
```

The `[[startup]]` hook only runs the next time herdr starts, so linking alone
starts nothing visibly. Either restart herdr, or start the poller for the
current session with:

```bash
herdr plugin action invoke ubuntudroid.git-stack.start
```

Stop it the same way with `herdr plugin action invoke ubuntudroid.git-stack.stop` (also
available as the optional keybinding below).

Before enabling it, see what it would do to your sidebar without touching
anything:

```bash
GIT_STACK_DRYRUN=1 ./poller-ctl.sh poll-once
```

This prints the tokens each stacked space would get and any moves that would be
applied, and writes nothing.

## Configure the sidebar

The plugin publishes `gstk_stack` and `gstk_stack_tail` metadata tokens; herdr only
renders them if your layout asks for them. Put `$gstk_stack` right after
`state_icon` on your top row and `$gstk_stack_tail` first on your bottom one, in
`~/.config/herdr/config.toml`:

```toml
[ui.sidebar.spaces]
rows = [
  ["state_icon", { token = "$gstk_stack", fg = "#89b4fa" }, "workspace"],
  [{ token = "$gstk_stack_tail", fg = "#89b4fa" }, "branch", "git_status"],
]
```

Then `herdr server reload-config`.

Those two positions line up on purpose: herdr indents every row after the first
by exactly the two columns `state_icon` occupies, so a head placed after the
state icon and a tail leading its own row land in the same column. Do not try
to nudge them with spaces — herdr trims token values.

Sharing those rows costs about 8 columns on the first and 2 on the last. To give
the head its own row, add `[{ token = "$gstk_stack" }]` as a separate entry instead.

**Token names are namespaced.** Every plugin's tokens share one name space, so
each token this plugin publishes is prefixed `gstk_` and cannot collide with
another plugin's. Override the prefix with `GIT_STACK_TOKEN_PREFIX` (see
[Environment](#environment)) and mirror it in `rows`; set it to the empty string
for the bare `stack` / `stack_tail` / `stack_bar_*` names published before 0.3.0.

## Rows in the middle

With more than two rows configured, the line breaks across the rows in between.
Close the gap by declaring one connector per middle row in
`bars.conf`, under the plugin's config directory
(`~/.config/herdr/plugins/config/ubuntudroid.git-stack/` on Linux and macOS):

```
# <name>: <metadata token name>...
coder: coder_icon coder_ticket
session: coder
```

Each line publishes `gstk_stack_bar_<name>` as a `│`, and the tokens after the colon
are the condition: the bar is set only for a space that already carries one of
them, and cleared for one that does not. Use `always` for a row that is never
empty. Then reference them in the matching rows:

```toml
rows = [
  ["state_icon", { token = "$gstk_stack", fg = "#89b4fa" }, "workspace"],
  [{ token = "$gstk_stack_bar_coder", fg = "#89b4fa" }, "$coder_icon", "$coder_ticket"],
  [{ token = "$gstk_stack_bar_session", fg = "#89b4fa" }, "$coder"],
  [{ token = "$gstk_stack_tail", fg = "#89b4fa" }, "branch", "git_status"],
]
```

The condition is the whole point. herdr draws a row when any one of its tokens
resolves, so an unconditional bar would turn every otherwise-blank middle row
into a bare `│`. Naming that row's real tokens keeps the row collapsed for
spaces that have nothing to put on it.

Bars cost one extra `workspace list` read per tick, and only when `bars.conf`
exists. They also depend on another plugin's tokens being live, so a bar follows
whatever publishes them.

Optional keybinding:

```toml
[[keys.command]]
key = "prefix+shift+s"
type = "plugin_action"
command = "ubuntudroid.git-stack.toggle"
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
  members. The bracket still closes exactly once, on whichever member sits at
  the bottom of the block.

## Environment

| Variable | Default | Meaning |
|---|---|---|
| `GIT_STACK_REFRESH` | `3` | poll interval in seconds |
| `GIT_STACK_TTL_MS` | `9000` | token TTL; tokens vanish if the poller dies |
| `GIT_STACK_DRYRUN` | unset | print intended writes instead of applying them |
| `GIT_STACK_CONFIG_DIR` | `$HERDR_PLUGIN_CONFIG_DIR` | where `bars.conf` is read from |
| `GIT_STACK_TOKEN_PREFIX` | `gstk_` | prefix on every sidebar token name; mirror it in `rows`, empty for bare names |

## Tests

```bash
./test.sh          # everything except herdr and poll
./test.sh infer    # one group: token, infer, git, trunk, bracket, bars, moves, stacks, herdr, poll
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
