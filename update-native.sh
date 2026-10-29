#!/usr/bin/env bash
# Prepare the complete system upgrade, then install it and local native packages together.
set -euo pipefail
# Internal root-only stage used by setup and the normal updater.
if [[ ${1:-} == --build-staged ]]; then
shift
export PATH=/usr/bin LC_ALL=C
umask 077
(( EUID == 0 && $# == 2 )) || { echo 'Usage: sudo update-native.sh --build-staged STAGE USER_UID' >&2; exit 1; }
stage=$(realpath -e -- "$1")
uid=$2
[[ $uid =~ ^[1-9][0-9]*$ && $stage != *$'\n'* && $stage != *\\* &&
   -d $stage && $(stat -c '%u:%a' -- "$stage") == "$uid:700" ]]
gid=$(id -g "$uid")
reader=(setpriv --reuid="$uid" --regid="$gid" --clear-groups --no-new-privs env -i PATH=/usr/bin LC_ALL=C)
repo=$(dirname -- "$(realpath -- "${BASH_SOURCE[0]}")")
source "$repo/packages/upgrade-guard/gate-lib.sh"
[[ $(pacman-conf RootDir) == / && $(pacman-conf DBPath) == /var/lib/pacman/ && $(findmnt -n -o FSTYPE /) == btrfs ]]
for dir in /var/lib/hyprcachy /var/lib/hyprcachy/native-builds; do
    [[ ! -L $dir ]]
    if [[ -e $dir ]]; then
        [[ -d $dir && $(stat -c %u "$dir") == 0 ]]
        (( (8#$(stat -c %a "$dir") & 0022) == 0 ))
    else
        install -d -m 0700 -- "$dir"
    fi
done
work=$(mktemp -d /var/lib/hyprcachy/native-builds/build.XXXXXXXX)
locked=false
cleanup() {
    local status=$?
    if $locked; then rm -f /var/lib/pacman/db.lck; fi
    if [[ -d $work/root ]]; then
        if ! btrfs subvolume delete "$work/root" || ! btrfs subvolume sync /; then
            echo "Scratch snapshot retained at $work; remove it manually." >&2
            exit 1
        fi
    fi
    rm -rf -- "$work"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
mkdir "$work/input" "$work/control" "$work/output"
# Read user files only as that user, without following final symlinks or devices.
freeze() {
    local name=$1 limit=$2 before after copied
    [[ $name =~ ^[a-zA-Z0-9@._+:~-]+$ && -f $stage/$name && ! -L $stage/$name ]]
    before=$(timeout 60s "${reader[@]}" sha256sum -- "$stage/$name")
    timeout 60s "${reader[@]}" dd if="$stage/$name" iflag=nofollow,nonblock,count_bytes count="$((limit + 1))" status=none > "$work/input/$name"
    (( $(stat -c %s "$work/input/$name") <= limit ))
    after=$(timeout 60s "${reader[@]}" sha256sum -- "$stage/$name")
    copied=$(sha256sum "$work/input/$name")
    [[ ${before%% *} == "${copied%% *}" && $before == "$after" ]] || { echo 'Staging input changed; retry.' >&2; exit 1; }
}
for file in plan config update-plan tmux-directory; do freeze "$file" 1048576; done
for file in native-sources.tar tmux-source.tar; do freeze "$file" 536870912; done
while IFS=$'\t' read -r name version filename hash signature extra; do
    [[ $name =~ ^[a-zA-Z0-9@._+-]+$ && -n $version && -z $extra &&
       $filename =~ ^[a-zA-Z0-9@._+:~^-]+\.pkg\.tar(\.[a-zA-Z0-9]+)?$ &&
       $hash =~ ^[a-f0-9]{64}$ && -n $signature && $signature != '(null)' ]]
    freeze "$filename" 2147483648
    (cd "$work/input"; printf '%s  %s\n' "$hash" "$filename" | sha256sum --check --strict)
    printf '%s' "$signature" | base64 --decode > "$work/input/$filename.sig"
done < "$work/input/plan"
# Hold pacman's lock only while checking/copying its databases into the snapshot.
if (set -o noclobber; printf '%s\n' "$$" > /var/lib/pacman/db.lck); then locked=true
else echo 'Pacman is busy; retry the coordinated build.' >&2; exit 1; fi
pacman-conf > "$work/config.current"
cmp "$work/input/config" "$work/config.current"
pacman -Sup --noconfirm --print-format $'%n\t%v\t%f\t%h\t%g' > "$work/plan.current"
cmp "$work/input/plan" "$work/plan.current"
database=$(database_fingerprint /var/lib/pacman)
config_hash=$(sha256sum "$work/input/config")
plan_hash=$(sha256sum "$work/input/plan")
printf '%s\n' "$database" "${config_hash%% *}" "${plan_hash%% *}" > "$work/update-plan.current"
cmp "$work/input/update-plan" "$work/update-plan.current"
btrfs subvolume snapshot / "$work/root"
[[ $(database_fingerprint "$work/root/var/lib/pacman") == "$database" ]]
rm -- "$work/root/var/lib/pacman/db.lck" /var/lib/pacman/db.lck
locked=false
install -m 0644 "$repo/rebuild-native.sh" "$work/control/candidate"
chmod 0755 "$work/input" "$work/control"
chmod 0644 "$work/input/"*
chown 65534:65534 "$work/output"
echo 'Building native packages against the pending upgrade in an isolated snapshot...'
timeout --signal=TERM --kill-after=15s 1800s systemd-nspawn --quiet --console=pipe --register=no --private-network --settings=no --link-journal=no \
    --directory="$work/root" --hostname=hyprcachy-package-build --drop-capability=CAP_SYS_ADMIN,CAP_MKNOD \
    --bind-ro="$work/input:/input" --bind-ro="$work/control:/control" --bind="$work/output:/output" \
    /usr/bin/env -i PATH=/usr/bin LC_ALL=C HOME=/root /bin/bash /control/candidate --candidate < /dev/null
# Export as the caller, never write through a user-controlled path as root.
[[ -f $work/output/success && ! -L $work/output/success ]]
"${reader[@]}" mkdir -- "$stage/built"
packages=()
for file in "$work/output/"*.pkg.tar*; do
    [[ -f $file && ! -L $file && ${file##*/} =~ ^hyprcachy-[a-zA-Z0-9._+:~-]+\.pkg\.tar(\.[a-zA-Z0-9]+)?$ ]]
    "${reader[@]}" tee -- "$stage/built/${file##*/}" < "$file" > /dev/null
    packages+=("$stage/built/${file##*/}")
done
(( ${#packages[@]} == 3 ))
printf '%s\0' "${packages[@]}" | "${reader[@]}" tee -- "$stage/native-packages" > /dev/null

exit 0
fi

export LC_ALL=C
(( EUID != 0 )) || { echo 'Run ./update-native.sh as your normal user.' >&2; exit 1; }
[[ $# == 0 || ( $# == 2 && ( $1 == --prepare || $1 == --finish ) && -n $2 ) ]] || {
    echo 'Usage: update-native.sh [--prepare|--finish DIRECTORY (setup only)]' >&2; exit 1;
}
prepare_only=false finish_only=false
if [[ ${1:-} == --prepare ]]; then prepare_only=true; fi
if [[ ${1:-} == --finish ]]; then finish_only=true; fi
repo=$(dirname -- "$(realpath -- "${BASH_SOURCE[0]}")")
# This is the user's checkout, sourced only by the unprivileged update driver.
source "$repo/packages/upgrade-guard/gate-lib.sh"
if $prepare_only || $finish_only; then
    # Setup owns privileged snapshot building, installation and cleanup.
    stage=$2
    [[ $stage == /* && -d $stage && ! -L $stage && $(stat -c '%u:%a' -- "$stage") == "$EUID:700" ]]
    if $prepare_only; then [[ -z $(find "$stage" -mindepth 1 -print -quit) ]]; fi
else
    stage=$(mktemp -d)
    trap 'rm -rf -- "$stage"' EXIT
    # Match the frozen print plan's default provider choices; installation still asks for confirmation.
    sudo pacman -Syu --downloadonly --noconfirm
fi
trap 'exit 130' INT
trap 'exit 143' TERM
[[ $(pacman-conf RootDir) == / && $(pacman-conf DBPath) == /var/lib/pacman/ ]]
if ! $finish_only; then
database=$(database_fingerprint /var/lib/pacman)
installed_names=$(pacman -Qq)
[[ -n $installed_names ]] || { echo 'Installed package list is empty; cannot preserve install reasons.' >&2; exit 1; }
pacman-conf > "$stage/config"
pacman -Sup --noconfirm --print-format $'%n\t%v\t%f\t%h\t%g' > "$stage/plan"
mapfile -t caches < <(pacman-conf CacheDir)
archives=() dependencies=()
unset HYPRCACHY_TMUX_PACKAGE
: > "$stage/expected"
while IFS=$'\t' read -r name version filename hash signature extra; do
    [[ $name =~ ^[a-zA-Z0-9@._+-]+$ && -n $version && -z $extra &&
       $filename =~ ^[a-zA-Z0-9@._+:~^-]+\.pkg\.tar(\.[a-zA-Z0-9]+)?$ &&
       $hash =~ ^[a-f0-9]{64}$ && -n $signature && $signature != '(null)' ]] || {
        echo 'Cannot freeze the full repository upgrade plan.' >&2; exit 1;
    }
    [[ ! -e $stage/$filename ]]
    found=false
    for cache in "${caches[@]}"; do
        [[ -f $cache/$filename ]] || continue
        cp --reflink=auto -- "$cache/$filename" "$stage/$filename"
        found=true; break
    done
    $found || { echo "Downloaded archive missing: $filename" >&2; exit 1; }
    (cd -- "$stage"; printf '%s  %s\n' "$hash" "$filename" | sha256sum --check --strict)
    printf '%s' "$signature" | base64 --decode > "$stage/$filename.sig"
    [[ $(pacman -Qp -- "$stage/$filename") == "$name $version" ]]
    # -U cannot faithfully reproduce -Syu's replacement selection. Never silently change the plan.
    metadata=$(bsdtar -xOf "$stage/$filename" --fast-read .PKGINFO)
    while read -r key equal replacement rest; do
        [[ $key == replaces && $equal == = ]] || continue
        replacement=${replacement%%[<>=]*}
        if [[ $replacement != "$name" ]] && installed=$(pacman -Qq -- "$replacement" 2>/dev/null) && [[ $installed == "$replacement" ]]; then
            echo "Repository replacement $replacement -> $name requires ordinary pacman -Syu before this coordinated update." >&2
            exit 1
        fi
    done <<< "$metadata"
    archives+=("$stage/$filename")
    # With no explicit -S targets or replacements, newly pulled packages are dependencies.
    if ! grep -qxF -- "$name" <<< "$installed_names"; then dependencies+=("$name"); fi
    printf '%s\t%s\n' "$name" "$version" >> "$stage/expected"
    if [[ $name == tmux ]]; then export HYPRCACHY_TMUX_PACKAGE="$stage/$filename"; fi
done < "$stage/plan"

config_hash=$(sha256sum "$stage/config")
plan_hash=$(sha256sum "$stage/plan")
printf '%s\n' "$database" "${config_hash%% *}" "${plan_hash%% *}" > "$stage/update-plan"
# Freeze only the local package recipes and their declared flat-file inputs.
mkdir "$stage/sources"
for component in upgrade-guard window-session tmux; do
    source_dir="$repo/packages/$component"
    metadata=$(cd "$source_dir"; makepkg --printsrcinfo)
    mapfile -t files < <(awk '$1 ~ /^source(_.*)?$/ || $1 == "install" { print $3 }' <<< "$metadata" | sort -u)
    files=(PKGBUILD "${files[@]}")
    mkdir "$stage/sources/$component"
    for file in "${files[@]}"; do
        [[ $file =~ ^[a-zA-Z0-9._-]+$ && $file != . && $file != .. && -f $source_dir/$file && ! -L $source_dir/$file ]] || {
            echo "Unsupported package source: $component/$file" >&2; exit 1;
        }
    done
    (cd "$source_dir"; sha256sum -- "${files[@]}") > "$stage/sources.before"
    for file in "${files[@]}"; do cp -- "$source_dir/$file" "$stage/sources/$component/$file"; done
    (cd "$stage/sources/$component"; sha256sum --check --strict "$stage/sources.before")
    (cd "$source_dir"; sha256sum -- "${files[@]}") > "$stage/sources.after"
    cmp "$stage/sources.before" "$stage/sources.after"
done
archive=()
[[ -z ${HYPRCACHY_TMUX_PACKAGE:-} ]] || archive=("$HYPRCACHY_TMUX_PACKAGE")
bash -p "$stage/sources/tmux/tmux-source" "$stage/tmux-input" "${archive[@]}"
bsdtar -cf "$stage/native-sources.tar" -C "$stage/sources" .
bsdtar -cf "$stage/tmux-source.tar" -C "$stage/tmux-input" .
printf '%s\n' "$repo/packages/tmux" > "$stage/tmux-directory"
if $prepare_only; then exit 0; fi
sudo /usr/bin/bash -p "$repo/update-native.sh" --build-staged "$stage" "$EUID"
fi
# Reconstruct the frozen plan when setup resumes us after its privileged build.
read -r database < "$stage/update-plan"
config_hash=$(sha256sum "$stage/config")
plan_hash=$(sha256sum "$stage/plan")
printf '%s\n' "$database" "${config_hash%% *}" "${plan_hash%% *}" | cmp - "$stage/update-plan"
archives=() dependencies=()
installed_names=$(pacman -Qq)
[[ -n $installed_names ]]
cut -f1,2 "$stage/plan" > "$stage/expected"
while IFS=$'\t' read -r name version filename rest; do
    archives+=("$stage/$filename")
    if ! grep -qxF -- "$name" <<< "$installed_names"; then dependencies+=("$name"); fi
done < "$stage/plan"
mapfile -d '' -t native < "$stage/native-packages"
(( ${#native[@]} == 3 ))
for package in "${native[@]}"; do
    frozen="$stage/${package##*/}"
    [[ ! -e $frozen ]]
    digest=$(sha256sum -- "$package")
    cp --reflink=auto -- "$package" "$frozen"
    copied=$(sha256sum -- "$frozen")
    [[ ${digest%% *} == "${copied%% *}" ]] || { echo 'Native package changed while staging; retry.' >&2; exit 1; }
    [[ ! -f $package.sig ]] || cp -- "$package.sig" "$frozen.sig"
    read -r name version extra < <(pacman -Qp -- "$frozen")
    [[ $name == hyprcachy-* && -n $version && -z $extra ]]
    # A repository-supplied native package must not silently compete with the local checkout.
    if cut -f1 "$stage/expected" | grep -qxF -- "$name"; then
        echo "Both the repository and checkout select $name; choose one source explicitly." >&2; exit 1
    fi
    if [[ $name == hyprcachy-tmux ]]; then
        bsdtar -xOf "$frozen" --fast-read usr/lib/hyprcachy/upgrade.d/hyprcachy-tmux/update-plan > "$stage/packaged-plan"
        cmp -- "$stage/update-plan" "$stage/packaged-plan"
    fi
    archives+=("$frozen")
    printf '%s\t%s\n' "$name" "$version" >> "$stage/expected"
done

[[ $database == "$(database_fingerprint /var/lib/pacman)" ]] || { echo 'Package databases changed while building; retry.' >&2; exit 1; }
pacman-conf > "$stage/config.now"
cmp -- "$stage/config" "$stage/config.now"
pacman -Sup --noconfirm --print-format $'%n\t%v\t%f\t%h\t%g' > "$stage/plan.now"
cmp -- "$stage/plan" "$stage/plan.now"
pacman -Up --noconfirm --print-format $'%n\t%v' -- "${archives[@]}" > "$stage/actual"
sort "$stage/expected" > "$stage/expected.sorted"
sort "$stage/actual" > "$stage/actual.sorted"
cmp -- "$stage/expected.sorted" "$stage/actual.sorted" || {
    echo 'Local installation would change the complete upgrade plan; refusing a partial upgrade.' >&2; exit 1;
}
# The normal guard replays and verifies this actual transaction under pacman's lock.
if $finish_only; then
    printf '%s\0' "${archives[@]}" > "$stage/packages.list"
else
    sudo pacman -U -- "${archives[@]}"
    if (( ${#dependencies[@]} )); then
        sudo pacman -D --asdeps -- "${dependencies[@]}" || {
            printf 'Packages were installed, but dependency marking failed. Retry: sudo pacman -D --asdeps' >&2
            printf ' %q' "${dependencies[@]}" >&2
            printf '\n' >&2
            exit 1
        }
    fi
fi
