# Hyprcachy

Minimal Arch/CachyOS installation with Btrfs, Snapper, Limine, Hyprland, UWSM,
and user dotfiles.

Hyprcachy installs the OS and desktop infrastructure, plus Git and Stow for
bootstrapping dotfiles. Dotfiles own their user applications (Foot, Neovim, tmux,
and the Quickshell wallpaper shell) and supporting tools, fonts, and development
dependencies. These do not belong in Hyprcachy's system package list.
Dotfiles own `packages-arch.txt` and a standalone `setup.sh` bootstrap. Hyprcachy
reads and validates that package list after cloning/updating dotfiles, installs
its packages with pacman, then applies configs as the user. No dotfiles script is
executed as root. Additional Neovim language runtimes are still project/dotfiles
concerns; this transfer does not add every toolchain.

Publish the dotfiles dependency list before publishing this Hyprcachy integration.

## Fresh installation — DESTRUCTIVE

Boot a current Arch ISO in UEFI mode. Download **both** scripts together before
starting (the installer checks for `setup.sh` before touching disks):

```bash
curl -fLO https://raw.githubusercontent.com/JacksonDCollins/hyprcachy/main/install.sh
curl -fLO https://raw.githubusercontent.com/JacksonDCollins/hyprcachy/main/setup.sh
less install.sh
less setup.sh
bash install.sh
```

Alternatively clone this repository and run `bash install.sh` from it.
The selected disk is erased. Use the `default` dotfiles profile in a VM; `jacktop`
forces a laptop-specific 4K mode and `work` references physical monitor outputs.

`install.sh` owns partitioning, filesystems, accounts/passwords, locale, repository
bootstrap, and initial bootloader/Snapper setup. It invokes `setup.sh` inside the
new installation and creates the initial snapshot after setup succeeds.

To launch automatically from an Arch ISO, append this to its UEFI boot entry's
kernel options (press `e` in the boot menu for a one-time edit):

```text
script=https://raw.githubusercontent.com/JacksonDCollins/hyprcachy/refs/heads/main/boot.sh
```

`boot.sh` downloads both scripts into a temporary directory and runs the installer.
Internet access is required; download failures stop execution, and disk erasure
still requires confirmation. No script needs to be embedded in the ISO.
For a persistent ISO edit, change only the existing entry's options in both the
ISO filesystem and its embedded EFI boot image; retain the normal menu defaults.

## Reapply configuration on an existing Hyprcachy install

Keep a local copy of this repository, update it, review changes, then run:

```bash
git pull --ff-only
sudo ./setup.sh
```

Under sudo, setup uses `SUDO_USER`. When running from a root shell or configuring
a different existing user, name that user explicitly:

```bash
sudo ./setup.sh jackson
sudo ./setup.sh jackson default  # explicitly change machine profile
```

`setup.sh`:

- Requires an existing non-root account and configured CachyOS repositories.
- Performs a full `pacman -Syu --needed --noconfirm` transaction, including system
  upgrades and installation of the packages in its `PACKAGES` array. Review this
  list before running. Removing an entry never uninstalls a package.
- Clones or fast-forward-updates `~/dotfiles` on `standalone-hyprland`, as the user.
  Refuses dirty checkouts, unexpected origins/branches, and divergent history;
  it never resets, stashes, merges, or force-pulls your work.
- Installs the validated packages in `~/dotfiles/packages-arch.txt` with
  `pacman -Syu --needed --noconfirm`. Review this dotfiles-owned list too;
  removed entries are not automatically uninstalled.
- Uses an explicitly supplied profile, otherwise the dotfiles saved profile at
  `~/.local/state/dotfiles/machine`. Prompts from the available profiles on first use.
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

## Non-destructive checks

```bash
for script in boot.sh install.sh setup.sh; do bash -n "$script" || exit; done
python tests/test_boot.py
python tests/test_dotfiles.py
python tests/test_session.py
python tests/test_setup.py
```

Tests use temporary directories, local Git repositories, and mocked service
commands. Full install, first boot, and login/logout still need VM testing.
