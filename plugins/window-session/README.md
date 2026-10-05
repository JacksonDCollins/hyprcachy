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

## Build and install

Prerequisites are Hyprland's installed development headers, GCC, make, pkgconf
and Arch's usual `base-devel` packaging tools. The upgrade gate additionally uses
Btrfs, systemd-nspawn, pacman-contrib (`pactree`) and util-linux. These are native
build/isolation tools, not a session daemon. No test compositor or GPU access is
required. Lua is already a Hyprland dependency; no Lua CLI is used.
Runtime launches use the existing `uwsm app` path. Process-command fallback uses
GNU coreutils 9.5+ `env` to preserve the working directory and argv[0].

```sh
cd ~/hyprcachy
./rebuild-plugin.sh
```

Run without `sudo`: `makepkg` builds as your user and prompts for privilege when
installing dependencies or the finished package. The command uses the current
local files (including uncommitted changes), performs a clean rebuild, and reinstalls
even if the version is unchanged. Normal pacman compatibility hooks still run.
Build work directories are cleaned on success; the package archive is retained.
Extra arguments are forwarded to `makepkg`. It does not reload the live plugin.

Package builds and the upgrade gate are compile-only: no tests or compositor
harness are run. After replacing native code, restart the graphical session;
a configuration reload cannot replace the already loaded binary.

The gate requires a genuine nspawn container and matching transaction inputs.
Only the trial pacman invocation uses `--disable-sandbox-network`: nspawn already
provides the private network and drops `CAP_SYS_ADMIN`, which prevents creating a
second network namespace. Pacman's other sandbox features and the host's pacman
configuration are unchanged.

Hyprcachy's `setup.sh` also builds
and installs this local package as the selected user, never builds as root, and
fails visibly on incompatible source/API changes rather than skipping the plugin. Two-script ISO installs fetch
this repository's published `main` sources; publish the plugin before using that
path. Normal cloned-repository setup uses its local sources. For an existing
system use `setup.sh`, **not the disk-partitioning `install.sh`**.

The package owns `/usr/lib/hyprcachy/window-session/`,
`/usr/share/hyprcachy/window-session/`, root-owned source in
`/usr/src/hyprcachy-window-session/` (only `plugin.cpp`, its three headers and
`Makefile`), four pacman hooks, and
`/etc/xdg/autostart/hyprcachy-window-session.desktop`. At the next login, Hyprcachy's
UWSM session runs that entry to load the native plugin with `hyprctl plugin load`.
There is no launcher script, extra daemon, or dotfiles loader. Loading the plugin
registers its configuration API; restoration remains **opt-in**.

A post-transaction hook refreshes running systemd user managers when the autostart
entry changes, using Arch's existing systemd helper. This
regenerates the startup unit without loading/reloading the plugin in a live desktop.
A user manager can survive a graphical logout when another login session remains;
without the refresh, the new entry may stay undiscovered across logins.
To recover an already running session with **no plugin loaded**:

```sh
systemctl --user daemon-reload
systemctl --user start 'app-hyprcachy\x2dwindow\x2dsession@autostart.service'
hyprctl plugin list
```

Hyprland reloads its configuration after loading the plugin, so a guarded settings
block skipped during initial startup is applied once the native API exists. The
plugin starts its embedded-Lua controller after configuration processing finishes.
The autostart entry is restricted to `XDG_CURRENT_DESKTOP=Hyprland`. Standalone
sessions must provide XDG autostart support or explicitly load the native `.so`
using Hyprland's plugin loading API. If plugin permission management is enabled,
Hyprland may ask for approval; this package does not bypass permission policy.

Do not also manage this plugin with `hyprpm`: pacman owns its source, compiled
artifact and compile-only upgrade gate. Other unrelated plugins can use `hyprpm`.
Dotfiles contain settings only.

## Enable restoration

Configure it directly in `hyprland.lua` or a Lua module sourced by that config:

```lua
hl.config({
    general = { layout = "dwindle" },
    dwindle = { preserve_split = true },
})

if hl.plugin.window_session and hl.plugin.window_session.config then
    hl.plugin.window_session.config({
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
end
```

Keep the guard shown above: the plugin may not have loaded yet or may be absent.
No `dofile` call is needed. Call `config` once per reload, supplying the complete options table.
Without a call (or without `enabled = true`), restoration is disabled even though
the native plugin is loaded. `hyprctl plugin list` shows whether it is loaded.
Keep `dwindle.preserve_split = true`. Once the native plugin is loaded, configuration
reloads apply settings without repeating restoration in the same session. With defaults, the first automatic save
needs about **20 seconds** of stable topology. Saving is sampled every five seconds,
so custom stability delays are rounded up to a sampling tick after a change is observed.

```sh
hyprctl repl 'return hyprcachy_window_session.status'
hyprctl eval 'hyprcachy_window_session.save()' # explicit checkpoint, even empty
```

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

Matching uses initial class/title fingerprints, with occurrence-order fallback
at `launch_delay`. When restoring a nonempty snapshot, startup matching stays active
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
Only the current format (`hyprcachy-window-session-v7`) is accepted. The identifier
rejects incompatible data; there are no legacy readers or migrations. Native-state
records have no separate version and are required for every saved window. A failed
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
As with all session state, only completed checkpoints survive; use `save()` before
an immediate logout if the latest change has not reached the periodic sample.

Install/rebuild and restart Hyprland to load the native `remap` helper. Incompatible
snapshots are archived as below; old in-memory baselines cannot be recovered after
the first activation. Subsequent fullscreen round trips are persisted in v7.

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

## Upgrade safety and removal

Use your normal update command—there is no upgrade wrapper or separate check-only
command:

```sh
sudo pacman -Syu
# yay/paru updates also work when they invoke the standard pacman CLI.
sudo pacman -U ./reviewed-package.pkg.tar.zst
```

Compilation is gated only when the transaction touches this package or the
installed dependency closures of its native build roots: `hyprland`, `lua`,
`gcc`, `make` and `pkgconf`. Dependencies needed only by maintenance/startup tools
(e.g. `device-mapper` through those tools) do not trigger a compatibility build.
The hooks still observe package names to detect relevant changes; unrelated
transactions are skipped before command replay or archive/provider checks.

For a relevant transaction:

1. The first pre-hook records actual incoming package names. Pacman has already
   resolved/downloaded the transaction and still owns its database lock.
2. The second pre-hook re-prepares the original command against those frozen
   databases, **without refreshing or downloading again**. It requires the same
   incoming names, verifies repository archive hashes/signatures, and copies the
   already-downloaded archives (or local `-U` files) into private staging.
3. A disposable Btrfs snapshot/nspawn container replays the transaction. Incoming
   and removed target sets must agree with the real pending transaction. Package
   scripts and system hooks are masked inside the container only.
4. Compile the native plugin against the **incoming headers/libraries**, as an
   unprivileged user. Do not run tests, load the plugin, start any compositor or
   access GPU devices.
5. Before returning success, verify unchanged databases, configuration, original
   package files and compiled artifacts. Delete the scratch root. `AbortOnFail`
   stops pacman if any preflight step fails; no host lock is removed or replaced.
6. Pacman commits its original transaction normally, preserving its dependency
   reasons and choices. The post-hook checks installed versions and publishes
   only the preflight-compiled binary. It performs no build after the upgrade.

The hooks do not receive package versions directly. Replaying a different
selection is therefore **refused**, not treated as a successful preflight: unsupported
CLI options/frontends, changed inputs, or non-default provider/group selections
that cannot be reproduced abort with an error. Ordinary repository overlap is not
itself ambiguous: named packages/dependencies use pacman's repository priority.
For literal arguments, the gate inspects incoming archive dependency metadata
(including local `-U` archives); unused `Provides` entries do not imply a provider
choice. Potential virtual-provider choices, replacements of installed packages,
and IgnoreGroup overrides still require identity checks. Same-named candidate
builds that cannot be distinguished from hook data require repository-qualified
literal targets. These conservative checks do not guess an interactive selection. IgnoreGroup overrides
combined with group/virtual targets cannot be replayed safely either. Specify the
chosen `repo/package` in your normal pacman command rather than letting the gate guess. Custom roots,
custom pacman configuration, stdin target lists, remote `-U` URLs and direct
libalpm GUI frontends are currently unsupported. Standard `pacman -Syu`, explicit
repository targets, local `-U`, and helpers invoking those commands are supported.
Repository archives require SHA-256 metadata and a PGP signature; local packages
retain pacman's configured local signature policy. Do not modify configuration
or package files concurrently with an upgrade.

**Compilation or transaction-integrity failure aborts before installed packages
or the existing plugin binary are changed.** Repository metadata and the
download cache can change. Errors are logged to
`/var/log/hyprcachy-window-session-upgrade.log`. Fix the source or build environment,
then retry. There is no fixed Hyprland allowlist. API changes can still require
code changes. **Successful compilation does not prove runtime compatibility,
correct restoration, or absence of compositor crashes.**

Unrelated package operations skip the expensive preflight. `setup.sh`, `chwd`,
and AUR helpers need no wrapper integration: their ordinary pacman transactions
hit the same hooks. First installation does not retroactively run newly installed
pre-hooks; the plugin remains opt-in until separately validated.

The gate requires the normal Hyprcachy Btrfs root/database layout, free snapshot
space and a working nspawn environment. No GPU/display/input devices, host
Wayland sockets or user homes are bound into the build environment. Compilation
runs unprivileged; the container has no network. If the build environment cannot
run, the upgrade fails closed. Runtime, driver and kernel compatibility are not
tested by this gate.

The gate is **not** a filesystem transaction or rollback mechanism: an unrelated
package script, disk error or interruption after pacman starts committing can
still leave a partial upgrade. Post-commit publication errors are reported, not
misrepresented as a cancelled update; compiled artifacts are retained for recovery.
Failed/aborted transactions can leave root-only staging data at the path printed
in the error log. Abrupt termination can also leave a pacman lock or scratch
snapshot. The package installs and activates the system timer
`hyprcachy-window-session-cleanup.timer`. It checks daily (with up to one hour of
random delay) for staging data older than **seven days** since its last hook exit.
Successful transactions still clean up immediately.

Cleanup shares an exclusive lock with the transaction hooks, defers while pacman
or nspawn is running or the pacman database lock exists, and skips stages whose
recorded PID still exists. Only root-owned, mode-0700 staging directories matching
the plugin's fixed naming scheme are eligible. Mounted paths, symlinks, unexpected
roots and nested subvolumes are retained for inspection. A recognized scratch
Btrfs subvolume is deleted with `btrfs subvolume delete --commit-after`, never
recursive file deletion; only then can the remaining staging files be removed.
An old reused PID can delay cleanup. Unexpected or damaged staging directories
may still need manual attention. The hooks and cleanup **never remove pacman's
lock**, saved layouts, or unrelated package caches.

The timer is package-owned and enabled for boot; installation/upgrades start it on
a running host. Chroot installs leave activation to the next boot. Uninstall stops
and removes the timer and service; it does not purge retained user/recovery data.
No desktop restart is needed for this housekeeping change.

```sh
systemctl list-timers hyprcachy-window-session-cleanup.timer
journalctl -u hyprcachy-window-session-cleanup.service
# Optional: run the same age-limited, guarded cleanup now.
sudo systemctl start hyprcachy-window-session-cleanup.service
```

The latest upgrade log is overwritten each preflight, not accumulated. Temporary
development builds under `/tmp` follow the system's normal temporary-file policy.
Manual
library replacement, disabling hooks, or explicit removal of the plugin bypasses
this protection. Keep normal system backups/snapshots.

The native plugin checks both the running compositor's commit and its ABI hash. Restart Hyprland after successful upgrades; no hot replacement is done.
Remove the configuration call, or set `enabled = false` in it, and reload to
stop recording/restoring (the upgrade gate
remains installed). `sudo pacman -R hyprcachy-window-session` explicitly removes
both the plugin and gate; private desktop snapshots remain.

## Known limits

- Special/hidden windows and groups are not restored. A workspace containing
  ignored/hidden tiled leaves cannot have its complete tree recorded. Groups require
  group-target/member bindings rather than one window per dwindle leaf; special
  workspaces require separate identity/visibility handling. These are explicit
  exclusions, not limitations imposed by Hyprland itself.
- Multiple indistinguishable windows remain ambiguous across boots. This restores
  layout structure for the matched windows, not application contents or identity.
- Trees are bounded to 511 nodes, 128 levels, 32 KiB and split ratios `[0.1, 1.9]`.
- Monitor changes scale/clamp floating geometry. Workspace moves affect every
  window on that workspace. Fullscreen return geometry uses the observation/fallback
  policy above; pixel-identical rendering also requires matching monitor/gap settings.
- The close/shutdown debounce is a heuristic; use explicit checkpoints when needed.
  One active graphical session per user and local XDG directories are assumed.
