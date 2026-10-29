# THIS IS VIBECODED SLOP, USE AT YOUR OWN RISK

# Hyprcachy

Minimal Arch/CachyOS installation with Btrfs, Snapper, Limine, Hyprland, UWSM,
and user dotfiles.

Hyprcachy installs the OS and desktop infrastructure, plus Git and Stow for
bootstrapping dotfiles. Dotfiles own their user applications (Foot, Neovim, vis, tmux,
and the Quickshell wallpaper shell) and supporting tools, fonts, and development
dependencies. These do not belong in Hyprcachy's system package list.
Dotfiles own `packages-arch.txt` and a standalone `setup.sh` bootstrap. Hyprcachy
reads and validates that package list after cloning/updating dotfiles, installs
its packages with pacman, then calls dotfiles' `setup.sh` once as the user.
Dotfiles own configuration/runtime setup sequencing and runtime versions.
No dotfiles script is executed as root.

The dotfiles package list includes `vis`, `vis-lexers`, and `lua-lpeg`; pacman
also supplies vis's Lua and TRE dependencies. Git and Wayland clipboard support
are already provisioned, and vis-lspc reuses the mise-managed language servers.
The vis configuration bootstraps vis-plug and vis-lspc on first editor startup.

Publish the dotfiles dependency list before publishing this Hyprcachy integration.

Hyprcachy's only provisioned swap configuration is **zswap backed by disk swap**;
it does not install or configure zram. Fresh installs in either mode create a
**16 GiB Linux swap partition** (`HYPRCACHY_SWAP`) at the end of the selected region,
registered by filesystem UUID in `/etc/fstab` at **priority 10**. Target disk swap
is formatted but never activated on the live ISO; it starts at first boot.

The installer sets these kernel parameters in `/etc/kernel/cmdline`:

```text
zswap.enabled=1 zswap.compressor=zstd zswap.max_pool_percent=20 zswap.shrinker_enabled=1
```

Zswap caches swapped pages using zstd, with compressed storage capped at **20% of
physical RAM** (about 6.2 GiB on a machine reporting 31 GiB RAM). It grows on demand,
not as a reservation. Cache eviction writes pages to disk, and the enabled shrinker
allows cold cached pages to be reclaimed under memory pressure. The cache uses
slots in the disk swap area: total swap capacity remains **16 GiB**, not 16 GiB
plus the cache size. Zswap is built into the kernel; no extra swap daemon or
`zram-generator` dependency is needed.

This is overflow swap, not a configured hibernation/resume setup. The installer
creates unencrypted storage, so disk swap can persist sensitive memory contents.
Existing systems require a separately reviewed manual migration: configure disk
swap, update the kernel parameters and boot configuration, and retire any old zram
configuration/package. `setup.sh` does not resize partitions, rewrite existing swap
policy, uninstall old packages, or drain active swap automatically.

## Optional window-session restoration

Hyprcachy owns an experimental [native dwindle-tree/session plugin](packages/window-session/).
Its implementation, packaging and upgrade integration live together under
`packages/window-session/`. Setup builds its local pacman package without a fixed Hyprland version allowlist;
dotfiles call its packaged `init.lua` configuration function, which declares native
loading before session readiness and application autostarts. Minimal protocol-state loading
happens during native initialization; desktop discovery stays asynchronous.
Restoration stays **disabled until explicitly enabled**. It uses Hyprland's embedded Lua
runtime, not an external interpreter or daemon. Keep using `sudo pacman -Syu`
or your usual pacman-based helper: the independent
[shared upgrade guard](packages/upgrade-guard/) owns hooks that compile the plugin against relevant
incoming packages in a disposable Btrfs/nspawn build environment before pacman can
commit. The Hyprland check is compile-only: no compositor or GPU access. Compilation failures
block the transaction instead of disabling the existing plugin. Transaction identity
and integrity checks remain mandatory; ambiguous or unsupported transactions fail
explicitly. There is no separate upgrade command. Dotfiles use one call:
`dofile("/usr/share/hyprcachy/window-session/init.lua")({ ... })`.
The package owns the loading logic; install it before using the call. No startup
service or autostart ordering override is needed. Compilation does not prove runtime correctness; read the
plugin documentation and validate restoration separately before relying on it.

To rebuild and install the plugin from this checkout, including uncommitted edits:

```sh
./rebuild-plugin.sh
```

Run as your normal user, not with `sudo`. It uses `makepkg` for a clean rebuild
and installation through normal pacman hooks, prompting for privilege when needed.
It reinstalls even when the package version is unchanged. Build work directories
are cleaned on success; package archives remain available. It builds and installs
only window-session; a compatible guard must already be installed.
Missing distribution prerequisites must be installed through your normal full system update;
extra makepkg arguments are not accepted. It does not reload the running plugin;
log out/in after native code changes.

## Split tmux status and automatic rebuilds

Setup also installs the [guarded tmux companion](packages/tmux/). It supplies a
native top session bar and bottom window/status bar without replacing the stock
`/usr/bin/tmux`. Dotfiles select the companion and configure the rows.

Each component owns its upgrade adapter, sources and build/check instructions.
The shared engine owns only frozen transaction replay, isolation, verification,
publication and cleanup, under its own `upgrade-guard` paths.

Run `./rebuild-tmux.sh` and reapply dotfiles. It builds and installs only the
companion, requiring an already installed compatible guard. It never adds a
window-session or guard package rebuild. Tmux does not depend on window-session
or Hyprland. A new tmux server is required; the command neither restarts one nor
restores over live sessions.

Ordinary `pacman -Syu` updates rebuild the companion from the exact signed stock
package's recipe, preserve distribution patches, and apply the patch from your
local Hyprcachy checkout in the same frozen Btrfs/nspawn transaction check.
The companion records that checkout's path when built; its build script and patch
are copied as data into private staging and executed only by the unprivileged
candidate. No Hyprcachy Git fetch or pull occurs. Private terminal checks verify the
bars before the upgrade may commit. Unknown recipes, patch conflicts and failed
checks stop the upgrade for review; automatic updates do not imply automatic
patch repair. See the companion README for activation and recovery details.

## Coordinated native update

```sh
./update-native.sh
```

Run as your normal user to prepare a **full system upgrade plus all three local
packages**: upgrade guard, window-session and tmux companion. The command first
uses `pacman -Syu --downloadonly` and freezes the package plan, local recipes and
verified tmux build inputs. It upgrades a disposable Btrfs snapshot to those exact
packages, then runs makepkg there as an unprivileged user with networking disabled.
The plugin therefore builds against the incoming Hyprland headers and libraries,
not the host's older version. All planned system archives and the three built
packages are then submitted in one guarded `pacman -U` transaction. It does
not install tmux first or bootstrap with a partial system upgrade. Changed plans,
extra dependencies and repository replacement transitions are rejected rather than
guessed; use ordinary `pacman -Syu` for replacement transitions before retrying.
The coordinated plan is checked again under pacman's lock by the incoming adapter.
After a successful install, newly pulled repository dependencies are marked with
`pacman -D --asdeps`; existing package reasons and the native packages are left alone.
Setup uses the same policy. If this bookkeeping fails, the packages are already
installed and the command prints the exact metadata-only retry; do not repeat the
whole upgrade just to repair install reasons.

Code comes from this checkout, including local edits; nothing pulls Hyprcachy from
GitHub. Exact verified upstream tmux sources may still be downloaded. Both components
are included even if not previously installed; component rebuild commands stay
component-only and require an installed compatible guard. No application is restarted.

`sudo ./setup.sh <username> [profile]` uses the same staged build on systems with
native components already installed; fresh setup still installs prerequisites first.
Root only freezes inputs, manages the snapshot and installs packages. PKGBUILDs
never run as root. Package hooks/scriptlets are suppressed only inside the trial
snapshot; the final host transaction retains its normal signature checks and guard.
Build failure stops before host installation, and scratch snapshots are removed.
Container builds receive no signing keys; sites requiring signatures on local
packages must arrange signing before installation, not weaken pacman's policy.

Run `python tests/test_staged_native.py` for unprivileged orchestration tests using
fake package/privileged commands. Real Btrfs/nspawn execution requires a separate
privileged integration check.
**Reboot after installation.** Obsolete bundled guards still require explicit repair.
The internal `--prepare DIRECTORY` mode is used by root-owned setup to run only
preparation/building as the user; setup itself handles download, installation and
cleanup. Normal use needs no arguments.

## Fresh installation — partitioning required

Boot a current Arch ISO in UEFI mode. Obtain a **complete local source tree**,
not just the two installer scripts. For example, explicitly clone it once:

```bash
git clone https://github.com/JacksonDCollins/hyprcachy.git
cd hyprcachy
less install.sh
less setup.sh
bash install.sh
```

Alternatively copy the complete local tree, including unpublished changes, to the
USB. The installer checks for the required helpers/packages before touching disks,
then copies that tree into the created user's `~/hyprcachy` with user ownership.
Setup and later updates do not clone or pull Hyprcachy. Publish installer changes
before using the automatic boot download instead of your local copy.

Before any target-disk writes, the installer waits up to one minute for NTP clock
synchronization, downloads/caches the CachyOS repository bootstrap, fetches and
checks its signing key over HTTPS (port 443, avoiding blocked HKP port 11371), and
checks that the CachyOS repository responds. A failure aborts without partitioning.
The official bootstrap imports this cached public key; its key signing and package
signature checks remain enabled. Exactly one primary key must match the pinned full
fingerprint `882DCFE48E2051D48E2562ABF3B607488DB35A47`, verified against CachyOS's
[official trusted-key list](https://github.com/CachyOS/CachyOS-PKGBUILDS/blob/master/cachyos-keyring/cachyos-trusted).
Matching only the key ID or a subkey is not enough. Bootstrap whitespace, quoting,
and keyserver-host changes are tolerated; changed key identities or unsupported
key commands abort before disk writes. Key rotation needs a reviewed pin update.

Bootstrap transfers retry transient failures up to three times with connection/
transfer deadlines (the USB launcher retries up to five times). Permanent HTTP
404s are not retried. These retries apply only to the installer's own bootstrap
downloads. Base installation uses normal `pacstrap -K`; this installer does not
set or remove pacman's `XferCommand` or `ParallelDownloads`, or supply a custom
pacman configuration. CachyOS's official bootstrap still configures its repositories
and signing keys as usual. Whole package transactions and setup scripts are **not**
automatically rerun. Successful checks do not guarantee later
servers stay online. The bootstrap's `yes` input producer may finish with an
expected SIGPIPE (141); that status is not logged as an installation failure.

The installer then presents searchable, numbered choices for:

- **Keyboard:** available console-to-XKB mappings supplied by systemd (search
  `us`, `uk`, `de`, etc.). It applies the console keymap with `loadkeys` and asks
  you to type a **non-secret sample** and confirm it before entering passwords.
  Use the live Linux console: SSH/graphical terminals retain their client's
  keyboard layout, which you must check separately. Cancelling does not restore
  the previous live console keymap.
- **Locale:** a supported UTF-8 locale, such as `en_AU.UTF-8` or `de_DE.UTF-8`.
  This controls the new system's language and regional formatting.
- **Timezone:** search city/region keywords; `new york` and `New_York` both find
  `America/New_York`. Only the installed system's timezone changes; RTC stays UTC.

Search is case-insensitive and all keywords must match (not typo-tolerant).
More than 20 matches asks for a narrower query. Enter at the number prompt
searches again; `q` or Ctrl+D cancels before target disk writes. These menus use
Bash and existing Arch ISO tools/data, without extra packages.

The installed console uses `/etc/vconsole.conf`. Desktop keyboard settings live
in `/etc/environment.d/60-keyboard.conf`; non-empty values are quoted and unset
variants/options are omitted because systemd rejects empty assignments. The dotfiles Hyprland configuration
honors its standard `XKB_DEFAULT_*` variables through UWSM/systemd user services.
Without those variables, standalone dotfiles retain US input. Publish the matching
dotfiles input change before using the GitHub-based installer; old dotfiles
hardcode US input. The mapping's layout-switch options are retained, but the
legacy Ctrl+Alt+Backspace termination option is not enabled.

Choose an installation mode:

- **Install alongside an existing OS** (default): select one contiguous
  unallocated region on a healthy GPT disk. Creates **2 GiB EFI/boot** first,
  **Btrfs root** in the middle, and **16 GiB swap** at the end of that region.
  At least **34 GiB** of aligned free space is required (including 16 GiB for root);
  **64 GiB or more is recommended** for apps, development tools and snapshots. Existing partitions, including other EFI
  partitions, are not formatted, resized or reused. Confirm with `INSTALL /dev/…`.
- **Erase disk**: destroys the entire selected disk, with a separate
  `ERASE /dev/…` confirmation. Creates the same EFI/root/swap arrangement; requires
  at least 34 GiB plus 2 MiB of alignment/GPT headroom before any disk writes.

After hostname, username and password entry, a **final review** shows the target
disk, proposed disk changes, timezone, locale, and console/desktop keyboard choices.
Passwords are never displayed. Only then must you type `INSTALL /dev/…` or
`ERASE /dev/…`; a mismatch or EOF aborts before target disk writes.

The alongside mode supports 512-byte and 4096-byte logical sectors. It refuses
MBR/hybrid or damaged GPT tables, mounted filesystems, active swap/device mappings,
insufficient free space, and a partition table that changed after selection.
There is no automatic shrinking, moving, GPT repair or conversion. Back up your
important data first, fully shut down the existing OS (not hibernation/Fast Startup),
and keep any BitLocker recovery key available. Do not run other partitioning tools
concurrently. GPT backups/logs are saved under `/root/hyprcachy-partitions.*` on the
live system and copied to the new system's `/root/` once its filesystems are mounted;
copy them to another drive before reboot. These are **not data backups** or an
automatic rollback; failed installations can leave newly created partitions.

Output and errors are logged to `/root/hyprcachy-install.*.log` on the live system.
At exit, once the new filesystems are mounted, the complete log is saved as
`/var/log/hyprcachy-install.log` in the target (`@log` subvolume), including the
failed stage and exit status. Logs are root-only; shell tracing is disabled so
password-bearing commands are not traced. Failures before mounting only have the
live log: copy it elsewhere **before reboot**. To inspect a persistent log from
another OS, mount the new Btrfs **`@log`** subvolume read-only, not just `@`.
Do not rerun `install.sh` blindly after a disk-changing failure.

Hyprcachy uses its **own EFI partition**, not the existing OS's bootloader files.
It mounts that partition with `umask=0077`, persisted by `genfstab`, so bootloader
random-seed files and the boot directory are not accessible to other local users.
Limine registers a new firmware boot entry and **may become the default**; existing
entries remain available through the firmware boot menu. Firmware support for
multiple EFI partitions varies; this installer does not configure Secure Boot
signing. Other operating systems are not scanned by the installer. After booting Hyprcachy, optionally run `sudo limine-scan` to add
them to its Limine menu, or keep selecting them through firmware.

Use the `default` dotfiles profile in a VM; `jacktop` forces a laptop-specific 4K
mode and `work` references physical monitor outputs.

`install.sh` owns partitioning, filesystems, accounts/passwords, locale, repository
bootstrap, and initial bootloader/Snapper setup. It invokes `setup.sh` inside the
new installation and creates the initial snapshot after setup succeeds.

To launch automatically from an Arch ISO, append this to its UEFI boot entry's
kernel options (press `e` in the boot menu for a one-time edit):

```text
script=https://raw.githubusercontent.com/JacksonDCollins/hyprcachy/refs/heads/main/boot.sh
```

`boot.sh` explicitly downloads the complete source archive for the initial install
and runs its installer. The installer retains the source tree in `~/hyprcachy`;
this archive has no Git metadata. Subsequent setup/updates use those local files,
not another Hyprcachy download.
Internet access is required; download failures stop execution. Installation mode,
region selection and confirmation remain interactive; automatic launch does not
authorize disk erasure. No script needs to be embedded in the ISO.
For a persistent ISO edit, change only the existing entry's options in both the
ISO filesystem and its embedded EFI boot image; retain the normal menu defaults.

## Reapply configuration on an existing Hyprcachy install

Keep the complete local source tree at `~/hyprcachy`, update/review its files
yourself, then run:

```bash
cd ~/hyprcachy
sudo ./setup.sh
```

Setup requires that user-owned persistent tree. It neither fetches Hyprcachy nor
builds from a temporary copy whose recorded source path disappears afterward.

Under sudo, setup uses `SUDO_USER`. When running from a root shell or configuring
a different existing user, name that user explicitly:

```bash
sudo ./setup.sh jackson
sudo ./setup.sh jackson default  # explicitly change machine profile
```

`setup.sh`:

- Requires an existing non-root account and configured CachyOS repositories.
- If a native component is installed, prepares the full system upgrade and all
  current local native packages **together**, using the shared updater before
  any installing `-Syu` can encounter an old adapter. Root downloads/installs;
  preparation and builds run as the selected user without nested sudo prompts.
  It does not rebuild these components again at the end. Existing native build
  prerequisites must be available; failures stop setup without bypassing hooks.
  With only a guard installed, updates that guard first. With no native components,
  installs distribution/dotfiles prerequisites before building the local packages.
  There are no bundled-guard migration branches or temporary hook overrides;
  candidate builds remain offline.
- Performs a full `pacman -Syu --needed --noconfirm` transaction, including system
  upgrades and installation of the packages in its `PACKAGES` array. Review this
  list before running. Removing an entry never uninstalls a package.
- Configures display-controller classes with CachyOS `chwd` profiles and rebuilds
  initramfs and Limine entries directly with `limine-mkinitcpio`, without the
  wrapper's confirmation prompt (`mkinitcpio -P` on non-Limine systems).
  Existing profiles are skipped, not force-reinstalled.
  Missing NVIDIA modules for installed kernels or initramfs errors stop setup.
- Clones or fast-forward-updates `~/dotfiles` on `standalone-hyprland`, as the user.
  Refuses dirty checkouts, unexpected origins/branches, and divergent history;
  it never resets, stashes, merges, or force-pulls your work.
- Installs the validated packages in `~/dotfiles/packages-arch.txt` with
  `pacman -Syu --needed --noconfirm`. Review this dotfiles-owned list too;
  removed entries are not automatically uninstalled.
- Uses an explicitly supplied profile, otherwise the dotfiles saved profile at
  `~/.local/state/dotfiles/machine`. Prompts from the available profiles on first use.
- Runs dotfiles' `setup.sh` as the user; it applies configs and installs its pinned
  mise runtimes and editor tools. Requires internet; initial setup may take several minutes.
- Builds window-session and tmux against the updated system as the selected
  user, then installs their archives together. Fresh installations include the
  shared guard in that transaction; an already bootstrapped guard is not rebuilt
  again. Native build tools are infrastructure dependencies; stock tmux still
  comes from the dotfiles application manifest.
- Replaces `/etc/greetd/config.toml` only if changed. Its previous contents are
  saved as `config.toml.hyprcachy-backup`, with older backups numbered.
- Enables NetworkManager, greetd, and the graphical-session polkit service.
  Refuses to replace a different enabled login manager. Does not explicitly
  start/restart the desktop or session services; package upgrade hooks can still
  affect running services. Log out/in or reboot after updates as appropriate.

It does **not** partition, format, recreate users, reset passwords, change the
hostname, recreate Snapper configurations, or reinstall the bootloader. Normal
package upgrade hooks may update kernels, initramfs, and boot entries.

Setup stops on errors but is not an all-or-nothing transaction: package upgrades
may finish before a dotfiles/configuration error. Fix the reported problem and
rerun **setup.sh**, never `install.sh`.

## Graphics drivers and NVIDIA

Hardware support belongs to Hyprcachy, not the dotfiles package manifest.
`setup.sh` installs `chwd`, `pciutils`, and firmware, then autoconfigures VGA, 3D,
and other display controllers (`0300`, `0302`, `0380`). Fresh installations use
this same stage inside `arch-chroot`; driver selection uses the target's installed
kernels, not the ISO's running kernel.

[CachyOS profiles](https://wiki.cachyos.org/features/chwd/chwd/) own GPU ID matching,
legacy NVIDIA branches, matching prebuilt CachyOS modules/DKMS dependencies,
initramfs module configuration, and laptop PRIME/power-management setup. Profile
package lists can include 32-bit libraries; keep the standard CachyOS repositories
and multilib enabled. Review `chwd --list` and existing profiles before applying
setup to a machine with manually configured drivers. Package/profile conflicts
are not overridden by Hyprcachy; resolve them explicitly and rerun setup. Changing
GPU vendors can require removing the old profile with chwd first.

We do not add global NVIDIA environment variables, force the discrete GPU, unload
live GPU modules, or duplicate NVIDIA power-management defaults with historical
workarounds. Profiles can replace their owned configuration and enable services;
package upgrades can run service hooks. Reboot after driver changes. Secure Boot
module signing, unsupported GPUs, and machine-specific suspend/display problems
still require separate configuration—automatic detection is not a guarantee that
every NVIDIA generation works with current Hyprland.

After reboot, inspect installed profiles, packages, per-kernel NVIDIA modules,
DKMS build status, live DRM parameters, and power-management service configuration:

```bash
bash setup.sh --hardware-report
# Optional: sudo bash setup.sh --hardware-report for restricted kernel parameters.
```

This mode is read-only and bypasses installation/account setup. In a chroot it
warns that live kernel/sysfs information belongs to the host. On NVIDIA hardware,
verify DRM `modeset=Y`; review DKMS status for unbuilt modules and kernel logs for
failures. Power services vary by driver/hardware—an absent service alone is not
proof of a problem. Test suspend/resume and external displays on the actual machine.

## Non-destructive checks

```bash
for script in boot.sh install.sh setup.sh; do bash -n "$script" || exit; done
bash setup.sh --hardware-report
```

Full installation, first boot, suspend/resume, and hybrid GPU offloading require
hardware testing.
