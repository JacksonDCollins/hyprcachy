# Native window-session plugin (experimental)

**Experimental and opt-in; no fixed Hyprland version allowlist.** This is a native C++
plugin plus a controller using Hyprland's embedded Lua runtime, not a daemon,
external Lua interpreter, Python/Node helper or Quickshell component.

The plugin captures dwindle's actual parent/child tree, split orientation and
ratios. After matching reopened windows, it validates the complete surviving
window set and rewires existing Hyprland-owned nodes. It does not approximate
splits from rectangles, replace dwindle, allocate layout nodes, hook functions or
access private node containers. Missing saved leaves are pruned. Extra live tiled
windows, groups or inconsistent trees cause restoration to be refused before
mutation; existing layout remains intact. Placement happens before tree restore,
and fullscreen is reapplied afterward. Floating windows also retain their pinned
state: placement temporarily unpins the window, then reapplies the saved pin state
after moving/resizing it.

## Existing projects checked

- [hypr-persist](https://github.com/ngamber/hypr-persist): an existing Rust session
  daemon that reconstructs trees from window geometry. Closest alternative, but
  not an authoritative native dwindle tree export/import plugin.
- [hypr-session](https://github.com/krishiv2489/hypr-session): session restoration,
  rather than native dwindle node/ratio persistence.

No suitable native plugin was found in that search. These remain alternatives if
inferred layouts or ordinary application/workspace restoration are sufficient.

## Build and packaging

The implementation, Makefile, packaging and upgrade integration all live here
in `packages/window-session/`. See [the package guide](README.md).

Build directly with `make` for development, or run `./rebuild-plugin.sh` from
the repository root for a clean package build and guarded installation.
See the package guide for prerequisites, startup integration and upgrade safety.
Installed package documentation is in `README.md` beside this runtime guide.

## Enable restoration

Configure it directly in `hyprland.lua` or a Lua module sourced by that config:

```lua
hl.config({
    general = { layout = "dwindle" },
    dwindle = { preserve_split = true },
})

dofile("/usr/share/hyprcachy/window-session/init.lua")({
    enabled = true,
    launch_delay = 20,    -- Seconds before missing-app launches / fallback matching.
    restore_timeout = 80, -- Maximum startup matching window; must exceed launch_delay.
    stability_delay = 15, -- Stable topology before automatic saving.
    launch = {
        foot = { "foot", "tmux", "new-session", "-A", "-s", "main" },
        firefox = "firefox.desktop", -- Desktop entry ID instead of an argv table.
        vesktop = false, -- Placement only; another autostart owns launching.
    },
    ignore = {}, -- Optional initial classes, e.g. { "private-app" }.
})
```

The package-owned `init.lua` returns a configuration function. Call it once per
reload with the complete options table; no loading logic or first-pass guard is
needed in dotfiles. Its stable absolute path does not depend on Lua versioned
module search directories. Install the package before using this call: a missing
snippet is a configuration error, not a silent disable.

The function declares `hl.plugin.load` and waits for the native API before applying
settings. Hyprland reloads the config after loading its declared plugins, before
announcing session readiness. Native initialization prepares the bounded protocol
store; the enabled config call then advertises it synchronously, before deferred
desktop discovery. Without `enabled = true`, restoration remains disabled.
`hyprctl plugin list` shows whether the native plugin is loaded. Keep the snippet
call while the session is running: removing it on reload lets Hyprland unload the
config-owned plugin, which can disconnect protocol clients. Disable the controller
with `enabled = false`, not by removing the call.
Keep `dwindle.preserve_split = true`. Once the native plugin is loaded, configuration
reloads apply settings without repeating restoration in the same session. With defaults, the first automatic save
needs about **20 seconds** of stable topology. Saving is sampled every five seconds,
so custom stability delays are rounded up to a sampling tick after a change is observed.

```sh
hyprctl repl 'return hyprcachy_window_session.status'
hyprctl repl 'return hyprcachy_window_session.save()' # queues an explicit checkpoint, even empty
```

Startup discovery, snapshot reads/writes, archival, process-command reads, and
snapshot encoding/decoding run on a native worker with its own Lua state. Only
copied plain data crosses threads; live windows and compositor APIs stay on the
main thread. The controller yields dispatcher objects to its main-state timer,
which invokes `hl.dispatch` and returns the result to the suspended coroutine.
Hyprland's opaque dispatcher objects are never called directly, and no dispatcher
runs on the file worker. The controller awaits completed jobs rather than blocking
a callback, increasing Hyprland's watchdog limit, or retrying a function against
elapsed time.
Slow storage delays readiness/checkpoint completion, not the compositor callback.
Application and autostart discovery finish before restore matching begins.

`save()`, `cycle()` and `restore_cycle()` queue asynchronous work. Wait until
`hyprcachy_window_session.task == nil` and check `.status` for errors before logout;
`save()` returning does not mean the checkpoint is committed. Cycle closes windows
only after both recovery checkpoints have been written successfully. Concurrent
manual operations are rejected as busy. Task errors stop the controller visibly;
failed writes do not replace the last complete checkpoint. Reload cancels obsolete
queued tasks; plugin shutdown joins the worker before unloading its code.

Restore reports include the underlying placement/layout errors. An `unmatched`
record has no accepted window match; it does not necessarily mean the application
failed to open. Read the last report with `hyprcachy_window_session.last_restore`.
An incomplete replay can finish and resume recording the current desktop;
`previous.tsv` preserves that login's input snapshot until the next fresh login.

Launch keys are exact initial window classes (`hyprctl clients`); values are
argument arrays, desktop-entry IDs, or `false`. Launch priority is an explicit
override, then a matching desktop entry, then a captured process command.
`false` always prevents launching, including command fallback. Auto-launch waits
`launch_delay` (default 20 seconds), skips known XDG autostarts/existing applications,
and launches at most once per application. Configure slow/custom autostarts
explicitly with `false`.

Commands are captured only for windows with no explicit override or matching
desktop entry. Native code reads the same-user process's `/proc/<pid>/exe`,
`cmdline`, and `cwd` through an open process directory. It stores the executable,
argument vector (including argv[0] and empty arguments), and working directory.
It does **not** read or save the process environment. Exited/inaccessible processes,
deleted paths, commands over 64 KiB or 256 arguments, and executable paths containing
`=` are skipped without losing the window's placement. `.capture_errors` reports
these omissions. Arguments are individually shell-quoted when launching through
`uwsm app`; their contents are not evaluated as shell syntax.

Commands must be captured while the application is running. Authenticated sessions,
browser tabs and terminal contents are not restored.
Version-specific executable/JAR paths can become stale after updates, and sandboxed
apps or apps requiring launcher-provided environment may need an explicit override.
This fallback recreates a process, not the launcher's environment or login state.

Participating native Wayland windows match by protocol session/window identities,
including the old identity retained while Chromium renumbers a restored window.
These records never fall back to titles or enumeration order. Other windows use
initial class/title fingerprints, with occurrence-order fallback at `launch_delay`.
When restoring a nonempty snapshot, startup matching stays active
for the full `restore_timeout` (default 80 seconds), even when all windows initially
match. If a matched loading window disappears, its saved record is requeued and its
replacement receives the same placement without launching another copy of the app.
Final tree/fullscreen restoration and recording wait until this observation period
ends; status reports the remaining seconds. Increase `restore_timeout` if an app's
window-replacement sequence takes longer. This applies to login and explicit cycles;
later window closures outside the restore period are not automatically restored.
A runtime marker prevents config
reloads from repeating launches/restoration. Recording samples every five seconds
and requires `stability_delay` seconds of stable topology (default 15) before saving;
shutdown stops it. Empty desktops never erase a snapshot automatically.

Each completed restore sends one standard desktop notification through `notify-send`
(`libnotify`), using your existing notification server—Quickshell on Hyprcachy—not
Hyprland's separate overlay. Notifications use normal urgency, respect Do Not Disturb,
and appear in the notification center/history. Success requests a five-second timeout;
incomplete results request twelve seconds, subject to the notification server's toast
policy (Quickshell caps toast visibility at eight seconds). Missing windows are listed
by app class (with counts), along with failed placement/fullscreen state, missing
workspaces, or unavailable/failed workspace layouts. Quickshell handles compact toast
rendering and exposes the full body in its notification center. The full list is also
available until the next report or configuration reload:

```sh
hyprctl repl 'return hyprcachy_window_session.last_restore'
```

Empty/no-op restores and ordinary config reloads do not show completion popups.
Close failures/timeouts and controller errors during restoration show a stopped
notification instead of success. Notification failures never stop the controller.
These results cover window/layout restoration, not app authentication or documents.

All three timing options use finite, non-negative whole seconds, with
`restore_timeout > launch_delay`. A zero launch delay launches on the first
one-second controller tick; zero stability delay saves on the next five-second
sample. `launch` and `ignore` default to empty tables; no other options are supported.
Ignoring a tiled window prevents capturing that workspace's complete dwindle tree.

`hyprcachy_window_session.restoring` is true during enabled startup, cycle close,
and replay, including the final layout/fullscreen/stacking operations. It becomes
false only after replay finishes (or stays true if replay stops on an error).
Fullscreen workspace rules must check this signal at event receipt and before
any deferred movement, so restored windows stay on their saved workspaces.
Manual return-location tags are preserved by the native-state codec. The shared
`hyprcachy_window_session.fullscreen_layouts` registry holds the rule's original
trees, expected remaining trees and away-window membership.

State is TSV in `$XDG_STATE_HOME/hyprcachy/window-session/` (default
`~/.local/state/hyprcachy/window-session/`), inside a mode-0700 directory. Writes
replace `current.tsv` atomically; `previous.tsv` retains the prior login snapshot.
Only the current format (`hyprcachy-window-session-v8`) is accepted. The identifier
rejects incompatible data; there are no legacy readers or migrations. Native-state
records have no separate version and are required for every saved window.
Optional `I` records bind a snapshot slot to a protocol session capability and
compositor-generated window generation. Duplicate or malformed identities reject
the snapshot; these tokens must be kept private. A failed
native-state capture prevents saving rather than overwriting a complete checkpoint
with partial state. Missing launch commands or trees still have their own error reporting.

`F` records store a fullscreen origin workspace, baseline tree, expected remaining
tree (empty when no tiled windows remain), and away slots. Both trees use snapshot
window slots, never compositor IDs. Native `remap` reuses the bounded tree parser,
prunes closed leaves and rejects duplicate bindings without touching the desktop.
The codec checks slot ownership, tiled state, away fullscreen/return tags, and
agreement with the ordinary saved workspace tree. Invalid `F` records reject the
snapshot, rather than execute or silently reinterpret it.

Automatic checkpoints, `save()` and `cycle()` include valid fullscreen baselines.
A changed/unverifiable live baseline is omitted; ignored live members are never
silently pruned into a supposedly complete baseline. After replay finishes,
window matches supply new stable IDs. A baseline is adopted only if every saved
member matched, away tags/states still agree, and the remaining live tree equals
the remapped expectation. Otherwise it is reported as skipped; returning windows
still use normal placement. Config reloads can recover the last checkpoint's
baselines by matching within workspaces and checking the live tree, without
replaying moves/fullscreen. This inherits ordinary window-matching limitations.
As with all session state, only completed checkpoints survive; queue `save()` and
wait for completion before logout if the latest change has not reached the periodic sample.

Install/rebuild and restart Hyprland to load the native `remap` helper. Incompatible
snapshots are archived as below; old in-memory baselines cannot be recovered after
the first activation. Subsequent fullscreen round trips are persisted in v8.

At controller startup, a `current.tsv` with a recognized snapshot header but a
different format is renamed to a unique `current.tsv.incompatible-XXXXXX` in the
same private directory. Existing archives are never overwritten. The controller
skips restoration and starts fresh recording of the current desktop, using the
normal stability delay; an empty desktop is still not saved automatically. A
notification/log message gives the archive path, also available as `.last_archive`.
This runs when the enabled controller starts, not inside the package installer.

Unknown/malformed headers, corrupt current-format data, oversized files, and archive
failures still stop the controller without replacing the snapshot. `previous.tsv`
and `cycle.tsv` are left untouched by this reset; incompatible recovery files are
not migrated or replayed. Archives are retained until you explicitly remove them.

Native-state records preserve pseudotiling and its size, remembered floating size,
floating stacking order, manually assigned tags, explicit per-window property
overrides, and observed windowed geometry. Rule-generated tags and values are not frozen:
Hyprland reapplies the current configuration. Only non-dynamic tags (without the
reserved `*` suffix) and core properties at `PRIORITY_SET_PROP` are checkpointed,
including opacity/override flags, borders, animation, size constraints and input/render
flags. Arbitrary third-party plugin property implementations are not serialized.
Saved manual tags/overrides replace current manual values on matched windows.

The native plugin observes non-fullscreen floating geometry at load, capture, and
render events. This is the **last observed** rectangle, not a read of Hyprland's
private fullscreen-return cache. A move immediately followed by fullscreen before
observation can therefore retain the earlier position. If no normal geometry was
observed, a fullscreen/maximized floating window is restored **fullscreen on a tiled
base** on its saved workspace. Exiting fullscreen then returns to tiling; pinning is
not reapplied to that tiled fallback. If the workspace has a saved split tree, its
subtree is retained beside the new tiled leaf under an additional 50/50 split;
if this exceeds the tree limits, default tiling is kept instead. The completion
report names the fallback. With observed geometry, the
floating rectangle is restored before fullscreen, so exiting fullscreen returns to it.
Remembered floating and pseudo sizes use logical pixels; normal floating rectangles
are normalized to monitor work areas. Floating stacking is restored bottom-to-top
among matched floating windows; native XWayland parent/transient constraints still apply.
Native state is limited to 64 KiB per window, 128 manual tags, 64 override entries and
32 colors per border gradient; the overall 512-KiB snapshot limit still applies.
**Snapshots contain launch recipes that may be executed at
login. Arguments can contain filenames, URLs or credentials even though environment
variables are never captured. Keep snapshots private and never import untrusted
ones.** Hex encoding and title fingerprints are not encryption. `.status`, `.capture_errors` and
Hyprland's logs expose failures/skipped captures.

## Persistent Wayland window identities

When enabled, the native plugin advertises **`xx_session_manager_v1` version 1**.
This is the experimental `xx-session-management-v1` revision used by Chromium.
It is application-independent, but requires a client that implements that exact
revision; it does not turn unsupported applications or XWayland windows into
protocol participants.

For Chromium, enable `chrome://flags/#wayland-session-management` (the underlying
feature is `WaylandSessionManagement`) and use native Wayland. Chromium must also
restore its own browser session/windows, for example with “Continue where you left
off”. The configuration-time load and enabled configuration shown above make the
protocol available before normal session autostarts on a fresh startup. Do not
replace that declaration with an XDG-autostart or exec-once plugin loader: late
loading cannot retroactively register an already-open browser's windows. A browser
opened before a manual late enable/load may need restarting. No browser settings
or flags are changed by this package, and it still launches once per app, not per window.

The protocol remembers initial configure sizes and persistent identities in the
private, atomically replaced mode-0600 `protocol.tsv`. Creation/removal is saved
before acknowledging the request; size changes are batched over 250 ms and flushed
at orderly plugin shutdown. A crash can lose the latest pending size update.
Recognized restores apply the saved size and send the protocol's `restored` event
after the initial empty surface commit, before the initial toplevel configure.
The existing Lua controller then uses those identities for desktop placement,
dwindle trees and fullscreen restoration during its normal startup/cycle window;
this is not a separate perpetual workspace-restoration daemon.

Session capabilities and window generations are random 256-bit values. Window
generations prevent a client reusing a deleted name from inheriting an unrelated
old snapshot slot. Chromium removes the old name and adds a new name before mapping;
the bridge retains the old restore identity on that physical toplevel for matching,
while subsequent captures save its new identity. Same-client duplicate sessions,
duplicate live names and late restore requests are rejected. Another connection
with the session capability can take over; the prior session becomes inert.
`ignore` classes also suppress protocol size restoration/tracking once their Wayland
app ID is known; an application may register its capability before setting that ID.

Explicit session/toplevel removal forgets the associated protocol state. Destroying
a session object freezes it, while disconnecting preserves its last checkpoint.
An explicit `xdg_toplevel.destroy` while its session is active removes that window.
Consequently a graceful close-and-restore cycle may lose protocol identities: this
is required protocol removal semantics, not permission to guess by title. Missing
identities are reported as unmatched. Browser tabs, documents, authentication and
application session bookkeeping remain application-owned.

Limits are 128 stored sessions, 256 stored/live managed windows, 1024 live protocol
objects, 512-byte client names and a 512-KiB protocol checkpoint. Corrupt, oversized
or unsafe checkpoint files fail closed, without replacing them. Keep backups before
resetting `protocol.tsv`, and only reset it with Hyprland stopped; forgetting the
capabilities also breaks identity matching with older desktop snapshots.

The service survives configuration reloads once enabled, preserving existing client
objects. To disable it entirely, set `enabled = false` and start a new graphical
session. Do not hot-unload it with connected clients. On the first v8 activation,
the old v7 desktop snapshot is archived rather than guessed/migrated; let participating
apps register and save a fresh checkpoint before expecting identity-based restoration.

## Explicit close-and-restore cycle

Wait until the controller is recording, then run:

```sh
hyprctl repl 'return hyprcachy_window_session.status'
# WARNING: requests closure of your current session-managed app windows.
hyprctl eval 'hyprcachy_window_session.cycle()'
```

This saves the current layout and launch recipes to both `current.tsv` and a
separate `cycle.tsv` recovery snapshot before requesting graceful closure. Ignored,
hidden and special-workspace windows are excluded. **This explicit command overrides
`launch = false` and login-autostart suppression**: autostarts will not run again in
the current session. Explicit launch commands still take priority; otherwise a
desktop entry or captured process command is used. Automatic login restoration
continues to respect `launch = false`.

Capture errors (including incomplete trees) or missing launch recipes abort before
any windows are closed. Save your work first: an available recipe does not guarantee
successful relaunch, and application documents/authentication remain app-owned.
Once all targeted windows disappear, the existing restore loop runs with your normal
launch delay, restore timeout, matching and tree restoration. Its one-launch-per-class
limit still applies; applications must recreate additional windows themselves.
The operation runs inside Hyprland, so closing the invoking terminal does not stop it.

Nothing is force-killed. If closure fails or windows remain after 60 seconds, the
controller stops with recording paused and the snapshot intact. Resolve any
unsaved-work dialogs, then retry restoration **without another close request**:

```sh
hyprctl eval 'hyprcachy_window_session.restore_cycle()'
```

Normal recording resumes when restoration finishes. Config reloads interrupt the
in-memory operation, so avoid reloading while it runs. The recovery `cycle.tsv`
survives reloads and normal recording, and remains available to `restore_cycle()`;
only another explicit cycle overwrites it. Keep it private like other snapshots.

## Upgrades and removal

See [the package guide](README.md) for guarded updates,
startup integration and removal. Rebuild/reinstall the packages and reboot after
replacing native code; a configuration reload cannot replace the loaded binary. Removing the package does not delete private snapshots.

## Known limits

- Special/hidden windows and groups are not restored. A workspace containing
  ignored/hidden tiled leaves cannot have its complete tree recorded. Groups require
  group-target/member bindings rather than one window per dwindle leaf; special
  workspaces require separate identity/visibility handling. These are explicit
  exclusions, not limitations imposed by Hyprland itself.
- Multiple indistinguishable windows in non-participating apps remain ambiguous
  across boots. Protocol identities avoid that ambiguity only when the application
  retains its session and explicitly restores the corresponding windows. Layout
  restoration is not restoration of application contents.
- Trees are bounded to 511 nodes, 128 levels, 32 KiB and split ratios `[0.1, 1.9]`.
- Monitor changes scale/clamp floating geometry. Workspace moves affect every
  window on that workspace. Fullscreen return geometry uses the observation/fallback
  policy above; pixel-identical rendering also requires matching monitor/gap settings.
- The close/shutdown debounce is a heuristic; use explicit checkpoints when needed.
  One active graphical session per user and local XDG directories are assumed.
