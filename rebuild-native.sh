#!/usr/bin/env bash
# Build only the requested component, or explicitly update all native packages.
set -euo pipefail
(( EUID != 0 )) || { echo 'Run this as your normal user; only pacman needs sudo.' >&2; exit 1; }
[[ $# == 1 && ( $1 == window-session || $1 == tmux || $1 == all ) ]] || {
    echo 'Usage: rebuild-native.sh window-session|tmux|all' >&2; exit 1;
}
repo=$(dirname -- "$(realpath -- "${BASH_SOURCE[0]}")")
sources=("$repo/packages/$1")
if [[ $1 == all ]]; then
    # Explicit coordinated update also retires any old bundled plugin guard.
    sources=("$repo/packages/upgrade-guard" "$repo/packages/window-session" "$repo/packages/tmux")
fi
packages=()
for source_dir in "${sources[@]}"; do
    cd -- "$source_dir"
    metadata=$(makepkg --printsrcinfo)
    requirements=$(awk -v coordinated="$1" '
        $1 ~ /^(make|check)?depends(_.*)?$/ {
            if (coordinated == "all" && $3 ~ /^hyprcachy-upgrade-guard([<>=]|$)/) next
            print $3
        }' <<< "$metadata")
    [[ -n $requirements ]] || { echo 'Cannot determine package prerequisites.' >&2; exit 1; }
    mapfile -t required <<< "$requirements"
    if ! missing=$(pacman -T "${required[@]}"); then
        printf 'Missing prerequisites:\n%s\n' "$missing" >&2
        echo 'Use ./update-native.sh to install/update the local guard and both components together.' >&2
        echo 'Install missing distribution prerequisites with a normal full system update, then retry.' >&2
        exit 1
    fi
    # Prerequisites were checked above; only an all-package update defers its local guard.
    makepkg --nodeps --cleanbuild --clean --force
    built=$(makepkg --packagelist)
    [[ $built != *$'\n'* && -f $built ]] || { echo 'Expected exactly one built native package.' >&2; exit 1; }
    packages+=("$built")
done
exec sudo pacman -U -- "${packages[@]}"
