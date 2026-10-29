#!/usr/bin/env bash
# Build only the requested component, or explicitly update all native packages.
set -euo pipefail
# Internal isolated stage; the ordinary component rebuild path remains below.
if [[ ${1:-} == --candidate ]]; then
shift
export PATH=/usr/bin LC_ALL=C
[[ -f /run/host/container-manager && $(< /run/host/container-manager) == systemd-nspawn &&
   -d /input && -d /output && -f /control/candidate ]] || {
    echo 'Native package building requires the isolated nspawn root.' >&2; exit 1;
}
if [[ ${1:-} == --build ]]; then
    (( EUID != 0 && $# == 1 ))
    cd /work/sources
    bsdtar -xf /input/native-sources.tar
    bsdtar -xf /input/tmux-source.tar -C /work/tmux
    export HYPRCACHY_TMUX_INPUT=/work/tmux HYPRCACHY_UPDATE_PLAN=/input/update-plan
    mapfile -t directories < /input/tmux-directory
    (( ${#directories[@]} == 1 ))
    export HYPRCACHY_TMUX_SOURCE_DIRECTORY=${directories[0]}
    [[ $HYPRCACHY_TMUX_SOURCE_DIRECTORY == /* && $HYPRCACHY_TMUX_SOURCE_DIRECTORY != *\\* ]]
    cp /etc/makepkg.conf /work/makepkg.conf
    printf '\nunset BUILDDIR SRCDEST LOGDEST SRCPKGDEST\nPKGDEST=/output\nMAKEFLAGS=-j2\n' >> /work/makepkg.conf
    builder=(makepkg --config /work/makepkg.conf --nosign)
    for component in upgrade-guard window-session tmux; do
        cd "/work/sources/$component"
        metadata=$("${builder[@]}" --printsrcinfo)
        requirements=$(awk '$1 ~ /^(make|check)?depends(_.*)?$/ && $3 !~ /^hyprcachy-upgrade-guard([<>=]|$)/ { print $3 }' <<< "$metadata")
        [[ -n $requirements ]]
        mapfile -t required <<< "$requirements"
        pacman -T "${required[@]}"
        # Only the local guard is deferred to the final combined transaction.
        "${builder[@]}" --nodeps --cleanbuild --clean --force --noconfirm
        built=$("${builder[@]}" --packagelist)
        [[ $built != *$'\n'* && $built == /output/* && -f $built && ! -L $built ]]
        identity=$(pacman -Qp -- "$built")
        [[ ${identity%% *} == "hyprcachy-$component" ]]
    done
    : > /output/success
    exit 0
fi
(( EUID == 0 && $# == 0 ))
pacman-conf > /output/config.actual
cmp /input/config /output/config.actual
mkdir -p /work/no-hooks /work/home /work/sources /work/tmux
mapfile -t hookdirs < <(pacman-conf HookDir)
hookdirs+=(/usr/share/libalpm/hooks)
for dir in "${hookdirs[@]}"; do
    for hook in "$dir/"*.hook; do
        [[ -e $hook || -L $hook ]] || continue
        ln -sf /dev/null "/work/no-hooks/${hook##*/}"
    done
done
archives=()
while IFS=$'\t' read -r _name _version filename _rest; do
    archives+=("/input/$filename")
    bsdtar -tf "/input/$filename" > /work/archive-files
    while IFS= read -r file; do
        [[ $file == *.hook ]] || continue
        ln -sf /dev/null "/work/no-hooks/${file##*/}"
    done < /work/archive-files
done < /input/plan
if (( ${#archives[@]} )); then
    pacman -Up --noconfirm --print-format $'%n\t%v' -- "${archives[@]}" | sort > /work/actual
    cut -f1,2 /input/plan | sort > /work/expected
    cmp /work/expected /work/actual
    # Mask hooks/scriptlets only in this disposable root, never on the host.
    pacman --disable-sandbox-network --noscriptlet --hookdir /work/no-hooks -U --noconfirm -- "${archives[@]}"
fi
while IFS=$'\t' read -r name version rest; do
    [[ $(pacman -Q -- "$name") == "$name $version" ]]
done < /input/plan
ldconfig
chown -R 65534:65534 /work/home /work/sources /work/tmux
chown 65534:65534 /work
exec setpriv --reuid=65534 --regid=65534 --clear-groups --no-new-privs \
    env -i PATH=/usr/bin LC_ALL=C HOME=/work/home /bin/bash /control/candidate --candidate --build

exit 0
fi

(( EUID != 0 )) || { echo 'Run this as your normal user; only pacman needs sudo.' >&2; exit 1; }
[[ ( $# == 1 || ( $# == 3 && $2 == --package-list && -n $3 ) ) &&
   ( $1 == window-session || $1 == tmux || $1 == upgrade-guard || $1 == all ) ]] || {
    echo 'Usage: rebuild-native.sh window-session|tmux|upgrade-guard|all [--package-list FILE]' >&2; exit 1;
}
# The full-update driver collects packages before starting its single install transaction.
package_list=${3:-}
repo=$(dirname -- "$(realpath -- "${BASH_SOURCE[0]}")")
sources=("$repo/packages/$1")
if [[ $1 == all ]]; then
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
if [[ -n $package_list ]]; then
    printf '%s\0' "${packages[@]}" > "$package_list"
else
    exec sudo pacman -U -- "${packages[@]}"
fi
