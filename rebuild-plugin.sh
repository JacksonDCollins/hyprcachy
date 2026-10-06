#!/usr/bin/env bash
set -euo pipefail
exec "$(dirname -- "$(realpath -- "${BASH_SOURCE[0]}")")/rebuild-native.sh" window-session "$@"
