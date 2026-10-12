#!/usr/bin/env bash
# Prepare the complete system upgrade, then install it and local native packages together.
set -euo pipefail
export LC_ALL=C
(( EUID != 0 )) || { echo 'Run ./update-native.sh as your normal user.' >&2; exit 1; }
[[ $# == 0 || ( $# == 2 && $1 == --prepare && -n $2 ) ]] || {
    echo 'Usage: update-native.sh [--prepare DIRECTORY (setup only)]' >&2; exit 1;
}
prepare_only=false
(( $# == 0 )) || prepare_only=true
repo=$(dirname -- "$(realpath -- "${BASH_SOURCE[0]}")")
# This is the user's checkout, sourced only by the unprivileged update driver.
source "$repo/packages/upgrade-guard/gate-lib.sh"
if $prepare_only; then
    # Setup owns download, installation and cleanup; this process only prepares as the user.
    stage=$2
    [[ $stage == /* && -d $stage && ! -L $stage && $(stat -c '%u:%a' -- "$stage") == "$EUID:700" ]]
    [[ -z $(find "$stage" -mindepth 1 -print -quit) ]]
else
    stage=$(mktemp -d)
    trap 'rm -rf -- "$stage"' EXIT
    # Match the frozen print plan's default provider choices; installation still asks for confirmation.
    sudo pacman -Syu --downloadonly --noconfirm
fi
trap 'exit 130' INT
trap 'exit 143' TERM
[[ $(pacman-conf RootDir) == / && $(pacman-conf DBPath) == /var/lib/pacman/ ]]
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
export HYPRCACHY_UPDATE_PLAN="$stage/update-plan"
"$repo/rebuild-native.sh" all --package-list "$stage/native-packages"
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
if $prepare_only; then
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
