# Henri's Ghostty fork

This is [upstream Ghostty](https://github.com/ghostty-org/ghostty) as of my
last rebase from `upstream/main`, plus one feature upstream doesn't have yet:
**session save/restore for Linux (GTK)**, built for and tested on
Wayland + GNOME + Ubuntu.

Upstream's position is to wait for GTK-level session management
([discussion #12055](https://github.com/ghostty-org/ghostty/discussions/12055)),
so this lives here. The starting point was the auto-closed upstream
[PR #12962](https://github.com/ghostty-org/ghostty/pull/12962), heavily
adapted and extended (split layouts, focus, backups were not in the PR).

## What gets remembered

Close Ghostty (window X, `exit`, quit, even SIGTERM) and the next launch
restores:

- **Windows** - size and maximized state (not position: Wayland doesn't
  allow apps to place their own windows; stacking order is also not
  guaranteed).
- **Tabs** - per window, in order, including which tab was selected.
- **Titles** - tab/surface/window titles *you set by hand* (right-click →
  "Change Tab Title…", or a `prompt_tab_title` keybind). Titles set by the
  shell via escape sequences are deliberately not persisted - the fresh
  shell will just set them again, and pinning them would freeze them.
- **Split layout** - each tab's full split tree: orientation and ratio of
  every divider, plus zoom state.
- **Working directory** - per pane, via shell integration's OSC 7 reports
  (so `shell-integration` must be active, which it is by default).
- **Focus** - the focused tab and the focused pane within it.
- **Scrollback** (optional, off by default) - set
  `window-save-state-scrollback-size = <bytes>` and each pane's most recent
  scrollback is replayed above the new prompt, colours included.

Shells are started fresh; running processes are not restored.

## How it works

- State lives at `$XDG_STATE_HOME/ghostty/<app id>/session.json`
  (`~/.local/state/ghostty/com.mitchellh.ghostty/session.json` for a
  ReleaseFast build; debug builds use `com.mitchellh.ghostty-debug`).
  Optional scrollback goes in `scrollback/<surface id>.vt` next to it.
- Saves happen on quit and window close, plus coalesced background saves on
  every structural change (tab open/close/reorder, split create/resize/zoom,
  rename, `cd`), so state survives SIGKILL or a power cut. Writes are
  atomic (tmp + rename), `0600`, and skipped when nothing changed.
- Restore runs on the app's first activation, replacing the default window.
  The schema is versioned (currently v2) and validated defensively: a
  malformed or truncated file is ignored or degraded per-tab, never a crash.
- **Backups**: every successful restore snapshots the file it just loaded to
  `backup/<unix timestamp>.json` in the same directory (the 10 newest are
  kept). The save path never touches these, so if a rich layout ever gets
  clobbered by a throwaway session, copy a backup back over `session.json`.
- Only the canonical single instance saves/restores. Launching from inside
  a terminal makes `gtk-single-instance` auto-detect to `false`, so ad-hoc
  terminal launches need `--gtk-single-instance=true`; desktop launches are
  fine as-is. `ghostty -e cmd` instances never touch session state.
- Turn it all off with `window-save-state = never` (also deletes the file).

## Building (Ubuntu)

```sh
sudo apt install -y libgtk-4-dev libadwaita-1-dev blueprint-compiler \
  gettext libxml2-utils libgtk4-layer-shell-dev
zig build -Doptimize=ReleaseFast   # zig 0.16.0+
```

Without `libgtk4-layer-shell-dev`, add `-fno-sys=gtk4-layer-shell` (the
vendored copy's runpath then ties the binary to the build directory).

## Maintenance notes (mostly for future me)

- Rebase flow: fetch upstream, rebase this branch's commits onto
  `upstream/main`, rebuild, retest (`zig build test -Dapp-runtime=none
  -Dtest-filter=SplitTree` and `-Dtest-filter=session` cover the pure logic).
- The GNOME launcher + D-Bus service files under `~/.local/share` point at
  `zig-out/bin/ghostty` in this checkout; a rebuild is all a new version
  needs.
- Restore is triggered from the first `activate()` specifically so D-Bus
  activation (how GNOME launches apps, with `--initial-window=false`)
  restores correctly - don't move it back into `run()`.
