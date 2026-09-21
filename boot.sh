#!/usr/bin/env bash
set -euo pipefail
workdir=$(mktemp -d /tmp/hyprcachy.XXXXXX)
trap 'rm -rf "$workdir"' EXIT
base=https://raw.githubusercontent.com/JacksonDCollins/hyprcachy/refs/heads/main
printf '\nDownloading Hyprcachy installer and setup from GitHub...\n'
systemd-run --quiet --wait --pipe -p Wants=network-online.target -p After=network-online.target \
    /usr/bin/curl --proto '=https' --fail-early --fail --location \
    --retry 5 --retry-all-errors --connect-timeout 15 \
    --output "$workdir/install.sh" "$base/install.sh" \
    --output "$workdir/setup.sh" "$base/setup.sh"
bash -n "$workdir/install.sh"
bash -n "$workdir/setup.sh"
bash "$workdir/install.sh"
