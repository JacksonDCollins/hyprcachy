#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "$(realpath -- "${BASH_SOURCE[0]}")")/plugins/window-session"
exec makepkg --syncdeps --cleanbuild --clean --force --install "$@"
