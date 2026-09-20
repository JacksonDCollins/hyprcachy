#!/usr/bin/env bash
set -euo pipefail

echo "======================================================"
echo "   CACHYOS MINIMAL: BTRFS + SNAPPER + LIMINE          "
echo "======================================================"

# --- 1. DYNAMIC DRIVE SELECTION ---
echo "Available Storage Drives:"
lsblk -dno NAME,SIZE,MODEL | grep -v "loop" || true
echo "------------------------------------------------------"
read -p "Enter the drive to install to (e.g., sda or nvme0n1): " CHOSEN_DRIVE

TARGET_DISK="/dev/$CHOSEN_DRIVE"
if [ ! -b "$TARGET_DISK" ]; then
    echo "Error: $TARGET_DISK is not a valid block device."
    exit 1
fi

# --- 2. USER CONFIGURATION ---
read -p "Enter target hostname (e.g., cachy-btrfs): " HOSTNAME
read -p "Enter new username: " NEW_USER
read -s -p "Enter password for $NEW_USER: " USER_PASSWORD
echo ""
read -s -p "Enter root account password: " ROOT_PASSWORD
echo ""

# --- 3. DISK PARTITIONING ---
echo "Wiping and partitioning $TARGET_DISK..."
timedatectl set-ntp true
sgdisk --zap-all "$TARGET_DISK"
# 2GB EFI/Boot partition is ideal for holding multiple kernel variants alongside snapshots
sgdisk --new=1:0:+2G --typecode=1:ef00 --change-name=1:"EFI" "$TARGET_DISK"
sgdisk --new=2:0:0   --typecode=2:8300 --change-name=2:"ROOT" "$TARGET_DISK"

if [[ "$TARGET_DISK" == *"nvme"* || "$TARGET_DISK" == *"mmcblk"* ]]; then
    EFI_PART="${TARGET_DISK}p1"
    ROOT_PART="${TARGET_DISK}p2"
else
    EFI_PART="${TARGET_DISK}1"
    ROOT_PART="${TARGET_DISK}2"
fi

# --- 4. BTRFS & SUBVOLUME CREATION ---
echo "Formatting filesystems (Btrfs)..."
mkfs.vfat -F32 "$EFI_PART"
mkfs.btrfs -f "$ROOT_PART"

# Create standard flat subvolume layout
mount "$ROOT_PART" /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@log
btrfs subvolume create /mnt/@pkg
btrfs subvolume create /mnt/@snapshots
umount /mnt

# Re-mount subvolumes cleanly using ZSTD transparent compression
MOUNT_OPTS="noatime,compress=zstd:3,space_cache=v2"
mount -o subvol=@,$MOUNT_OPTS "$ROOT_PART" /mnt

mkdir -p /mnt/{boot,home,var/log,var/cache/pacman/pkg,.snapshots}
mount -o subvol=@home,$MOUNT_OPTS "$ROOT_PART" /mnt/home
mount -o subvol=@log,$MOUNT_OPTS "$ROOT_PART" /mnt/var/log
mount -o subvol=@pkg,$MOUNT_OPTS "$ROOT_PART" /mnt/var/cache/pacman/pkg
mount -o subvol=@snapshots,$MOUNT_OPTS "$ROOT_PART" /mnt/.snapshots

# Mount the EFI system/boot partition directly into /boot
mount "$EFI_PART" /mnt/boot

# --- 5. REPO INJECTION & PACSTRAP ---
echo "Injecting CachyOS repositories into Live environment..."

# Using lowercase -o forces curl to write to the exact filename specified
if ! curl -f -L -o cachyos-repo.tar.xz https://cachyos.org; then
    echo "ERROR: Failed to download the CachyOS repository archive."
    exit 1
fi

tar xvf cachyos-repo.tar.xz && cd cachyos-repo
./cachyos-repo.sh --quiet || true
cd ..

echo "Pacstrapping base packages with Btrfs & Limine utilities..."
# Packages needed for filesystem health & backup configurations: btrfs-progs, snapper, snap-pac, limine
pacstrap -K /mnt base linux-cachyos linux-cachyos-headers linux-firmware \
    cachyos-keyring cachyos-mirrorlist btrfs-progs snapper snap-pac limine \
    limine-mkinitcpio-hook nano networkmanager sudo efibootmgr

genfstab -U /mnt >> /mnt/etc/fstab
cp /etc/pacman.conf /mnt/etc/pacman.conf
cp -r /etc/pacman.d/cachyos* /mnt/etc/pacman.d/

# --- 6. TARGET SYSTEM CHROOT SETUP ---
echo "Configuring target system environment..."
arch-chroot /mnt /usr/bin/bash <<EOF
set -euo pipefail

pacman-key --init
pacman-key --populate archlinux cachyos

echo "$HOSTNAME" > /etc/hostname
systemctl enable NetworkManager

echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
hwclock --systohc

# Accounts and permissions setup
echo "root:$ROOT_PASSWORD" | chpasswd
useradd -m -g users -G wheel,storage,power -s /bin/bash "$NEW_USER"
echo "$NEW_USER:$USER_PASSWORD" | chpasswd
echo "%wheel ALL=(ALL:ALL) ALL" >> /etc/sudoers.d/10-installer

# --- 7. SNAPPER SNAPSHOTTING ARRANGEMENT ---
echo "Configuring Snapper filesystem mapping..."
# Delete the temporary .snapshots placeholder directory so snapper can initialize properly
umount /mnt/.snapshots 2>/dev/null || true
rmdir /.snapshots 2>/dev/null || true

snapper -c root create-config /
rmdir /.snapshots
mkdir /.snapshots
# Re-mount the persistent snapshot subvolume
mount -a

# Ensure default wheel/admin visibility into backups
chown -R :wheel /.snapshots

# --- 8. LIMINE BOOTLOADER ARCHITECTURE ---
echo "Deploying and Configuring Limine Bootloader..."
mkdir -p /boot/EFI/limine
cp /usr/share/limine/BOOTX64.EFI /boot/EFI/limine/

# Direct NVRAM to fallback straight to Limine's unified path
efibootmgr --create --disk "$TARGET_DISK" --part 1 --label "CachyOS Limine" --loader '\\EFI\\limine\\BOOTX64.EFI' --unicode

# Generate custom runtime Limine Configuration file
cat <<EOT > /boot/EFI/limine/limine.conf
timeout: 3

/CachyOS Minimal (Btrfs)
    protocol: linux
    path: boot():/vmlinuz-linux-cachyos
    module_path: boot():/initramfs-linux-cachyos.img
    cmdline: root=UUID=$(blkid -s UUID -o value $ROOT_PART) rootflags=subvol=@ rw quiet
EOT

# Synchronize automated mkinitcpio hooks so upgrades refresh entries dynamically
mkinitcpio -P
EOF

umount -R /mnt
echo "=== FINISHED! Type 'reboot' to deploy into your new Btrfs machine ==="
