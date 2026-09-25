#!/usr/bin/env bash
# Repeatable setup for an existing Arch/CachyOS installation. Never formats disks.
set -euo pipefail

# Removing a package here does not uninstall it from an existing system.
PACKAGES=(
    hyprland git stow greetd greetd-tuigreet uwsm
    mako pipewire wireplumber pipewire-pulse pipewire-alsa
    xdg-desktop-portal-hyprland xdg-desktop-portal-gtk hyprpolkitagent
    qt5-wayland qt6-wayland noto-fonts networkmanager
    chwd pciutils linux-firmware
)

die() { echo "Error: $*" >&2; exit 1; }
hardware_report() {
    echo '=== GPU hardware and drivers (read-only) ==='
    if systemd-detect-virt --chroot --quiet; then
        echo 'Chroot: loaded modules/sysfs describe the host, NOT the installed target. Recheck after reboot.'
    fi
    lspci -Dnnk -d ::03 || true
    echo '--- Installed chwd profiles ---'
    if command -v chwd >/dev/null; then chwd --list-installed; else echo 'chwd not installed'; fi
    echo '--- Installed graphics/kernel packages ---'
    pacman -Q | grep -E '^(linux[^ ]*|.*nvidia[^ ]*|mesa|lib32-mesa|egl-wayland|vulkan[^ ]*|switcheroo-control) ' || true
    echo '--- DKMS build status ---'
    if command -v dkms >/dev/null; then dkms status; else echo 'DKMS not installed (prebuilt modules do not require it)'; fi
    echo '--- NVIDIA module for each installed kernel ---'
    local pkgbase kernel parameter service
    for pkgbase in /usr/lib/modules/*/pkgbase; do
        [[ -f "$pkgbase" ]] || continue
        kernel=${pkgbase%/pkgbase}; kernel=${kernel##*/}
        printf '%s (%s): ' "$kernel" "$(< "$pkgbase")"
        modinfo -k "$kernel" -F version nvidia 2>/dev/null || echo 'no NVIDIA module (normal on non-NVIDIA systems)'
    done
    echo '--- Running NVIDIA DRM parameters (Wayland expects modeset=Y) ---'
    for parameter in modeset fbdev; do
        if [[ -r /sys/module/nvidia_drm/parameters/$parameter ]]; then
            printf '%s=%s\n' "$parameter" "$(< "/sys/module/nvidia_drm/parameters/$parameter")"
        else
            echo "$parameter: unavailable; NVIDIA DRM is not loaded or parameter cannot be read"
        fi
    done
    echo '--- NVIDIA power-management configuration ---'
    if [[ -r /proc/driver/nvidia/params ]]; then
        grep -E 'PreserveVideoMemoryAllocations|TemporaryFilePath|DynamicPowerManagement' /proc/driver/nvidia/params || true
    fi
    for service in nvidia-suspend nvidia-resume nvidia-hibernate nvidia-powerd switcheroo-control; do
        printf '%s: ' "$service"
        systemctl is-enabled "$service.service" 2>/dev/null || true
    done
    echo 'After reboot, inspect failures with: journalctl -b -k --grep="NVRM|nvidia|nouveau|drm"'
}

# Reporting never installs packages, rebuilds boot files, or requires an account.
if [[ ${1:-} == --hardware-report ]]; then
    (( $# == 1 )) || die 'Usage: ./setup.sh --hardware-report'
    hardware_report
    exit 0
fi

(( EUID == 0 )) || die "Run with sudo: sudo ./setup.sh [username] [profile]"
(( $# <= 2 )) || die "Usage: sudo ./setup.sh [username] [profile]"
[[ -f /etc/arch-release ]] || die "This setup requires an Arch-based system."
# arch-chroot bind-mounts the live ISO's /run into the installed target.
if [[ -d /run/archiso ]] && ! systemd-detect-virt --chroot --quiet; then
    die "Run inside the installed system, not the live ISO."
fi
user=${1:-${SUDO_USER:-}}
[[ "$user" =~ ^[a-z_][a-z0-9_-]{0,31}$ && "$user" != root ]] || die "Specify an existing non-root username."
account=$(getent passwd "$user") || die "User $user does not exist."
IFS=: read -r _ _ uid _ _ user_home _ <<< "$account"
[[ "$uid" != 0 && "$user_home" == /* && "$user_home" != / && -d "$user_home" ]] || die "Invalid user home."
profile=${2:-}
[[ -z "$profile" || "$profile" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "Invalid profile name."
repos=$(pacman-conf --repo-list)
grep -qx cachyos <<< "$repos" || die "CachyOS repositories must already be configured."
if [[ -e /etc/systemd/system/display-manager.service ]] &&
    [[ $(basename "$(readlink -f /etc/systemd/system/display-manager.service)") != greetd.service ]]; then
    die "Another login manager is enabled. Disable it before switching to greetd."
fi

# Upgrade together with dependency installation; never perform a partial Arch upgrade.
pacman -Syu --needed --noconfirm "${PACKAGES[@]}"

# Use maintained GPU profiles, including legacy NVIDIA and hybrid laptops.
# Running inside arch-chroot makes / the target; never select kernels with uname -r
# here, since that is the live ISO's kernel. chwd inspects installed pkgbase files.
# No --force: chwd skips profiles already installed on repeat runs.
echo 'Configuring graphics hardware with CachyOS profiles...'
for gpu_class in 0300 0302 0380; do
    chwd --autoconfigure "$gpu_class"
done
profiles=$(chwd --list-installed)
printf '%s\n' "$profiles"
if grep -qi nvidia <<< "$profiles"; then
    # Catch failed/missing DKMS or prebuilt modules before declaring setup done.
    found_kernel=0
    for pkgbase in /usr/lib/modules/*/pkgbase; do
        [[ -f "$pkgbase" ]] || continue
        found_kernel=1
        kernel=${pkgbase%/pkgbase}; kernel=${kernel##*/}
        modinfo -k "$kernel" nvidia >/dev/null || die "NVIDIA module missing for $kernel; fix the driver build before rebooting."
    done
    (( found_kernel )) || die 'No installed kernels found for NVIDIA validation.'
fi
# Also rebuild on reruns: profile hooks may have changed configuration before a
# previous package operation failed. Rebuild errors must stop setup.
# Calling Limine directly also updates its entries, without the mkinitcpio wrapper prompt.
if command -v limine-mkinitcpio >/dev/null; then
    limine-mkinitcpio
else
    mkinitcpio -P
fi

# Fail on local changes or a different checkout, rather than resetting user work.
# Pass all user-controlled values as arguments, not shell source.
runuser -u "$user" -- env -u BASH_ENV -u ENV HOME="$user_home" USER="$user" LOGNAME="$user" /usr/bin/bash -c '
set -euo pipefail
profile=$1
url=https://github.com/JacksonDCollins/dotfiles.git
branch=standalone-hyprland
repo="$HOME/dotfiles"
if [[ -e "$repo" || -L "$repo" ]]; then
    [[ -d "$repo/.git" && ! -L "$repo" ]] || { echo "Not a dotfiles clone: $repo" >&2; exit 1; }
    cd "$repo"
    [[ $(git remote get-url origin) == "$url" ]] || { echo "Unexpected dotfiles remote; leaving it untouched." >&2; exit 1; }
    [[ $(git branch --show-current) == "$branch" ]] || { echo "Expected dotfiles branch $branch; leaving it untouched." >&2; exit 1; }
    [[ -z $(git status --porcelain) ]] || { echo "Commit or stash your local dotfiles changes before setup." >&2; exit 1; }
    git pull --ff-only origin "$branch"
else
    git clone --branch "$branch" "$url" "$repo"
    cd "$repo"
fi
' -- "$profile"

# Dotfiles own this data-only list. Never source or run their scripts as root.
mapfile -t dotfiles_packages < "$user_home/dotfiles/packages-arch.txt"
(( ${#dotfiles_packages[@]} )) || die "Empty dotfiles dependency list."
for package in "${dotfiles_packages[@]}"; do
    [[ "$package" =~ ^[a-z0-9][a-z0-9@._+-]*$ ]] || die "Invalid dotfiles dependency package name."
done
pacman -Syu --needed --noconfirm -- "${dotfiles_packages[@]}"

# Configuration installation stays unprivileged, including machine selection.
runuser -u "$user" -- env -u BASH_ENV -u ENV HOME="$user_home" USER="$user" LOGNAME="$user" /usr/bin/bash -c '
set -euo pipefail
profile=$1
cd "$HOME/dotfiles"
profiles=()
for dir in machines/*; do
    [[ -d "$dir" && ! -L "$dir" ]] || continue
    name=${dir#machines/}
    [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || continue
    profiles+=("$name")
done
(( ${#profiles[@]} )) || { echo "No valid dotfiles machine profiles found." >&2; exit 1; }
if [[ -z "$profile" && -f "$HOME/.local/state/dotfiles/machine" ]]; then
    profile=$(< "$HOME/.local/state/dotfiles/machine")
fi
if [[ -z "$profile" ]]; then
    PS3="Select a dotfiles machine profile (number): "
    select profile in "${profiles[@]}"; do
        [[ -n "$profile" ]] && break
        echo "Invalid selection; enter a listed number." >&2
    done
fi
valid=0
for name in "${profiles[@]}"; do
    [[ "$profile" != "$name" ]] || valid=1
done
(( valid )) || { echo "No valid profile selected; pass an available profile to setup.sh." >&2; exit 1; }
bash ./setup.sh "$profile"
' -- "$profile"

# Replace only this owned system config; preserve each changed version first.
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT
cat > "$workdir/greetd.toml" <<'GREETD'
[terminal]
vt = 1

[default_session]
command = "tuigreet --time --remember --cmd 'uwsm start -e -D Hyprland hyprland.desktop'"
user = "greeter"
GREETD
[[ ! -L /etc/greetd/config.toml ]] || die "Refusing to replace a symlink at /etc/greetd/config.toml."
if ! cmp -s "$workdir/greetd.toml" /etc/greetd/config.toml; then
    if [[ -e /etc/greetd/config.toml ]]; then
        cp -a --backup=numbered /etc/greetd/config.toml /etc/greetd/config.toml.hyprcachy-backup
    fi
    install -m 0644 "$workdir/greetd.toml" /etc/greetd/config.toml
fi
systemctl enable NetworkManager greetd.service
systemctl --global enable hyprpolkitagent.service

echo "Setup complete. Log out and back in (or reboot after system updates) to apply session changes."
