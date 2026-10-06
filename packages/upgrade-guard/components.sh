# shellcheck shell=bash
# Adapter API v1. Registration is executable package code, never user configuration.
component_name() { [[ $1 =~ ^hyprcachy-[a-zA-Z0-9@._+-]+$ ]]; }
select_components() {
    local stage=$1 registry=$2 directory name watched
    : > "$stage/check/selected"
    for directory in "$registry/"*; do
        [[ -d $directory && ! -L $directory ]] || continue
        name=${directory##*/}
        component_name "$name" || return 1
        component_active "$name" "$stage" || continue
        [[ -f "$directory/adapter" && ! -L "$directory/adapter" ]] || return 1
        [[ $(pacman -Qqo -- "$directory/adapter") == "$name" ]] || return 1
        if grep -qxF -e "$name" -e hyprcachy-upgrade-guard "$stage/incoming"; then
            printf '%s\n' "$name" >> "$stage/check/selected"
        else
            watched=$(bash -p "$directory/adapter" watch) || return 1
            if grep -Fxf "$stage/check/expected-targets" <<< "$watched" >/dev/null; then
                printf '%s\n' "$name" >> "$stage/check/selected"
            fi
        fi
    done
}
# Freeze installed registrations, then replace them with the actual incoming
# package payloads. Only flat files are supported; never extract archive paths.
prepare_components() {
    local stage=$1 registry=$2 directory name file archive identity member prefix adapter artifact mode destination extra declarations
    mkdir "$stage/check/adapters" "$stage/check/input"
    for directory in "$registry/"*; do
        [[ -d $directory && ! -L $directory ]] || continue
        name=${directory##*/}
        component_name "$name" || return 1
        component_active "$name" "$stage" || continue
        mkdir "$stage/check/adapters/$name"
        for file in "$directory/"*; do
            [[ -f $file && ! -L $file && ${file##*/} =~ ^[a-zA-Z0-9._-]+$ ]] || return 1
            [[ $(pacman -Qqo -- "$file") == "$name" ]] || return 1
            sha256sum -- "$file" >> "$stage/sources.sha256"
            cp -- "$file" "$stage/check/adapters/$name/"
        done
    done
    for archive in "$stage/packages/"*.pkg.tar*; do
        [[ $archive != *.sig ]] || continue
        identity=$(pacman -Qp -- "$archive") || return 1
        name=${identity%% *}
        [[ $name =~ ^[a-zA-Z0-9@._+-]+$ && $name != . && $name != .. ]] || return 1
        component_name "$name" || continue
        rm -rf -- "$stage/check/adapters/$name"
        prefix="usr/lib/hyprcachy/upgrade.d/$name/"
        bsdtar -tf "$archive" > "$stage/adapter-members" || return 1
        while IFS= read -r member; do
            [[ $member == usr/lib/hyprcachy/upgrade.d/* && $member != */ ]] || continue
            component_name "$name" && [[ $member == "$prefix"* ]] || return 1
            file=${member#"$prefix"}
            [[ $file =~ ^[a-zA-Z0-9._-]+$ && $file != . && $file != .. ]] || return 1
            mkdir -p "$stage/check/adapters/$name"
            [[ ! -e "$stage/check/adapters/$name/$file" ]] || return 1
            bsdtar -xOf "$archive" --fast-read "$member" > "$stage/check/adapters/$name/$file" || return 1
        done < "$stage/adapter-members"
    done
    # An updated selected component may not silently drop its adapter.
    while IFS= read -r name; do
        [[ -s "$stage/check/adapters/$name/adapter" ]] || return 1
    done < "$stage/check/selected"
    : > "$stage/check/components"
    : > "$stage/check/publications"
    for directory in "$stage/check/adapters/"*; do
        [[ -d $directory ]] || continue
        name=${directory##*/}
        if ! grep -qxF "$name" "$stage/check/selected" && ! grep -qxF "$name" "$stage/incoming"; then continue; fi
        adapter=$directory/adapter
        [[ -s $adapter ]] || return 1
        chmod 0755 "$directory/"*
        printf '%s\n' "$name" >> "$stage/check/components"
        mkdir "$stage/check/input/$name"
        timeout --kill-after=10s 300s bash -p "$adapter" prepare "$stage/check/input/$name" "$stage/packages" || return 1
        declarations=$(bash -p "$adapter" artifacts) || return 1
        [[ -n $declarations ]] || return 1
        while IFS=$'\t' read -r artifact mode destination extra; do
            [[ $artifact =~ ^[a-zA-Z0-9._-]+$ && $artifact != . && $artifact != .. && -z $extra ]] || return 1
            publication_path "$mode" "$destination" || return 1
            printf '%s/%s\t%s\t%s\n' "$name" "$artifact" "$mode" "$destination" >> "$stage/check/publications"
        done <<< "$declarations"
    done
    [[ -s "$stage/check/components" ]] || { : > "$stage/skipped"; return 0; }
    [[ -z $(find "$stage/check/input" ! -type d ! -type f -print -quit) ]] || return 1
    # All output names and destinations must be unique before any work is authorized.
    [[ -z $(cut -f1 "$stage/check/publications" | sort | uniq -d) && -z $(cut -f3 "$stage/check/publications" | sort | uniq -d) ]] || return 1
    printf '1\n' > "$stage/check/protocol"
    hash_controls "$stage/check" > "$stage/controls.sha256" || return 1
    cp -- "$stage/controls.sha256" "$stage/check/controls.sha256"
}
hash_controls() {
    local check=$1
    [[ -z $(find "$check/adapters" "$check/input" ! -type d ! -type f -print -quit) ]] || return 1
    (cd "$check" || exit; find adapters input -type f -print0 && printf '%s\0' protocol components publications candidate-check gate-lib.sh components.sh) |
        (cd "$check" || exit; sort -z | xargs -0 sha256sum)
}
verify_controls() {
    local actual
    [[ $(< "$1/check/protocol") == 1 ]] || return 1
    actual=$(hash_controls "$1/check") || return 1
    [[ $actual == "$(< "$1/controls.sha256")" ]]
}
