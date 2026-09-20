#!/usr/bin/env bash
set -euo pipefail

echo "======================================================"
echo "      AUTOMATED ARCH / CACHYOS MINIMAL INSTALL        "
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
read -p "Enter target hostname (e.g., cachy-minimal): " HOSTNAME
read -p "Enter new username: " NEW_USER
read -s -p "Enter password for $NEW_USER: " USER_PASSWORD
echo ""
read -s -p "Enter root account password: " ROOT_PASSWORD
echo ""

# --- 3. DISK PARTITIONING & FORMATTING ---
echo "Wiping and partitioning $TARGET_DISK..."
timedatectl set-ntp true
sgdisk --zap-all "$TARGET_DISK"
sgdisk --new=1:0:+1G --typecode=1:ef00 --change-name=1:"EFI" "$TARGET_DISK"
sgdisk --new=2:0:0   --typecode=2:8300 --change-name=2:"ROOT" "$TARGET_DISK"

if [[ "$TARGET_DISK" == *"nvme"* || "$TARGET_DISK" == *"mmcblk"* ]]; then
    EFI_PART="${TARGET_DISK}p1"
    ROOT_PART="${TARGET_DISK}p2"
else
    EFI_PART="${TARGET_DISK}1"
    ROOT_PART="${TARGET_DISK}2"
fi

echo "Formatting filesystems..."
mkfs.vfat -F32 "$EFI_PART"
mkfs.ext4 -F "$ROOT_PART"

# --- 4. MOUNT & REPO INJECTION ---
echo "Mounting filesystems..."
mount "$ROOT_PART" /mnt
mkdir -p /mnt/boot
mount "$EFI_PART" /mnt/boot

echo "Injecting CachyOS repositories into Live environment..."
curl -O https://cachyos.org
tar xvf cachyos-repo.tar.xz && cd cachyos-repo
./cachyos-repo.sh --quiet || true
cd ..

# --- 5. BOOTSTRAP SYSTEM ---
echo "Pacstrapping base packages..."
# Added 'sudo' so your custom user can execute administrative commands later
pacstrap -K /mnt base linux-cachyos linux-cachyos-headers linux-firmware cachyos-keyring cachyos-mirrorlist nano networkmanager sudo

genfstab -U /mnt >> /mnt/etc/fstab
cp /etc/pacman.conf /mnt/etc/mnt/etc/pacman.conf 2>/dev/null || cp /etc/pacman.conf /mnt/etc/pacman.conf
cp -r /etc/pacman.d/cachyos* /mnt/mnt/etc/pacman.d/ 2>/dev/null || cp -r /etc/pacman.d/cachyos* /mnt/etc/pacman.d/

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

# Passwords configuration
echo "root:$ROOT_PASSWORD" | chpasswd

# Creating the custom user and setting permissions
useradd -m -g users -G wheel,storage,power -s /bin/bash "$NEW_USER"
echo "$NEW_USER:$USER_PASSWORD" | chpasswd
echo "%wheel ALL=(ALL:ALL) ALL" >> /etc/sudoers.d/10-installer

# Configure systemd-boot
bootctl install

cat <<EOT > /boot/loader/entries/arch.conf
title   Arch-CachyOS Minimal
linux   /vmlinuz-linux-cachyos
initrd  /initramfs-linux-cachyos.img
options root=$(blkid -s UUID -o value $ROOT_PART) rw
EOT

cat <<EOT > /boot/loader/loader.conf
default arch.conf
timeout 3
console-mode max
EOT
EOF

umount -R /mnt
echo "=== FINISHED! Type 'reboot' to boot into your minimal setup ==="
