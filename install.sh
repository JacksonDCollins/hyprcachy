#!/usr/bin/env bash
set -euo pipefail

MOUNTED_TARGET=0
INSTALL_WORKDIR=""

cleanup() {
    if (( MOUNTED_TARGET )); then
        umount -R /mnt 2>/dev/null || true
    fi
    if [[ -n "$INSTALL_WORKDIR" ]]; then
        rm -rf "$INSTALL_WORKDIR"
    fi
}
trap cleanup EXIT

die() {
    echo "Error: $*" >&2
    exit 1
}

(( EUID == 0 )) || die "Run this installer as root."
[[ -d /sys/firmware/efi/efivars ]] || die "This installer requires a UEFI boot."
if findmnt -rn -R /mnt >/dev/null; then
    die "/mnt already contains mounts; unmount them before continuing."
fi

# Archiso may launch script= before its other startup services finish.
systemctl is-system-running --wait >/dev/null || true

echo "======================================================"
echo "   CACHYOS MINIMAL: BTRFS + SNAPPER + LIMINE          "
echo "======================================================"

# --- 1. DYNAMIC DRIVE SELECTION ---
echo "Available Storage Drives:"
lsblk -dno NAME,SIZE,MODEL | grep -v "loop" || true
echo "------------------------------------------------------"
read -r -p "Enter the drive to install to (e.g., sda or nvme0n1): " CHOSEN_DRIVE

if [[ "$CHOSEN_DRIVE" == /dev/* ]]; then
    TARGET_DISK="$CHOSEN_DRIVE"
else
    TARGET_DISK="/dev/$CHOSEN_DRIVE"
fi

[[ -b "$TARGET_DISK" ]] || die "$TARGET_DISK is not a valid block device."
[[ "$(lsblk -dno TYPE "$TARGET_DISK")" == "disk" ]] || die "$TARGET_DISK is not a whole disk."
if lsblk -nrpo MOUNTPOINT "$TARGET_DISK" | grep -q '[^[:space:]]'; then
    die "$TARGET_DISK contains mounted filesystems."
fi

read -r -p "Type $TARGET_DISK to confirm that it may be completely erased: " CONFIRM_DISK
[[ "$CONFIRM_DISK" == "$TARGET_DISK" ]] || die "Disk confirmation did not match."

# --- 2. USER CONFIGURATION ---
read -r -p "Enter target hostname (e.g., cachy-btrfs): " HOSTNAME
[[ "$HOSTNAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] || die "Invalid hostname."

read -r -p "Enter new username: " NEW_USER
[[ "$NEW_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ && "$NEW_USER" != root ]] || die "Invalid username."

read -r -s -p "Enter password for $NEW_USER: " USER_PASSWORD
echo
read -r -s -p "Confirm password for $NEW_USER: " CONFIRM_PASSWORD
echo
[[ -n "$USER_PASSWORD" && "$USER_PASSWORD" == "$CONFIRM_PASSWORD" ]] || die "User passwords did not match or were empty."
unset CONFIRM_PASSWORD

read -r -s -p "Enter root account password: " ROOT_PASSWORD
echo
read -r -s -p "Confirm root account password: " CONFIRM_PASSWORD
echo
[[ -n "$ROOT_PASSWORD" && "$ROOT_PASSWORD" == "$CONFIRM_PASSWORD" ]] || die "Root passwords did not match or were empty."
unset CONFIRM_PASSWORD

# --- 3. DISK PARTITIONING ---
echo "Wiping and partitioning $TARGET_DISK..."
timedatectl set-ntp true
sgdisk --zap-all "$TARGET_DISK"
# 2GB EFI/Boot partition leaves room for kernels retained with bootable snapshots.
sgdisk --new=1:0:+2G --typecode=1:ef00 --change-name=1:"EFI" "$TARGET_DISK"
sgdisk --new=2:0:0   --typecode=2:8300 --change-name=2:"ROOT" "$TARGET_DISK"
partprobe "$TARGET_DISK"
udevadm settle

EFI_PART="$(lsblk -nrpo NAME,PARTN "$TARGET_DISK" | awk '$2 == 1 { print $1; exit }')"
ROOT_PART="$(lsblk -nrpo NAME,PARTN "$TARGET_DISK" | awk '$2 == 2 { print $1; exit }')"
[[ -b "$EFI_PART" && -b "$ROOT_PART" ]] || die "The new partition devices did not appear."

# --- 4. BTRFS & SUBVOLUME CREATION ---
echo "Formatting filesystems (Btrfs)..."
mkfs.vfat -F32 "$EFI_PART"
mkfs.btrfs -f "$ROOT_PART"

# Create standard flat subvolume layout.
mount "$ROOT_PART" /mnt
MOUNTED_TARGET=1
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@log
btrfs subvolume create /mnt/@pkg
btrfs subvolume create /mnt/@snapshots
umount /mnt
MOUNTED_TARGET=0

# Re-mount subvolumes using ZSTD transparent compression.
MOUNT_OPTS="noatime,compress=zstd:3,space_cache=v2"
mount -o subvol=@,$MOUNT_OPTS "$ROOT_PART" /mnt
MOUNTED_TARGET=1

mkdir -p /mnt/{boot,home,var/log,var/cache/pacman/pkg,.snapshots}
mount -o subvol=@home,$MOUNT_OPTS "$ROOT_PART" /mnt/home
mount -o subvol=@log,$MOUNT_OPTS "$ROOT_PART" /mnt/var/log
mount -o subvol=@pkg,$MOUNT_OPTS "$ROOT_PART" /mnt/var/cache/pacman/pkg
mount -o subvol=@snapshots,$MOUNT_OPTS "$ROOT_PART" /mnt/.snapshots
mount "$EFI_PART" /mnt/boot

# --- 5. REPO INJECTION & PACSTRAP ---
echo "Injecting CachyOS repositories into Live environment..."
INSTALL_WORKDIR="$(mktemp -d)"
curl -fL https://mirror.cachyos.org/cachyos-repo.tar.xz \
    -o "$INSTALL_WORKDIR/cachyos-repo.tar.xz"
tar -xf "$INSTALL_WORKDIR/cachyos-repo.tar.xz" -C "$INSTALL_WORKDIR"
(
    cd "$INSTALL_WORKDIR/cachyos-repo"
    # Make package installation non-interactive, but skip upgrading the
    # RAM-backed live system; pacstrap syncs repositories for the target.
    grep -Eq '^[[:space:]]*pacman -Syu[[:space:]]*$' cachyos-repo.sh || \
        die "Could not find the live-system upgrade in cachyos-repo.sh."
    sed -i -E \
        -e 's/^([[:space:]]*)pacman /\1pacman --noconfirm /' \
        -e '/^[[:space:]]*pacman --noconfirm -Syu[[:space:]]*$/d' \
        cachyos-repo.sh
    ./cachyos-repo.sh --install
)

echo "Pacstrapping base packages with Btrfs, Snapper, and Limine utilities..."
pacstrap -K /mnt base linux-cachyos linux-firmware \
    cachyos-keyring cachyos-mirrorlist btrfs-progs snapper snap-pac limine \
    limine-mkinitcpio-hook limine-snapper-sync networkmanager sudo efibootmgr

genfstab -U /mnt >> /mnt/etc/fstab
cp /etc/pacman.conf /mnt/etc/pacman.conf
cp -r /etc/pacman.d/cachyos* /mnt/etc/pacman.d/

ROOT_UUID="$(blkid -s UUID -o value "$ROOT_PART")"
[[ -n "$ROOT_UUID" ]] || die "Could not determine the root filesystem UUID."

# Snapper must create its own temporary /.snapshots before it is replaced by @snapshots.
umount /mnt/.snapshots
rmdir /mnt/.snapshots

# --- 6. TARGET SYSTEM CHROOT SETUP ---
echo "Configuring target system environment..."
arch-chroot /mnt /usr/bin/bash -s -- "$HOSTNAME" "$NEW_USER" "$ROOT_UUID" <<'EOF'
set -euo pipefail

hostname=$1
new_user=$2
root_uuid=$3

pacman-key --init
pacman-key --populate archlinux cachyos

printf '%s\n' "$hostname" > /etc/hostname
systemctl enable NetworkManager

printf 'en_US.UTF-8 UTF-8\n' > /etc/locale.gen
locale-gen
printf 'LANG=en_US.UTF-8\n' > /etc/locale.conf
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
hwclock --systohc

# Accounts and permissions setup.
useradd -m -U -G wheel -s /bin/bash "$new_user"
install -m 0440 /dev/null /etc/sudoers.d/10-installer
printf '%%wheel ALL=(ALL:ALL) ALL\n' > /etc/sudoers.d/10-installer
visudo -cf /etc/sudoers.d/10-installer

# --- 7. SNAPPER SNAPSHOTTING ARRANGEMENT ---
echo "Configuring Snapper filesystem mapping..."
snapper -c root create-config /
btrfs subvolume delete /.snapshots
mkdir /.snapshots
mount /.snapshots
chgrp wheel /.snapshots
chmod 0750 /.snapshots
systemctl enable snapper-cleanup.timer

# --- 8. LIMINE BOOTLOADER ARCHITECTURE ---
echo "Deploying and configuring Limine Bootloader..."
printf 'ESP_PATH="/boot"\n' > /etc/default/limine
printf 'root=UUID=%s rootflags=subvol=@ rw quiet\n' "$root_uuid" > /etc/kernel/cmdline

if grep '^HOOKS=' /etc/mkinitcpio.conf | grep -qw systemd; then
    overlay_hook=sd-btrfs-overlayfs
else
    overlay_hook=btrfs-overlayfs
fi
if ! grep '^HOOKS=' /etc/mkinitcpio.conf | grep -qw "$overlay_hook"; then
    sed -i "s/\\bfilesystems\\b/filesystems $overlay_hook/" /etc/mkinitcpio.conf
fi
grep '^HOOKS=' /etc/mkinitcpio.conf | grep -qw "$overlay_hook" || {
    echo "Failed to add $overlay_hook to mkinitcpio hooks." >&2
    exit 1
}

limine-install
limine-update
snapper -c root create --description "Initial installation"
limine-snapper-sync
systemctl enable limine-snapper-sync.service
EOF

# Feed credentials over stdin rather than interpolating them into shell code.
printf 'root:%s\n%s:%s\n' "$ROOT_PASSWORD" "$NEW_USER" "$USER_PASSWORD" | arch-chroot /mnt chpasswd
unset ROOT_PASSWORD USER_PASSWORD

echo "=== FINISHED! Remove the installation media and reboot. ==="
