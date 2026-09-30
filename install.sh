#!/usr/bin/env bash
set +x # Never trace password entry or the chpasswd pipe, even under bash -x.
set -Eeuo pipefail

die() {
    echo "Error: $*" >&2
    exit 1
}

select_option() {
    local title=$1 zones=$2 query zone lower word matched choice selected i
    local -a words matches
    [[ -n $zones ]] || die "No choices available for $title."
    printf '%s: search by keywords; type q to cancel installation.\n' "$title" >&2
    while true; do
        read -r -p "$title search: " query || die "Selection cancelled; no disks were changed."
        query=${query,,}
        query=${query//_/ }
        query=${query//\// }
        read -ra words <<< "$query"
        (( ${#words[@]} )) || continue
        [[ $query != q ]] || die "Selection cancelled; no disks were changed."
        matches=()
        while IFS= read -r zone; do
            lower=${zone,,}
            matched=1
            for word in "${words[@]}"; do
                if [[ $lower != *"$word"* ]]; then matched=0; break; fi
            done
            if (( matched )); then matches+=("$zone"); fi
        done <<< "$zones"
        if (( ${#matches[@]} == 0 )); then
            echo 'No matches; try different keywords.' >&2
            continue
        elif (( ${#matches[@]} > 20 )); then
            printf '%s matches; narrow your search with more keywords.\n' "${#matches[@]}" >&2
            continue
        fi
        for i in "${!matches[@]}"; do
            printf '%d) %s\n' "$((i + 1))" "${matches[i]}" >&2
        done
        while true; do
            read -r -p "$title number (Enter to search again, q to cancel): " choice \
                || die "Selection cancelled; no disks were changed."
            [[ -n $choice ]] || break
            [[ ${choice,,} != q ]] || die "Selection cancelled; no disks were changed."
            if [[ $choice =~ ^[1-9][0-9]?$ ]] && (( choice <= ${#matches[@]} )); then
                selected=${matches[choice - 1]}
                printf '%s\n' "$selected"
                return 0
            fi
            echo 'Invalid number; choose one of the listed choices.' >&2
        done
    done
}

select_timezone() {
    local zones selected
    zones=$(timedatectl --no-pager list-timezones) || die "Could not list timezones."
    selected=$(select_option 'Timezone (e.g. new york)' "$zones") || return 1
    [[ -f /usr/share/zoneinfo/"$selected" ]] || die "Selected timezone data is missing."
    printf '%s\n' "$selected"
}

select_locale() {
    local locales selected
    locales=$(awk '$2 == "UTF-8" {print $1}' /usr/share/i18n/SUPPORTED) || die "Could not list supported locales."
    selected=$(select_option 'UTF-8 locale (e.g. en_US or de_DE)' "$locales") || return 1
    [[ $selected =~ ^[A-Za-z0-9_@.-]+$ ]] || die "Invalid locale identifier."
    printf '%s\n' "$selected"
}

select_keyboard() {
    local available keymap layout model variant options languages rows=""
    command -v loadkeys >/dev/null || die "loadkeys is required to configure the console keyboard."
    available=$(localectl list-keymaps) || die "Could not list console keymaps."
    [[ -r /usr/share/systemd/kbd-model-map ]] || die "systemd keyboard mappings are missing."
    while read -r keymap layout model variant options languages; do
        [[ $keymap =~ ^[A-Za-z0-9][A-Za-z0-9_.+-]*$ &&
           $layout =~ ^[A-Za-z0-9_,+-]+$ && $model =~ ^[A-Za-z0-9_+-]+$ &&
           $variant =~ ^[A-Za-z0-9_,+-]+$ && $options =~ ^[A-Za-z0-9_:,+-]+$ ]] || continue
        grep -Fxq -- "$keymap" <<< "$available" || continue
        # inet is an obsolete model suffix; evdev provides multimedia keys.
        model=${model%+inet}
        # Apply Bulgarian phonetic to bg, not us, in the affected systemd mapping.
        if [[ $keymap == bg_pho-utf8 && $layout == bg,us && $variant == ,phonetic ]]; then
            variant=phonetic,
        fi
        # Preserve layout-switch options, not the legacy X-server kill shortcut.
        options=${options//terminate:ctrl_alt_bksp/}
        options=${options//,,/,}
        options=${options#,}
        options=${options%,}
        rows+="$keymap $layout $model $variant ${options:--} ${languages:--}"$'\n'
    done < /usr/share/systemd/kbd-model-map
    echo 'Columns: console keymap, desktop layout, model, variant, options, language tags (- = default).' >&2
    select_option 'Keyboard (e.g. us, uk, de, fr)' "${rows%$'\n'}"
}

verify_keyboard() {
    local _sample answer
    loadkeys "$KEYMAP" || die "Could not apply the console keymap; run from the live Linux console."
    echo "Console keyboard set to $KEYMAP. SSH/graphical terminals still use their client's layout."
    read -r -p 'Type a NON-SECRET sample to check letters and symbols (not a password): ' _sample || die "Keyboard check cancelled."
    read -r -p 'Do the keys match your intended layout? [y/N]: ' answer || die "Keyboard check cancelled."
    [[ $answer == y || $answer == Y ]] || die "Keyboard not confirmed. Correct the layout and rerun before entering passwords."
}

confirm_installation() {
    local expected answer
    echo '================ FINAL INSTALLATION REVIEW ================'
    lsblk -dno NAME,SIZE,MODEL "$TARGET_DISK"
    if [[ $INSTALL_MODE == 1 ]]; then
        echo "Mode: alongside; preserve existing partitions on $TARGET_DISK."
        printf 'New EFI: sectors %s–%s (2 GiB); new Btrfs root: sectors %s–%s (%s).\n' \
            "$EFI_START" "$((ROOT_START - 1))" "$ROOT_START" "$REGION_END" \
            "$(numfmt --to=iec-i --suffix=B "$((ROOT_SECTORS * SECTOR_SIZE))")"
        expected="INSTALL $TARGET_DISK"
    else
        echo "Mode: ERASE ALL DATA on $TARGET_DISK; create 2 GiB EFI plus Btrfs root using the rest."
        expected="ERASE $TARGET_DISK"
    fi
    printf 'Hostname: %s\nUser: %s\nTimezone: %s\nLocale: %s\nConsole keymap: %s\n' \
        "$HOSTNAME" "$NEW_USER" "$TIMEZONE" "$SYSTEM_LOCALE" "$KEYMAP"
    printf 'Desktop keyboard: layout=%s model=%s variant=%s options=%s\n' \
        "$XKB_LAYOUT" "$XKB_MODEL" "${XKB_VARIANT:-(default)}" "${XKB_OPTIONS:-(none)}"
    echo 'Passwords: entered and confirmed (not displayed).'
    echo 'Limine uses the new EFI partition and may become the default firmware entry; no OS scan will run.'
    echo 'Back up important data/recovery keys. Any mismatch below cancels before target disk writes.'
    read -r -p "Type $expected to proceed: " answer || die "Installation cancelled."
    [[ $answer == "$expected" ]] || die "Confirmation did not match; no target disk writes performed."
}

# Pure sector arithmetic, also usable by disposable-image checks.
plan_free_region() {
    local start=$1 end=$2 sector_size=$3 alignment
    [[ $start =~ ^[0-9]{1,15}$ && $end =~ ^[0-9]{1,15}$ ]] || return 1
    [[ $sector_size == 512 || $sector_size == 4096 ]] || return 1
    alignment=$((1048576 / sector_size))
    EFI_START=$(((start + alignment - 1) / alignment * alignment))
    REGION_END=$(((end + 1) / alignment * alignment - 1))
    EFI_SECTORS=$((2 * 1024 * 1024 * 1024 / sector_size))
    ROOT_START=$((EFI_START + EFI_SECTORS))
    ROOT_SECTORS=$((REGION_END - ROOT_START + 1))
    (( ROOT_SECTORS >= 16 * 1024 * 1024 * 1024 / sector_size ))
}

eligible_regions() {
    local disk=$1 sector_size=$2 listing start end sectors rest
    listing=$(LC_ALL=C sfdisk --list-free --output Start,End,Sectors "$disk") || return 1
    while read -r start end sectors rest; do
        [[ $sectors =~ ^[0-9]{1,15}$ ]] || continue
        if plan_free_region "$start" "$end" "$sector_size"; then
            printf '%s %s\n' "$EFI_START" "$REGION_END"
        fi
    done <<< "$listing"
}

assert_disk_idle() {
    local node holder mounts nodes types
    [[ $(lsblk -dnro RO "$TARGET_DISK") == 0 ]] || die "The target disk is read-only."
    mounts=$(lsblk -nrpo MOUNTPOINTS "$TARGET_DISK") || die "Cannot inspect target mounts."
    [[ ! $mounts =~ [^[:space:]] ]] || die "$TARGET_DISK contains mounted filesystems or active swap."
    types=$(lsblk -nrpo TYPE "$TARGET_DISK") || die "Cannot inspect target devices."
    while read -r node; do
        [[ $node == disk || $node == part ]] || die "Deactivate device mappings/RAID on $TARGET_DISK first."
    done <<< "$types"
    nodes=$(lsblk -nrpo NAME "$TARGET_DISK") || die "Cannot inspect target holders."
    while read -r node; do
        for holder in /sys/class/block/"${node##*/}"/holders/*; do
            [[ ! -e $holder ]] || die "$node has active device holders."
        done
    done <<< "$nodes"
}

# Refuse damaged/hybrid GPT rather than silently repairing or converting it.
read_gpt() {
    local disk=$1 errors=$2 table bytes entries=0 i
    local -a mbr
    table=$(LC_ALL=C sfdisk --dump "$disk" 2> "$errors") || return 1
    [[ ! -s $errors && $table == 'label: gpt'$'\n'* ]] || return 1
    # MBR type bytes have fixed offsets, independent of logical sector size.
    # Nested DOS probing can incorrectly assume 512-byte geometry on 4Kn images.
    bytes=$(od -An -v -tu1 -j450 -N49 -w49 "$disk") || return 1
    read -ra mbr <<< "$bytes"
    (( ${#mbr[@]} == 49 )) || return 1
    for i in 0 16 32 48; do
        case ${mbr[i]} in
            238) entries=$((entries + 1)) ;; # Protective GPT entry (0xee).
            0) ;;
            *) return 1 ;; # Hybrid MBR: leave it alone.
        esac
    done
    (( entries == 1 )) || return 1
    LC_ALL=C sfdisk --verify "$disk" >/dev/null 2> "$errors" || return 1
    [[ ! -s $errors ]] || return 1
    printf '%s\n' "$table"
}

append_layout() (
    # Hold a cooperating-writer lock across revalidation and the GPT write.
    local disk=$1 snapshot=$2 plan=$3 backup=$4 current after preserved lock uuid
    exec {lock}<"$disk"
    flock --exclusive --nonblock "$lock" || die "Another tool has locked $disk."
    current=$(read_gpt "$disk" "$backup/validation.log") || die "GPT validation failed; no partitions created."
    [[ $current == "$(<"$snapshot")" ]] || die "Partition table changed since selection; start again."
    LC_ALL=C sfdisk --no-act --append --lock=no --wipe never --wipe-partitions never "$disk" < "$plan" > "$backup/preview.log" 2>&1 \
        || die "Partition plan rejected; see $backup/preview.log."
    LC_ALL=C sfdisk --append --lock=no --wipe never --wipe-partitions never --backup --backup-file "$backup/sectors" "$disk" < "$plan" > "$backup/write.log" 2>&1 \
        || die "Partition write failed; do not format manually. Inspect $backup/write.log and backups."
    after=$(read_gpt "$disk" "$backup/validation.log") || die "Post-write GPT validation failed; no formatting performed."
    # sfdisk can return success without adding entries when GPT slots are full.
    for uuid in "$EFI_PARTUUID" "$ROOT_PARTUUID"; do
        [[ $(grep -icF "uuid=$uuid" <<< "$after") == 1 ]] \
            || die "Both new GPT entries could not be confirmed; no formatting performed. Inspect $backup."
    done
    preserved=$(printf '%s\n' "$after" | grep -viF -e "uuid=$EFI_PARTUUID" -e "uuid=$ROOT_PARTUUID")
    [[ $preserved == "$current" ]] || die "Existing partition metadata changed; no formatting performed. Inspect $backup."
)

new_partition_device() {
    local uuid=$1 expected_start=$2 expected_size=$3 listing node part_uuid result="" start size
    listing=$(lsblk -nrpo NAME,PARTUUID "$TARGET_DISK") || return 1
    while read -r node part_uuid; do
        [[ ${part_uuid,,} == "${uuid,,}" ]] || continue
        [[ -z $result && -b $node ]] || return 1
        read -r start < "/sys/class/block/${node##*/}/start" || return 1
        read -r size < "/sys/class/block/${node##*/}/size" || return 1
        # Kernel sysfs reports 512-byte units even on 4Kn disks.
        [[ $start == "$((expected_start * SECTOR_SIZE / 512))" && $size == "$((expected_size * SECTOR_SIZE / 512))" ]] || return 1
        result=$node
    done <<< "$listing"
    [[ -n $result ]] || return 1
    printf '%s\n' "$result"
}

# Retry transfers, not package transactions or the entire repository setup.
download_file() {
    local url=$1 destination=$2
    shift 2
    curl --proto '=https' --fail --location --show-error --remove-on-error \
        --retry 3 --retry-all-errors --retry-delay 2 --retry-max-time 120 \
        --connect-timeout 15 --max-time 60 "$@" --output "$destination" -- "$url"
}

configure_downloads() {
    local command="XferCommand = /usr/bin/curl --fail --location --show-error --retry 3 --retry-all-errors --retry-delay 2 --retry-max-time 300 --connect-timeout 15 --max-time 300 --output '%o' -- '%u'"
    grep -qx '\[options\]' "$1" || die "Missing pacman options section: $1"
    sed -i -e '/^[[:space:]]*XferCommand[[:space:]]*=/d' \
        -e "/^\[options\]$/a $command" "$1"
}

network_preflight() {
    # Trust anchor: CachyOS/CachyOS-PKGBUILDS, cachyos-keyring/cachyos-trusted.
    # Key rotation requires a reviewed update, never discovery from a keyserver.
    local directory=$1 fingerprint=882DCFE48E2051D48E2562ABF3B607488DB35A47
    download_file https://mirror.cachyos.org/cachyos-repo.tar.xz "$directory/cachyos-repo.tar.xz"
    tar -xf "$directory/cachyos-repo.tar.xz" -C "$directory"
    local script="$directory/cachyos-repo/cachyos-repo.sh"
    bash -n "$script"
    # Fetch over HTTPS (443), not HKP (11371). Require exactly one primary key
    # with the pinned fingerprint; a matching key ID or subkey is insufficient.
    download_file "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x$fingerprint" "$directory/cachyos-key.asc"
    install -dm 0700 "$directory/gnupg"
    gpg --homedir "$directory/gnupg" --batch --with-colons --show-keys "$directory/cachyos-key.asc" \
        | awk -F: -v expected="$fingerprint" '
            $1 == "pub" {primaries++; primary_fingerprint=1; next}
            $1 == "sub" {primary_fingerprint=0}
            $1 == "fpr" && primary_fingerprint {actual=$10; primary_fingerprint=0}
            END {exit !(primaries == 1 && actual == expected)}'
    # Match command tokens, not indentation, quoting or the keyserver hostname.
    # Unknown identities/command shapes still fail closed before disk writes.
    if ! awk -v expected="$fingerprint" '
        $1 == "pacman-key" && ($2 == "--recv-keys" || $2 == "--lsign-key") {
            key=$3; gsub(/["\047]/, "", key); key=toupper(key); sub(/^0X/, "", key)
            if (key != expected && key != substr(expected, length(expected)-15)) bad=1
            if ($2 == "--recv-keys") {
                received++
                if (NF > 3 && $4 != "--keyserver" && $4 !~ /^#/) bad=1
                if ($4 == "--keyserver" && (NF < 5 || (NF > 5 && $6 !~ /^#/))) bad=1
                print "    pacman-key --add /root/cachyos-key.asc"
            } else {
                signed++
                if (NF > 3 && $4 !~ /^#/) bad=1
                print "    pacman-key --lsign-key " expected
            }
            next
        }
        {print}
        END {exit (bad || received != 1 || signed != 1)}' "$script" > "$script.cached-key"; then
        die "CachyOS key bootstrap changed; review its key identity/commands before installing."
    fi
    chmod --reference="$script" "$script.cached-key"
    mv -- "$script.cached-key" "$script"
    bash -n "$script"
    download_file https://mirror.cachyos.org/repo/x86_64/cachyos/cachyos.db "$directory/repository.headers" --head
    echo 'CachyOS archive, signing key and repository are reachable; no target disks changed.'
}

start_log() {
    INSTALL_LOG=$1
    exec 3>&1 4>&2
    exec > >(tee -a "$INSTALL_LOG") 2>&1
    LOG_PID=$!
}

finish_log() {
    # Drain tee before copying, so the final error is included in the saved log.
    exec 1>&3 2>&4 3>&- 4>&-
    wait "$LOG_PID" || return
    if [[ -n ${1:-} ]]; then
        install -Dm 0600 "$INSTALL_LOG" "$1"
    fi
}

stage() {
    STAGE=$*
    printf '\n=== %s ===\n' "$STAGE"
}

# Sourcing exposes helpers only; it never starts an installation.
[[ ${BASH_SOURCE[0]} == "$0" ]] || return 0
export LC_ALL=C

# Clone/download both scripts together; fail before touching disks if setup is missing.
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
[[ -r "$SCRIPT_DIR/setup.sh" ]] || { echo "setup.sh must be beside install.sh" >&2; exit 1; }
(( EUID == 0 )) || die "Run this installer as root."
[[ -d /sys/firmware/efi/efivars ]] || die "This installer requires a UEFI boot."
if findmnt -rn -R /mnt >/dev/null; then
    die "/mnt already contains mounts; unmount them before continuing."
fi
MOUNTED_TARGET=0
TARGET_LOG_READY=0
PLAN_DIR=""
NETWORK_DIR=""
STAGE=initialization
start_log "$(mktemp /root/hyprcachy-install.XXXXXX.log)"

cleanup() {
    local status=$? destination=""
    trap - ERR
    set +e
    if (( status )); then
        printf '\nFAILED: %s (exit %s). Do not rerun the installer blindly.\n' "$STAGE" "$status"
    fi
    echo "Live log: $INSTALL_LOG (copy elsewhere before reboot)."
    if (( TARGET_LOG_READY )); then
        destination=/mnt/var/log/hyprcachy-install.log
        echo 'Persistent log: HyprCachy @log/hyprcachy-install.log'
        if [[ -n ${BACKUP_DIR:-} ]]; then
            install -dm 0700 /mnt/root
            cp -a -- "$BACKUP_DIR" /mnt/root/ || { echo 'Could not preserve partition backups.' >&2; status=1; }
        fi
    fi
    finish_log "$destination" || { echo 'Could not save the complete installation log.' >&2; status=1; }
    if (( MOUNTED_TARGET )); then
        umount -R /mnt || { echo 'Target unmount failed; inspect mounts before reboot.' >&2; status=1; }
    fi
    [[ -z $PLAN_DIR ]] || rm -rf -- "$PLAN_DIR"
    [[ -z $NETWORK_DIR ]] || rm -rf -- "$NETWORK_DIR"
    exit "$status"
}
trap cleanup EXIT
trap 'printf "Error during %s at installer line %s (exit %s).\n" "$STAGE" "$LINENO" "$?" >&2' ERR

# Archiso may launch script= before its other startup services finish.
systemctl is-system-running --wait >/dev/null || true

echo "======================================================"
echo "   CACHYOS MINIMAL: BTRFS + SNAPPER + LIMINE          "
echo "======================================================"

stage 'Clock synchronization and network preflight (before disk writes)'
timedatectl set-ntp true
for (( attempt=0; attempt<30; attempt++ )); do
    [[ $(timedatectl show -p NTPSynchronized --value) == yes ]] && break
    sleep 2
done
[[ $(timedatectl show -p NTPSynchronized --value) == yes ]] \
    || die "Clock is not synchronized. Fix live-USB internet/time synchronization and rerun."
date -u
NETWORK_DIR=$(mktemp -d /root/hyprcachy-network.XXXXXX)
network_preflight "$NETWORK_DIR"
cp /etc/pacman.conf "$NETWORK_DIR/pacman.conf"
configure_downloads "$NETWORK_DIR/pacman.conf"

stage 'Installation choices'
KEYBOARD=$(select_keyboard)
read -r KEYMAP XKB_LAYOUT XKB_MODEL XKB_VARIANT XKB_OPTIONS _ <<< "$KEYBOARD"
if [[ $XKB_VARIANT == - ]]; then XKB_VARIANT=""; fi
if [[ $XKB_OPTIONS == - ]]; then XKB_OPTIONS=""; fi
verify_keyboard
SYSTEM_LOCALE=$(select_locale)
TIMEZONE=$(select_timezone)
printf 'Selected timezone: %s\n' "$TIMEZONE"

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

TARGET_DISK=$(readlink -f -- "$TARGET_DISK")
[[ -b "$TARGET_DISK" ]] || die "$TARGET_DISK is not a valid block device."
[[ "$(lsblk -dno TYPE "$TARGET_DISK")" == "disk" ]] || die "$TARGET_DISK is not a whole disk."
assert_disk_idle
lsblk -o NAME,SIZE,FSTYPE,LABEL,PARTLABEL "$TARGET_DISK"

echo "1) Install alongside an existing OS, using one unallocated region (GPT only)"
echo "2) ERASE the entire disk"
read -r -p "Installation mode [1]: " INSTALL_MODE
INSTALL_MODE=${INSTALL_MODE:-1}
case "$INSTALL_MODE" in
    1)
        for tool in sfdisk blockdev flock numfmt od; do
            command -v "$tool" >/dev/null || die "Required tool missing: $tool"
        done
        PLAN_DIR=$(mktemp -d)
        read_gpt "$TARGET_DISK" "$PLAN_DIR/errors" > "$PLAN_DIR/before.dump" \
            || die "Alongside installation requires a healthy, non-hybrid GPT. Nothing was changed."
        SECTOR_SIZE=$(blockdev --getss "$TARGET_DISK")
        [[ $SECTOR_SIZE == 512 || $SECTOR_SIZE == 4096 ]] || die "Unsupported logical sector size."
        regions=$(eligible_regions "$TARGET_DISK" "$SECTOR_SIZE") || die "Could not read free regions."
        [[ -n $regions ]] || die "No contiguous unallocated region fits 2 GiB EFI plus at least 16 GiB root."
        mapfile -t REGIONS <<< "$regions"
        echo "Eligible unallocated regions (the entire selected region will be used):"
        for i in "${!REGIONS[@]}"; do
            read -r first last <<< "${REGIONS[i]}"
            printf '%d) sectors %s–%s, %s\n' "$((i + 1))" "$first" "$last" \
                "$(numfmt --to=iec-i --suffix=B "$(((last - first + 1) * SECTOR_SIZE))")"
        done
        read -r -p "Region number: " region
        if [[ ! $region =~ ^[1-9][0-9]{0,5}$ ]] || (( region > ${#REGIONS[@]} )); then
            die "Invalid region."
        fi
        read -r first last <<< "${REGIONS[region - 1]}"
        plan_free_region "$first" "$last" "$SECTOR_SIZE" || die "Invalid region geometry."
        read -r EFI_PARTUUID < /proc/sys/kernel/random/uuid
        read -r ROOT_PARTUUID < /proc/sys/kernel/random/uuid
        printf 'start=%s, size=%s, type=U, uuid=%s, name="HYPRCACHY_EFI"\nstart=%s, size=%s, type=L, uuid=%s, name="HYPRCACHY_ROOT"\n' \
            "$EFI_START" "$EFI_SECTORS" "$EFI_PARTUUID" "$ROOT_START" "$ROOT_SECTORS" "$ROOT_PARTUUID" > "$PLAN_DIR/layout"
        printf 'NEW EFI: sectors %s–%s (2 GiB); NEW Btrfs root: sectors %s–%s (%s).\n' \
            "$EFI_START" "$((ROOT_START - 1))" "$ROOT_START" "$REGION_END" "$(numfmt --to=iec-i --suffix=B "$((ROOT_SECTORS * SECTOR_SIZE))")"
        echo "Existing partitions/EFI files will not be formatted or reused. No OS scan will run."
        echo "Limine will add a firmware boot entry and may become the default; existing entries remain."
        echo "Back up important data and any BitLocker recovery key before proceeding."
        echo "Fully shut down the existing OS first; do not run other partitioning tools during installation."
        ;;
    2)
        command -v sgdisk >/dev/null || die "Required tool missing: sgdisk"
        ;;
    *) die "Invalid installation mode." ;;
esac

# --- 2. USER CONFIGURATION ---
read -r -p "Enter target hostname (e.g., cachy-btrfs): " HOSTNAME
[[ "$HOSTNAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] || die "Invalid hostname."

read -r -p "Enter new username: " NEW_USER
[[ "$NEW_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ && "$NEW_USER" != root ]] || die "Invalid username."

IFS= read -r -s -p "Enter password for $NEW_USER: " USER_PASSWORD
echo
IFS= read -r -s -p "Confirm password for $NEW_USER: " CONFIRM_PASSWORD
echo
[[ -n "$USER_PASSWORD" && "$USER_PASSWORD" == "$CONFIRM_PASSWORD" ]] || die "User passwords did not match or were empty."
unset CONFIRM_PASSWORD

IFS= read -r -s -p "Enter root account password: " ROOT_PASSWORD
echo
IFS= read -r -s -p "Confirm root account password: " CONFIRM_PASSWORD
echo
[[ -n "$ROOT_PASSWORD" && "$ROOT_PASSWORD" == "$CONFIRM_PASSWORD" ]] || die "Root passwords did not match or were empty."
unset CONFIRM_PASSWORD

confirm_installation

# --- 3. DISK PARTITIONING ---
stage 'Partitioning the confirmed target'
assert_disk_idle
if [[ $INSTALL_MODE == 1 ]]; then
    BACKUP_DIR=$(mktemp -d /root/hyprcachy-partitions.XXXXXX)
    cp -- "$PLAN_DIR/before.dump" "$BACKUP_DIR/before.dump"
    cp -- "$PLAN_DIR/layout" "$BACKUP_DIR/plan"
    echo "Partition-table backup: $BACKUP_DIR (copy off the live environment before reboot)."
    append_layout "$TARGET_DISK" "$PLAN_DIR/before.dump" "$PLAN_DIR/layout" "$BACKUP_DIR"
else
    echo "Wiping and partitioning $TARGET_DISK..."
    sgdisk --zap-all "$TARGET_DISK"
    # 2 GiB EFI/Boot leaves room for kernels retained with bootable snapshots.
    sgdisk --new=1:0:+2G --typecode=1:ef00 --change-name=1:"EFI" "$TARGET_DISK"
    sgdisk --new=2:0:0 --typecode=2:8300 --change-name=2:"ROOT" "$TARGET_DISK"
fi
partprobe "$TARGET_DISK"
udevadm settle

if [[ $INSTALL_MODE == 1 ]]; then
    EFI_PART=$(new_partition_device "$EFI_PARTUUID" "$EFI_START" "$EFI_SECTORS") || die "New EFI device/geometry could not be verified; no formatting performed."
    ROOT_PART=$(new_partition_device "$ROOT_PARTUUID" "$ROOT_START" "$ROOT_SECTORS") || die "New root device/geometry could not be verified; no formatting performed."
else
    EFI_PART="$(lsblk -nrpo NAME,PARTN "$TARGET_DISK" | awk '$2 == 1 { print $1; exit }')"
    ROOT_PART="$(lsblk -nrpo NAME,PARTN "$TARGET_DISK" | awk '$2 == 2 { print $1; exit }')"
fi
[[ -b "$EFI_PART" && -b "$ROOT_PART" && $EFI_PART != "$ROOT_PART" ]] || die "The new partition devices did not appear."

# --- 4. BTRFS & SUBVOLUME CREATION ---
assert_disk_idle
stage 'Formatting only the selected new filesystems'
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
TARGET_LOG_READY=1

# --- 5. TARGET BOOTSTRAP & CACHYOS REPOSITORIES ---
stage 'Installing Arch base packages'
pacstrap -C "$NETWORK_DIR/pacman.conf" -K /mnt base linux-firmware btrfs-progs snapper snap-pac limine \
    networkmanager sudo efibootmgr zsh

genfstab -U /mnt >> /mnt/etc/fstab
configure_downloads /mnt/etc/pacman.conf

# Set console input before kernel hooks build the initramfs. UWSM's user
# services inherit these standard XKB variables via systemd environment.d.
printf 'KEYMAP=%s\n' "$KEYMAP" > /mnt/etc/vconsole.conf
install -dm 0755 /mnt/etc/environment.d
printf 'XKB_DEFAULT_LAYOUT=%s\nXKB_DEFAULT_MODEL=%s\nXKB_DEFAULT_VARIANT=%s\nXKB_DEFAULT_OPTIONS=%s\n' \
    "$XKB_LAYOUT" "$XKB_MODEL" "$XKB_VARIANT" "$XKB_OPTIONS" > /mnt/etc/environment.d/60-keyboard.conf

# Run the official repository setup against the disk-backed target, never the live ISO.
stage 'Configuring CachyOS repositories and signing keys'
cp -a -- "$NETWORK_DIR/cachyos-repo" /mnt/root/
cp -- "$NETWORK_DIR/cachyos-key.asc" /mnt/root/cachyos-key.asc
arch-chroot /mnt /usr/bin/bash -c \
    'cd /root/cachyos-repo && ./cachyos-repo.sh --install' < <(yes)
rm -rf /mnt/root/cachyos-repo /mnt/root/cachyos-key.asc

stage 'Installing CachyOS kernel and boot integration'
arch-chroot /mnt pacman --noconfirm -S --needed \
    linux-cachyos limine-mkinitcpio-hook limine-snapper-sync

ROOT_UUID="$(blkid -s UUID -o value "$ROOT_PART")"
[[ -n "$ROOT_UUID" ]] || die "Could not determine the root filesystem UUID."

# Snapper must create its own temporary /.snapshots before it is replaced by @snapshots.
umount /mnt/.snapshots
rmdir /mnt/.snapshots

# --- 6. TARGET SYSTEM CHROOT SETUP ---
stage 'Configuring accounts, locale, Snapper and Limine'
arch-chroot /mnt /usr/bin/bash -s -- "$HOSTNAME" "$NEW_USER" "$ROOT_UUID" "$TIMEZONE" "$SYSTEM_LOCALE" <<'EOF'
set -euo pipefail

hostname=$1
new_user=$2
root_uuid=$3
timezone=$4
system_locale=$5
[[ -f /usr/share/zoneinfo/"$timezone" ]] || { echo "Selected timezone is missing from target tzdata." >&2; exit 1; }
awk -v chosen="$system_locale" '$1 == chosen && $2 == "UTF-8" {found=1} END {exit !found}' /usr/share/i18n/SUPPORTED \
    || { echo "Selected locale is missing from target glibc." >&2; exit 1; }

pacman-key --init
pacman-key --populate archlinux cachyos

printf '%s\n' "$hostname" > /etc/hostname
printf '%s UTF-8\n' "$system_locale" > /etc/locale.gen
locale-gen
printf 'LANG=%s\n' "$system_locale" > /etc/locale.conf
ln -sfn "/usr/share/zoneinfo/$timezone" /etc/localtime
hwclock --systohc --utc

# Accounts and permissions setup.
useradd -m -U -G wheel -s /usr/bin/zsh "$new_user"
install -m 0440 /dev/null /etc/sudoers.d/10-installer
printf '%%wheel ALL=(ALL:ALL) ALL\n' > /etc/sudoers.d/10-installer
visudo -cf /etc/sudoers.d/10-installer

# --- 7. SNAPPER SNAPSHOTTING ARRANGEMENT ---
echo "Configuring Snapper filesystem mapping..."
snapper --no-dbus -c root create-config /
btrfs subvolume delete /.snapshots
mkdir /.snapshots
mount /.snapshots
chgrp wheel /.snapshots
chmod 0750 /.snapshots
systemctl enable snapper-cleanup.timer

# --- 8. LIMINE BOOTLOADER ARCHITECTURE ---
echo "Deploying and configuring Limine Bootloader..."
printf 'ESP_PATH="/boot"\nFIND_BOOTLOADERS=no\n' > /etc/default/limine
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
systemctl enable limine-snapper-sync.service
EOF

# Feed credentials over stdin rather than interpolating them into shell code.
printf 'root:%s\n%s:%s\n' "$ROOT_PASSWORD" "$NEW_USER" "$USER_PASSWORD" | arch-chroot /mnt chpasswd
unset ROOT_PASSWORD USER_PASSWORD

# --- 9. REPEATABLE SYSTEM AND USER SETUP ---
stage 'Installing graphics, desktop and user dotfiles'
install -m 0700 "$SCRIPT_DIR/setup.sh" /mnt/root/hyprcachy-setup.sh
arch-chroot /mnt /usr/bin/bash /root/hyprcachy-setup.sh "$NEW_USER"
rm /mnt/root/hyprcachy-setup.sh
arch-chroot /mnt snapper --no-dbus -c root create --description "Initial installation"
arch-chroot /mnt limine-snapper-sync

if [[ $INSTALL_MODE == 1 ]]; then
    echo "Existing OS partitions were preserved. Select the new Limine entry in your firmware boot menu."
    echo "Firmware boot priority may have changed; adjust it in firmware settings if desired."
    echo "Optional after boot: sudo limine-scan to add other operating systems to Limine's menu."
    echo "Copy $BACKUP_DIR off the live environment before reboot; it is not a data backup."
fi
echo "=== FINISHED! Remove the installation media and reboot. ==="
