# Window-session package

This directory contains the complete `hyprcachy-window-session` component:
native C++/Lua implementation, Makefile, PKGBUILD and upgrade adapter. No external source
symlinks or separate plugin directory are needed.

See [the plugin guide](plugin-README.md) for configuration, snapshot semantics
and restoration limits. Both guides are installed in
`/usr/share/doc/hyprcachy-window-session/`.

## Build and install

Prerequisites are Hyprland's installed development headers, GCC, make, pkgconf,
Wayland (including `wayland-scanner`) and Arch's usual `base-devel` packaging tools. The upgrade gate additionally uses
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
use `./update-native.sh` for an explicit guard update with both components.
Missing distribution prerequisites are reported; install them through your normal
full system update before retrying. The command uses the current
local files (including uncommitted changes), performs a clean rebuild, and reinstalls
even if the version is unchanged. Normal pacman compatibility hooks still run.
Build work directories are cleaned on success; the package archive is retained.
Extra makepkg arguments are not accepted. It does not reload the live plugin.

Plugin builds and the plugin compatibility check are compile-only: no tests or
compositor harness are run. Rebuild/reinstall the packages, then **reboot**;
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
`/usr/src/hyprcachy-window-session/` (native sources, headers, protocol XML and
`Makefile`; generated bindings stay in the build directory). Transaction hooks
belong to the shared upgrade guard; this component ships no migration hooks.
Dotfiles call `dofile("/usr/share/hyprcachy/window-session/init.lua")({ ... })`.
This package-owned function declares the native load and handles the first-pass
API guard; dotfiles contain only the call and settings. See the runtime guide
for the complete example. The package must be installed before using that call.
There is no shell launcher, extra daemon, or XDG-autostart loader. Restoration
and protocol advertisement remain **opt-in** through `enabled = true`.

Configuration-declared plugins load during native compositor initialization,
before systemd `READY=1`, the Wayland event loop and first-frame exec-once handlers
in the supported Hyprland startup sequence. `PLUGIN_INIT` prepares the private
state directory and loads only the bounded `protocol.tsv` store, outside Lua
callbacks. This small critical read can delay compositor startup on slow storage;
it does not run under, extend or bypass a Lua callback deadline. No protocol global
is advertised yet. A subsequent startup config reload calls `config(enabled=true)`
and publishes the prepared protocol synchronously, before startup proceeds.
Existing clients cannot race desktop-file discovery because that work comes later.
An incompatible/unpermitted installed plugin or invalid store fails visibly; no empty
replacement store is substituted. A missing package snippet is a configuration
error. This ordering assumes successful early loading
and enabled configuration; a late manual load cannot repair an already-open client.
Loading while disabled may prepare the private directory/store, but advertises no
protocol and starts no restoration.

`file-worker.hpp` keeps desktop-file discovery/parsing and desktop snapshot
I/O/codecs off the compositor thread. The timer only resumes continuations after
completed work; Hyprland's callback watchdog limits are unchanged. No extra app
startup dependencies or readiness polling services are installed. If plugin
permission management is enabled, permission must be granted; this package does
not bypass that policy.

Reinstalling the package removes files it no longer ships. The required reboot
regenerates systemd user services and activates the new native code. There is no
live-session migration or automatic cleanup of user-owned overrides. Remove any
separately created duplicate loader from your own configuration.

Do not also manage this plugin with `hyprpm`: pacman owns its source, compiled
artifact and compile-only upgrade gate. Other unrelated plugins can use `hyprpm`.
Dotfiles contain the snippet call and settings, not loading implementation.

## Upgrade safety and removal

The independent [shared upgrade guard](../upgrade-guard/) owns
transaction replay, integrity checks, hooks and cleanup. This package contains
the native plugin, controller, early protocol bootstrap, rebuild sources and its own
`upgrade-adapter`. That adapter owns dependency watching, compile-only checks
and the artifact declaration. The shared engine has no plugin build logic.
It depends on the guard, not on tmux; native restoration code is unchanged by
the package split.

Use normal `sudo pacman -Syu` updates. The guard compile-checks this component
when its native dependency closures change, or this package or the guard is
updated. Successful compilation is not a runtime/compositor test. See the
guard documentation for failure handling, transaction limits and cleanup.

`./update-native.sh` explicitly builds and installs the guard, plugin and tmux
companion in one transaction. `./rebuild-plugin.sh` only rebuilds this plugin and
never initiates that coordinated update. Reboot after installation. Automatic
migration from obsolete bundled guards is not supported; rebooting does not
repair an incompatible guard that blocks installation.

The native plugin checks both the running compositor's commit and its ABI hash.
Reboot after successful upgrades; no hot replacement is done.
Remove the configuration call, or set `enabled = false` and reload, to stop
the desktop snapshot controller. Once advertised, the session-management protocol
service survives configuration reloads for connected applications; start a new
graphical session with restoration disabled to stop that service too. Do not hot-unload
the plugin while applications hold its protocol objects: unloading destroys those
objects and can disconnect their Wayland connections. Keep the snippet call
until logout: removing it on reload also unloads a config-owned plugin.
Uninstall after ending the graphical session, or keep config auto-reload disabled
until restart. `sudo pacman -R hyprcachy-window-session` removes only this
component; the shared guard still protects an installed tmux companion.
Private desktop snapshots and `protocol.tsv` remain untouched.

## Session-management protocol source

The vendored `xx-session-management-v1.xml` is the experimental version currently
used by Chromium, not a claim to implement a finalized `xdg-session-management`
standard. Its copyright/license notice is preserved in the XML.

- Source: Chromium `a061f192b7a947d106f39aa8293a58aebaa59553`,
  `third_party/wayland-protocols/unstable/session-management/xx-session-management-v1.xml`.
- SHA-256: `44598db2469011d2457d88c6e2f7c48fef4f79c71ce7764b0d14de8ab981cf03`.

Bindings are generated locally/offline by `wayland-scanner`. The upgrade adapter
watches Wayland as well as Hyprland. Builds stop for review if Hyprland's SDK gains
session-management bindings, rather than blindly advertising a competing global.
See the plugin guide for client activation and persistent identity limitations.
