# shellcheck shell=bash
# Shared, data-only verification helpers. Never source transaction manifests.
gate_error() { echo "Window-session upgrade blocked: $*" >&2; return 1; }
# Serialize hooks and retention cleanup without creating or removing pacman's lock.
lock_state() {
    state=/run/hyprcachy-window-session
    (( EUID == 0 )) || { gate_error 'Root is required.'; return 1; }
    [[ ! -L "$state" ]] || return 1
    if [[ -e "$state" ]]; then [[ $(stat -c '%u:%a' "$state") == 0:700 ]] || return 1; fi
    install -d -m 0700 "$state" || return 1
    [[ ! -L "$state/maintenance.lock" ]] || return 1
    exec 9>"$state/maintenance.lock" || return 1
    flock "$@" 9
}
database_fingerprint() {
    (cd -- "$1" && find . -type f ! -path './db.lck' -print0 | LC_ALL=C sort -z | xargs -0 sha256sum) | sha256sum | cut -d ' ' -f 1
}
same_targets() {
    local a b
    [[ -s "$1" && -s "$2" ]] || return 1
    a=$(LC_ALL=C sort -u -- "$1") || return 1
    b=$(LC_ALL=C sort -u -- "$2") || return 1
    [[ $a == "$b" ]]
}
# Parse only replayable pacman options. Do not eval command lines or replay refreshes.
# Outputs operation, replay_options, replay_targets and extra_caches arrays.
parse_transaction() {
    local arg option value char i selected
    operation='' replay_options=() replay_targets=() extra_caches=()
    shift # argv[0]; the caller separately checks /proc/PID/exe.
    while (( $# > 0 )); do
        arg=$1; shift
        case $arg in
            --) replay_targets+=("$@"); break ;;
            --sync|--upgrade)
                selected=S; [[ $arg != --upgrade ]] || selected=U
                [[ -z $operation || $operation == "$selected" ]] || return 1
                operation=$selected ;;
            --refresh|--noconfirm|--confirm|--quiet|--verbose|--debug|--noprogressbar|--disable-download-timeout|--disable-sandbox) ;;
            --sysupgrade|--needed|--asdeps|--asexplicit) replay_options+=("$arg") ;;
            --ignore|--ignore=*|--ignoregroup|--ignoregroup=*|--overwrite|--overwrite=*|--cachedir|--cachedir=*|--config|--config=*|--color|--color=*|--ask|--ask=*|--root|--root=*|--dbpath|--dbpath=*|--logfile|--logfile=*)
                option=${arg%%=*}
                if [[ $arg == *=* ]]; then value=${arg#*=}; else
                    (( $# > 0 )) || return 1
                    value=$1; shift
                fi
                [[ -n $value ]] || return 1
                case $option in
                    --config) [[ $value == /etc/pacman.conf ]] || { gate_error 'Non-default pacman configuration is not supported.'; return 1; } ;;
                    --cachedir) extra_caches+=("$value") ;;
                    --root) [[ $value == / ]] || { gate_error 'Non-default root is not supported.'; return 1; } ;;
                    --dbpath) [[ $value == /var/lib/pacman || $value == /var/lib/pacman/ ]] || { gate_error 'Non-default database path is not supported.'; return 1; } ;;
                    --color|--logfile) ;;
                    *) replay_options+=("$option" "$value") ;;
                esac ;;
            --*) gate_error "Cannot safely replay option $arg."; return 1 ;;
            -?*)
                for (( i=1; i<${#arg}; i++ )); do
                    char=${arg:i:1}
                    case $char in
                        S|U)
                            [[ -z $operation || $operation == "$char" ]] || return 1
                            operation=$char ;;
                        y|q|v) ;;
                        u) replay_options+=(--sysupgrade) ;;
                        *) gate_error "Cannot safely replay short option -$char."; return 1 ;;
                    esac
                done ;;
            -) gate_error 'Stdin package lists cannot be replayed; pass explicit targets.'; return 1 ;;
            *) replay_targets+=("$arg") ;;
        esac
    done
    [[ $operation == S || $operation == U ]] || { gate_error 'Expected a sync or local-package transaction.'; return 1; }
    for arg in "${replay_targets[@]}"; do
        [[ $arg != - ]] || { gate_error 'Stdin package lists cannot be replayed.'; return 1; }
    done
}
# Track native compatibility, not dependencies of maintenance/notification tools.
compatibility_dependencies() {
    local root
    printf '%s\n' hyprcachy-window-session
    for root in hyprland lua gcc make pkgconf; do
        pactree --unique --linear "$root" || return 1
    done
}
# Provider/replacement menus can contain the SAME name from different repositories.
# Matching target names alone cannot prove which build the user selected.
verify_provider_identity() {
    local name=$1 version=$2 hash=$3 archive=$4 mode=$5 requirements=$6 explicit rows candidate candidate_version candidate_hash extra metadata key equal replaced replacement=false provides matched
    shift 6
    for explicit in "$@"; do [[ $explicit != "$name" ]] || return 0; done
    metadata=$(bsdtar -xOf "$archive" --fast-read .PKGINFO) || return 1
    while read -r key equal replaced extra; do
        [[ $key == replaces && $equal == = ]] || continue
        replaced=${replaced%%[<>=]*}
        if [[ $replaced != "$name" ]] && pacman -Q -- "$replaced" > /dev/null 2>&1; then replacement=true; break; fi
    done <<< "$metadata"
    if [[ $mode != all ]] && ! $replacement; then
        pacman -Q -- "$name" > /dev/null 2>&1 && return 0
        grep -q '^provides = ' <<< "$metadata" || return 0
        if [[ -n $requirements ]]; then
            # Literal targets/dependencies use repository priority, not a provider menu.
            # Only provisions actually requested by this plan can introduce a choice.
            provides=$(awk -v name="$name" '$1 == "provides" && $2 == "=" { sub(/[<>=].*$/, "", $3); if ($3 != name) print $3 }' <<< "$metadata")
            matched=$(grep -Fxf "$requirements" <<< "$provides") || [[ $? == 1 ]] || return 1
            [[ -n $matched ]] || return 0
        fi
    fi
    # Info mode includes every repository, even versions excluded by IgnorePkg.
    # A print/prepare query would hide those and could miss an interactive override.
    metadata=$(pacman --color never -Sii -- "$name") || return 1
    rows=$(awk '
        /^Name[[:space:]]*:/ { name=$3; version=""; names++ }
        /^Version[[:space:]]*:/ { version=$3 }
        /^SHA-256 Sum[[:space:]]*:/ { print name "\t" version "\t" $4; hashes++ }
        END { if (!names || names != hashes) exit 1 }
    ' <<< "$metadata") || { gate_error 'Cannot inspect repository provider identities.'; return 1; }
    while IFS=$'\t' read -r candidate candidate_version candidate_hash extra; do
        [[ $candidate == "$name" && $candidate_version == "$version" && $candidate_hash == "$hash" && -z $extra ]] || {
            gate_error "Ambiguous provider/replacement $name across repositories; specify it explicitly (repo/$name) in the normal pacman command."; return 1;
        }
    done <<< "$rows"
}
verify_commit() {
    local stage=$1 parent=$2 proc=$3 database=$4 current
    [[ -f "$stage/passed" ]] || { gate_error 'No successful preflight.'; return 1; }
    [[ $(< "$stage/pid") == "$parent" ]] || { gate_error 'Approval belongs to another process.'; return 1; }
    cmp -s "$stage/command" "$proc/$parent/cmdline" || { gate_error 'Transaction command differs from staged archives.'; return 1; }
    cmp -s "$stage/config" "$stage/config.current" || { gate_error 'Pacman configuration changed during preflight.'; return 1; }
    current=$(database_fingerprint "$database") || { gate_error 'Cannot fingerprint the installed database.'; return 1; }
    [[ $current == "$(< "$stage/database")" ]] || {
        gate_error 'Package databases changed during preflight; retry.'; return 1;
    }
    (cd -- "$stage/packages" && sha256sum --check --strict ../archives.sha256) || {
        gate_error 'Incoming archives changed after compilation.'; return 1;
    }
    sha256sum --check --strict "$stage/sources.sha256" || {
        gate_error 'Original package files changed during preflight.'; return 1;
    }
    (cd -- "$stage/check/build" && sha256sum --check --strict ../../artifacts.sha256) || {
        gate_error 'Compiled plugin artifacts changed.'; return 1;
    }
}
publish_artifacts() {
    local stage=$1 output=$2
    (cd -- "$stage/check/build" && sha256sum --check --strict ../../artifacts.sha256) || return 1
    install -m 0644 "$stage/check/build/window-session.so" "$output/window-session.so.new" &&
        mv -f -- "$output/window-session.so.new" "$output/window-session.so"
}
