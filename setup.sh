#!/usr/bin/env bash
# Repeatable setup for an existing Arch/CachyOS installation. Never formats disks.
set -euo pipefail

# Removing a package here does not uninstall it from an existing system.
PACKAGES=(
    hyprland git stow greetd greetd-tuigreet uwsm
    mako pipewire wireplumber pipewire-pulse pipewire-alsa
    xdg-desktop-portal-hyprland xdg-desktop-portal-gtk hyprpolkitagent
    qt5-wayland qt6-wayland noto-fonts networkmanager
)

die() { echo "Error: $*" >&2; exit 1; }
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
