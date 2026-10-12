# Guarded tmux companion

`hyprcachy-tmux` supplies a patched executable alongside the distribution's tmux.
It adds `status-position split`: with two or more status rows, row zero appears
above the panes and the remaining rows below. With one row, it behaves like
`bottom`. Existing `top` and `bottom` modes remain available. Formatting, session
ranges, mouse bindings, prompts and status jobs remain native tmux features.

Dotfiles display named sessions in the top row, highlight the current session,
and retain the existing dotbar/TSM window bar below. This is not a real pane and
adds nothing to resurrect snapshots.

## Install from this checkout

```sh
./rebuild-tmux.sh  # companion only; requires an installed compatible guard
cd ~/dotfiles
./install.sh jackhome  # substitute your machine profile
```

Tmux depends on [hyprcachy-upgrade-guard](../upgrade-guard/), not on the
window-session plugin or Hyprland. This command builds and installs only the
companion; it does not rebuild the guard or update another component. Missing
prerequisites (including the guard's required version) stop the command.
Use `./update-native.sh` to prepare a full system upgrade together with all three
local packages, then reboot. It builds against the incoming tmux archive before
installing the complete frozen upgrade in one guarded transaction; it does not
try the 3.8 patch against an installed 3.7 tmux first. This coordinated command also installs window-session if absent;
it is not a tmux-only install.
Install missing distribution prerequisites through your normal full system update.

`setup.sh` also uses the coordinated path when a native component is installed,
before its ordinary installing system upgrade. Fresh setups install prerequisites
first. Both paths build from the user-owned `~/hyprcachy` tree; the recorded source
directory is never a temporary setup directory. Setup does not fetch Hyprcachy or
ask the unprivileged builder to run sudo.

These commands require your approval/password for package installation. They do
not restart tmux. The new feature requires a **new tmux server**; merely attaching
a new terminal, reloading configuration, or logging out while the old server
survives does not replace it. Finish/save your work before deliberately stopping
the old server. The login service still leaves any existing server alone and
restores the selected resurrect `last` snapshot only when starting a new one.

The dotfiles launcher `~/.local/bin/tmux` chooses `/usr/bin/hyprcachy-tmux` when
installed, otherwise stock tmux. A UWSM `env.d/60-tmux` entry puts that launcher
first after loading the login environment, before graphical apps start. The login
service uses its absolute path. For a shell outside that environment, put
`~/.local/bin` before `/usr/bin`, or call `hyprcachy-tmux` explicitly.

## Component ownership

This directory owns `tmux-source`, the patch, `build`, the launcher, and
`upgrade-adapter`. The package installs its adapter and source-fetch helper under
`/usr/lib/hyprcachy/upgrade.d/hyprcachy-tmux/`; they are not supplied by the guard.
The adapter declares source preparation, builds/checks, watched packages and the
ordered binary/version outputs. The shared engine only invokes that interface.

## Ordinary upgrades

Continue using `sudo pacman -Syu`. The independent shared transaction guard
handles incoming tmux/companion packages and guard updates when this companion
is installed:

1. Preserve the exact selected package archives, signatures, databases and pacman
   command as before. Unrelated upgrades do not trigger a tmux build.
2. Freeze `build` and `split-status.patch` from the local checkout recorded when
   this companion was built (normally `~/hyprcachy/packages/tmux`). Local edits are
   included. Read them as the checkout owner, not root; reject missing, oversized,
   symlinked or changing files. The sandbox gets copies, never a home-directory bind.
   Nothing fetches or pulls Hyprcachy from GitHub. Verify the stock tmux package's signature. Retrieve its packaging recipe and
   require its SHA-256 to equal the signed package's `.BUILDINFO` digest. CachyOS's
   package-release adjustment is accepted only when the resulting digest matches.
3. Fetch the matching upstream Git tag and packaging files. In the disposable
   Btrfs/nspawn candidate, makepkg verifies strong source digests (no `SKIP`)
   and applies distribution patches before our zero-fuzz patch.
4. Build as an unprivileged user with networking disabled. Use private, clean
   tmux sockets to check actual top/bottom rendering and pane placement. No user
   tmux configuration, default socket, snapshots or graphical compositor is used.
5. Refuse the host transaction if any step fails. Recheck the frozen transaction,
   fetched inputs and artifacts before authorizing it.
6. After a matching successful commit, atomically replace only the companion
   executable, then its stock-version marker. Never overwrite `/usr/bin/tmux`.

The Hyprland check runs only when its component is installed or incoming and a
native dependency, that component, or the guard changes. It remains compile-only. The existing lock, timeouts and guarded seven-day
staging cleanup are shared; there is no daemon, timer or second host transaction
for tmux updates. Existing tmux servers are never restarted by these hooks.

The patch targets tmux 3.8's redraw and prompt APIs; the old 3.7c patch is not
retained. The build checks split-status rendering and pane origin using private
servers; these bounded checks are not an exhaustive tmux regression suite.

Routine compatible updates are automatic, **not automatic patch repair**. A
changed source origin, unrecognized downstream recipe, unsigned local tmux
archive, patch conflict or failed build/check stops the upgrade for review. An
offline update also needs the required sources to be available; this prototype
fetches them for each guarded build rather than maintaining another source cache.
These are upstream tmux sources, not Hyprcachy patch updates. Keep the recorded
checkout available; rebuilding the companion from a moved checkout updates its
recorded path. Missing local sources never fall back to the installed old patch.
Recipe downloads get two bounded retries, including DNS failures. If no recipe
was downloaded, the error reports a download failure rather than a hash mismatch;
fix connectivity and retry the original command without disabling hooks.
Component-only rebuilds need the exact signed installed tmux archive in pacman's
cache, or the same version still available from the configured mirror. They do not
upgrade distribution packages; use `./update-native.sh` when the current patch needs
an incoming tmux version. Its driver supplies the exact target through
`HYPRCACHY_TMUX_PACKAGE`, preserving the same signature and recipe verification.
Repository replacement transitions cannot be translated faithfully to a local `-U`
transaction, so the coordinated script rejects them; ordinary `pacman -Syu` retains
its normal replacement handling. Install this updated companion/adapter once to
enable local-source hooks; changing files in an older checkout alone cannot update
an already installed old adapter.

If publication fails after pacman has committed, the running server is untouched.
The launcher refuses an executable whose recorded stock version is no longer
installed. Repair with `sudo pacman -S tmux` (without `--needed`) after fixing the
reported problem. Logs and retained staging paths are reported by the shared
guard in `/var/log/hyprcachy-upgrade.log`.

The companion's own package version tracks our patch/guard integration; its
executable tracks the stock tmux package independently. As with the session
plugin, a generated executable may differ from the companion package's original
file checksum after an upgrade. The stock tmux package remains unmodified.

Remove `hyprcachy-tmux` normally to disable this integration. Subsequent new
servers use stock tmux and the configuration keeps its ordinary bottom bar.
Neither removal nor installation terminates an already running server.
