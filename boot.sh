#!/usr/bin/env bash
set -euo pipefail
workdir=$(mktemp -d /tmp/hyprcachy.XXXXXX)
trap 'rm -rf "$workdir"' EXIT
printf '\nDownloading the complete Hyprcachy source tree for initial installation...\n'
systemd-run --quiet --wait --pipe -p Wants=network-online.target -p After=network-online.target \
    /usr/bin/curl --proto '=https' --proto-redir '=https' --fail --location \
    --retry 5 --retry-connrefused --retry-max-time 120 --connect-timeout 15 --max-time 60 \
    --output "$workdir/source.tar.gz" \
    https://codeload.github.com/JacksonDCollins/hyprcachy/tar.gz/refs/heads/main
mkdir "$workdir/source"
tar -xzf "$workdir/source.tar.gz" --strip-components=1 --no-same-owner --no-same-permissions -C "$workdir/source"
for script in install.sh setup.sh update-native.sh rebuild-native.sh; do
    bash -n "$workdir/source/$script"
done
bash "$workdir/source/install.sh"
