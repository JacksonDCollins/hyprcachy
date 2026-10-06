# Window-session package

This directory contains the complete `hyprcachy-window-session` component:
native C++/Lua implementation, Makefile, PKGBUILD, upgrade adapter, lifecycle
hooks, legacy upgrade handoff and XDG autostart entry. No external source
symlinks or separate plugin directory are needed.

See [the plugin guide](plugin-README.md) for configuration, snapshot semantics
and restoration limits. Both guides are installed in
`/usr/share/doc/hyprcachy-window-session/`.

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
installing only this plugin. The guard must already satisfy the package dependency;
use `./update-native.sh` for an explicit guard migration/update with both components.
Missing distribution prerequisites are reported; install them through your normal
full system update before retrying. The command uses the current
local files (including uncommitted changes), performs a clean rebuild, and reinstalls
even if the version is unchanged. Normal pacman compatibility hooks still run.
Build work directories are cleaned on success; the package archive is retained.
Extra makepkg arguments are not accepted. It does not reload the live plugin.

Plugin builds and the plugin compatibility check are compile-only: no tests or
compositor harness are run. After replacing native code, restart the graphical session;
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
`Makefile`), two component-owned post-transaction hooks, and
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

## Upgrade safety and removal

The independent [shared upgrade guard](../upgrade-guard/) owns
transaction replay, integrity checks, hooks and cleanup. This package contains
the native plugin, controller, autostart integration, rebuild sources and its own
`upgrade-adapter`. That adapter owns dependency watching, compile-only checks
and the artifact declaration. The shared engine has no plugin build logic.
It depends on the guard, not on tmux; native restoration code is unchanged by
the package split.

Use normal `sudo pacman -Syu` updates. The guard compile-checks this component
when its native dependency closures change, or this package or the guard is
updated. Successful compilation is not a runtime/compositor test. See the
guard documentation for failure handling, transaction limits and cleanup.

`./update-native.sh` explicitly builds and installs the guard, plugin and tmux
companion in one transaction, including migration from the installed bundled
guard. `./rebuild-plugin.sh` only rebuilds this plugin and never initiates that
coordinated update. No manual file overwrites, package removal or hook disabling
is needed for migration.

The component-owned `legacy-post` and old-named post-hook finish a build already
authorized by the original 0.7 guard during that migration. They never replay
transactions and do nothing without that old approved state. The plugin's upgrade
script stops its old cleanup units; the shared engine uses separately named
`hyprcachy-upgrade-*` hooks, state and units. No legacy paths or plugin knowledge
are built into the shared engine.

The native plugin checks both the running compositor's commit and its ABI hash.
Restart Hyprland after successful upgrades; no hot replacement is done.
Remove the configuration call, or set `enabled = false` and reload, to stop
recording/restoring. `sudo pacman -R hyprcachy-window-session` removes only this
component; the shared guard still protects an installed tmux companion.
Private desktop snapshots remain untouched.
