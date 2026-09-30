#!/usr/bin/env bash
# Non-destructive bootstrap check. No root, real network, package installs or disks.
# Failure cases: transient/permanent downloads, incomplete archives/keys, changed
# upstream key import, duplicate downloader settings, lost logs or leaked secrets.
# Key failures: same-ID/wrong fingerprint, matching subkey/wrong primary, multiple
# primary keys, missing fingerprint; whitespace/quoting changes must still work.
# Integration also checks GPT appends preserve existing partition metadata/data.
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
source "$repo/install.sh"

mkdir -p "$work/upstream/cachyos-repo" "$work/bin"
cat > "$work/upstream/cachyos-repo/cachyos-repo.sh" <<'EOF'
#!/bin/bash
set -e
	pacman-key   --recv-keys   "0xf3b607488db35a47"  --keyserver 'another.example' # public directory
    pacman-key    --lsign-key '882DCFE48E2051D48E2562ABF3B607488DB35A47'
    pacman -U https://mirror.cachyos.org/example.pkg.tar.zst
EOF
tar -cJf "$work/archive.tar.xz" -C "$work/upstream" cachyos-repo
cat > "$work/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$CHECK_WORK/curl.calls"
[[ " $* " == *' --retry 3 '* && " $* " == *' --retry-all-errors '* &&
   " $* " == *' --connect-timeout 15 '* && " $* " == *' --max-time 60 '* ]] || exit 90
output=""
while (( $# )); do
    if [[ $1 == --output ]]; then output=$2; shift 2; else url=$1; shift; fi
done
if [[ ${CHECK_FAIL:-} == archive ]]; then exit 28; fi
case $url in
    */cachyos-repo.tar.xz) cp "$CHECK_WORK/archive.tar.xz" "$output" ;;
    *keyserver.ubuntu.com*)
        if [[ ${CHECK_FAIL:-} == key ]]; then exit 22; fi
        printf '%s\n' '-----BEGIN PGP PUBLIC KEY BLOCK-----' 'fixture' '-----END PGP PUBLIC KEY BLOCK-----' > "$output" ;;
    */cachyos.db) printf 'HTTP/2 200\n' > "$output" ;;
    *) exit 91 ;;
esac
EOF
cat > "$work/bin/gpg" <<'EOF'
#!/usr/bin/env bash
printf 'pub:-:4096:1:F3B607488DB35A47:0:0::-:::scSC::::::23::0:\n'
case ${CHECK_FAIL:-} in
    collision|subkey) printf 'fpr:::::::::000000000000000000000000F3B607488DB35A47:\n' ;;
    missing) ;;
    *) printf 'fpr:::::::::882DCFE48E2051D48E2562ABF3B607488DB35A47:\n' ;;
esac
if [[ ${CHECK_FAIL:-} == subkey ]]; then
    printf 'sub:-:4096:1:F3B607488DB35A47:0:0:::::e:\nfpr:::::::::882DCFE48E2051D48E2562ABF3B607488DB35A47:\n'
elif [[ ${CHECK_FAIL:-} == multiple ]]; then
    printf 'pub:-:4096:1:0000000000000000:0:0:::::s:\nfpr:::::::::0000000000000000000000000000000000000000:\n'
fi
EOF
chmod +x "$work/bin/curl" "$work/bin/gpg"
export CHECK_WORK=$work PATH="$work/bin:$PATH"

mkdir "$work/good"
network_preflight "$work/good"
grep -Fq 'pacman-key --add /root/cachyos-key.asc' "$work/good/cachyos-repo/cachyos-repo.sh"
grep -Fq 'pacman-key --lsign-key 882DCFE48E2051D48E2562ABF3B607488DB35A47' "$work/good/cachyos-repo/cachyos-repo.sh"
grep -Fq 'search=0x882DCFE48E2051D48E2562ABF3B607488DB35A47' "$work/curl.calls"
[[ $(wc -l < "$work/curl.calls") == 3 ]]

# Run failures in new shells so errexit behavior matches the real installer.
for failure in archive key collision subkey multiple missing; do
    mkdir "$work/$failure"
    if CHECK_FAIL=$failure bash -euo pipefail -c \
        'source "$1/install.sh"; network_preflight "$2"; touch "$2/unsafe-disk-write"' \
        _ "$repo" "$work/$failure" > "$work/$failure.out" 2>&1; then
        echo "FAIL: $failure failure was ignored" >&2; exit 1
    fi
    [[ ! -e "$work/$failure/unsafe-disk-write" ]]
done

# Refuse an upstream key-import change instead of silently patching wrong code.
sed -i -e 's/f3b607488db35a47/changed/g' -e 's/882DCFE48E2051D48E2562ABF3B607488DB35A47/CHANGED/g' "$work/upstream/cachyos-repo/cachyos-repo.sh"
tar -cJf "$work/archive.tar.xz" -C "$work/upstream" cachyos-repo
mkdir "$work/changed"
if bash -euo pipefail -c 'source "$1/install.sh"; network_preflight "$2"' \
    _ "$repo" "$work/changed" > "$work/changed.out" 2>&1; then
    echo 'FAIL: changed upstream key import accepted' >&2; exit 1
fi

printf '[options]\nXferCommand = old\nSigLevel = Required DatabaseOptional\n[core]\nInclude = /etc/pacman.d/mirrorlist\n' > "$work/pacman.conf"
configure_downloads "$work/pacman.conf"
configure_downloads "$work/pacman.conf"
[[ $(grep -c '^XferCommand =' "$work/pacman.conf") == 1 ]]
grep -q -- '--retry-all-errors' "$work/pacman.conf"
grep -q '^SigLevel = Required DatabaseOptional$' "$work/pacman.conf"
grep -q '^\[core\]$' "$work/pacman.conf"

# Logging captures output but never traces the password-bearing shell commands.
(
    start_log "$work/live.log"
    STAGE='fixture bootstrap'
    printf 'stage: %s\n' "$STAGE"
    USER_PASSWORD='fixture-secret-never-log'
    printf 'simulated failure: exit 28\n' >&2
    finish_log "$work/saved/install.log"
)
cmp "$work/live.log" "$work/saved/install.log"
[[ $(stat -c %a "$work/saved/install.log") == 600 ]]
! grep -q 'fixture-secret-never-log' "$work/saved/install.log"

# Protect the main ordering: network preflight must precede every partition write.
python3 - "$repo/install.sh" <<'PY'
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text()
main = text.split('[[ ${BASH_SOURCE[0]} == "$0" ]] || return 0', 1)[1]
preflight = main.index('network_preflight "$NETWORK_DIR"')
for operation in ('append_layout "$TARGET_DISK"', 'sgdisk --zap-all', 'mkfs.vfat', 'mkfs.btrfs'):
    assert preflight < main.index(operation), operation
assert 'trap cleanup EXIT' in main
assert 'trap ' in main and ' ERR' in main
assert 'cp -- "$NETWORK_DIR/cachyos-key.asc"' in main
PY
# Real partition-tool integration on a disposable sparse file, never a device.
command -v sfdisk >/dev/null
image="$work/disk.img"
truncate -s 20G "$image"
printf 'label: gpt\nstart=2048,size=4096,type=U\nstart=6144,size=8192,type=L\n' \
    | sfdisk "$image" > "$work/image-create.log" 2>&1
printf 'PRESERVE OLD EFI' | dd of="$image" bs=1 seek=1048576 conv=notrunc status=none
printf 'PRESERVE OLD ROOT' | dd of="$image" bs=1 seek=3145728 conv=notrunc status=none
old_data=$(dd if="$image" bs=512 skip=2048 count=12288 status=none | sha256sum)
mkdir "$work/image-backup"
read_gpt "$image" "$work/image-backup/validation.log" > "$work/before.dump"
regions=$(eligible_regions "$image" 512)
read -r first last <<< "$regions"
plan_free_region "$first" "$last" 512
read -r EFI_PARTUUID < /proc/sys/kernel/random/uuid
read -r ROOT_PARTUUID < /proc/sys/kernel/random/uuid
printf 'start=%s,size=%s,type=U,uuid=%s,name="HYPRCACHY_EFI"\nstart=%s,size=%s,type=L,uuid=%s,name="HYPRCACHY_ROOT"\n' \
    "$EFI_START" "$EFI_SECTORS" "$EFI_PARTUUID" "$ROOT_START" "$ROOT_SECTORS" "$ROOT_PARTUUID" > "$work/layout"
append_layout "$image" "$work/before.dump" "$work/layout" "$work/image-backup"
[[ $(dd if="$image" bs=512 skip=2048 count=12288 status=none | sha256sum) == "$old_data" ]]
[[ $(sfdisk --dump "$image" | grep -c '^.*disk.img[1-4] :') == 4 ]]

# Reject a changed table before another append, leaving that table untouched.
sfdisk --part-label "$image" 1 CHANGED > /dev/null
sfdisk --dump "$image" > "$work/changed-table.dump"
if (append_layout "$image" "$work/before.dump" "$work/layout" "$work/image-backup") > "$work/changed-table.out" 2>&1; then
    echo 'FAIL: changed partition table accepted' >&2; exit 1
fi
sfdisk --dump "$image" > "$work/after-rejection.dump"
cmp "$work/changed-table.dump" "$work/after-rejection.dump"
printf 'PASS: bootstrap preflight, failure boundaries, signed-package configuration, persistent private logs, disk-write ordering, and real GPT preservation\n'
