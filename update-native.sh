#!/usr/bin/env bash
# Explicitly build and install the guard and both components in one transaction.
set -euo pipefail
exec "$(dirname -- "$(realpath -- "${BASH_SOURCE[0]}")")/rebuild-native.sh" all "$@"
