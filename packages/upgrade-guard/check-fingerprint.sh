#!/usr/bin/env bash
# Run as a normal user so unreadable-directory checks exercise permissions.
set -euo pipefail
(( EUID != 0 )) || { echo 'Run as a normal user.' >&2; exit 1; }
source "$(dirname -- "${BASH_SOURCE[0]}")/gate-lib.sh"
work=$(mktemp -d)
trap 'chmod -R u+rwX "$work"; rm -rf -- "$work"' EXIT
mkdir -p "$work/local/example" "$work/sync"
printf installed > "$work/local/example/desc"
printf repository > "$work/sync/core.db"
before=$(database_fingerprint "$work")
mkdir "$work/sync/download-test"
printf partial > "$work/sync/download-test/core.db.part"
chmod 000 "$work/sync/download-test"
printf locked > "$work/db.lck"
[[ $(database_fingerprint "$work") == "$before" ]]
printf changed > "$work/sync/core.db"
[[ $(database_fingerprint "$work") != "$before" ]]
before=$(database_fingerprint "$work")
printf changed > "$work/local/example/desc"
[[ $(database_fingerprint "$work") != "$before" ]]
mkdir "$work/local/unreadable"
chmod 000 "$work/local/unreadable"
if database_fingerprint "$work" >/dev/null 2>&1; then
    echo 'Unreadable database directory was silently ignored.' >&2
    exit 1
fi
echo 'PASS: download staging ignored; database changes and permission failures preserved.'
