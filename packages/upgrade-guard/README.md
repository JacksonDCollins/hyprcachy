# Shared upgrade transaction engine

This package contains transaction machinery only. It does not know any
component's source URL, patch, compiler command, build dependencies, output
names or version-marker rules. Each native package owns its own adapter and
preparation helpers under `/usr/lib/hyprcachy/upgrade.d/<package>/`.

The engine lives in `/usr/lib/hyprcachy/upgrade-guard`, uses
`/run/hyprcachy-upgrade-guard`, logs to `/var/log/hyprcachy-upgrade.log`, and owns
`hyprcachy-upgrade-cleanup.timer` plus the `*-hyprcachy-upgrade-*.hook` files.
There are no component-named runtime directories or units in this package.

## Adapter API v1

A registration is a flat directory owned by its `hyprcachy-*` package. It contains
an `adapter` Bash script and optional preparation helpers. These are trusted,
reviewed package code, **not user-editable configuration or transaction data**.
The engine never sources transaction manifests.

The adapter implements four actions:

- `watch`: print additional package names whose changes require rebuilding.
  The engine automatically watches the component itself and guard updates.
- `prepare INPUT PACKAGES`: fetch/verify sources into the empty INPUT directory.
  PACKAGES contains the exact frozen incoming archives. This runs on the host
  before snapshot creation, with networking and a five-minute timeout.
- `build INPUT OUTPUT`: compile/check in the replayed candidate, offline, as UID
  65534 with no-new-privileges and a five-minute timeout. INPUT is read-only to
  the build user; OUTPUT, a clean home and the candidate's temporary space are
  available for compilation.
- `artifacts`: print ordered tab-separated `filename`, `0644|0755`, and absolute
  destination rows. Destinations must be files owned by that component below
  `/usr/lib/hyprcachy/`. A component declares any version marker last.

Host actions run as root, like the hooks they extend. Review package adapters
before installation. New adapters are taken only from the frozen archives of the
real, already-prepared pacman transaction, not a second repository selection.
Preparation tools must already be installed: incoming dependencies are not yet
available on the host. The rebuild helpers check prerequisites first; install
missing tools through your normal full system update, then retry.

An incoming registration replaces its installed instructions before preparation.
Only flat payload files are copied out of archives; archive paths are not
extracted into the host. A selected component cannot silently drop its adapter.
Removed components are skipped independently. The native package namespace is
reserved for registration discovery: incoming `hyprcachy-*` packages are inspected
even when not registered yet. Other unrelated transactions skip before replay.
If inspection finds no work, no candidate container is started.

## Transaction safety

Continue using ordinary `pacman -Syu`, explicit repository targets, or local
`pacman -U` files. Helpers work when they invoke the standard pacman CLI.

CachyOS pacman isolates hooks from the network by default. Only the preflight
hook declares `NetworkAccess = allowed`, because adapters fetch verified sources
before the candidate starts. Incoming/publication hooks remain isolated, and the
candidate still uses `systemd-nspawn --private-network`. Do not disable pacman's
network sandbox globally to fix source preparation.

The supported installed guard must already provide this declaration. Setup does
not repair obsolete hook formats or create administrative overrides. An older
guard can block installation before reboot; that requires explicit repair, not
bypassing the current safety checks.

1. Record the real incoming/removed target sets while pacman holds its lock.
2. Re-prepare without refreshing databases or downloading packages again.
   Require the same selection and freeze the already-prepared package archives,
   signatures, original files, command and database/configuration fingerprints.
3. Freeze applicable adapters, prepared inputs and publication declarations.
   Hash them before creating the disposable Btrfs/nspawn candidate.
4. Replay exactly that transaction with package scripts and system hooks masked.
   Verify target sets, then run the selected adapters' offline build actions.
5. Verify artifacts, ownership, controls and original transaction inputs. Delete
   the scratch root before permitting the original transaction to commit.
6. After commit, verify installed versions and hashes again. Validate every
   declared artifact before atomic per-file publication in declaration order.
   Do not rebuild, reload applications or restart servers after commit.

The engine provides one replay and one lock for all components. It requires the
normal Btrfs system-root/database layout, free snapshot space and working nspawn.
It does not bind host home directories, display sockets or GPU devices. Component
checks define compatibility coverage; compilation is not a runtime guarantee.

Unsupported frontends/options, custom roots/configuration, stdin package lists,
remote `-U` URLs, unreproducible provider/group choices, changed inputs or failed
builds abort before commit. Literal dependencies follow repository priority;
ambiguous replacements/provisions require explicit `repo/package` targets.
Repository archives require signature and SHA-256 metadata; local archives keep
pacman's local signature policy. Components may require stricter source trust.
Never modify package files or configuration concurrently with an upgrade.

This is not a filesystem rollback: disk errors, package scripts or interruption
after commit starts can leave a partial upgrade. Publication errors are reported
and artifacts retained, not described as cancelled transactions. Publication is
atomic per file, not across multiple components. Keep normal system backups.
First installation of the engine cannot retroactively execute its pre-hooks.

## Retention and installation

The daily timer (up to one hour of jitter) removes inactive staging directories
older than seven days under `/var/cache/hyprcachy-preflight.*`. This generic cache
prefix identifies the guard's staging data. It checks root ownership, mode,
processes, locks, mounts and nested subvolumes. It never removes pacman's lock,
application snapshots or unrelated caches. Unexpected data requires inspection.

`./update-native.sh` explicitly builds and installs the engine and both components
in one transaction. `setup.sh` first bootstraps an installed guard before its
system upgrade, then builds the components against the updated system. Fresh setup installs
prerequisites first and all three local packages together. Bootstrap keeps normal
hooks enabled and stops if prerequisites or the installed guard's checks fail. Component-only
`rebuild-plugin.sh` / `rebuild-tmux.sh` require a compatible installed guard;
they neither rebuild it nor update another package. Reboot after installation.
Automatic migration from obsolete bundled guards is not supported. No component
is a dependency of the engine.

```sh
systemctl list-timers hyprcachy-upgrade-cleanup.timer
journalctl -u hyprcachy-upgrade-cleanup.service
```

The timer is package-owned, enabled at boot and activated on installation on a
running host. Removal stops it but does not purge retained recovery data. The
latest upgrade log is overwritten for each preflight.
