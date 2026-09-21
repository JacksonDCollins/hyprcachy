"""Non-destructive checks for repeated config application and installer separation."""

import os
import subprocess
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
source = (root / 'setup.sh').read_text()
installer = (root / 'install.sh').read_text()
for forbidden in ('sgdisk ', 'mkfs.', 'useradd ', 'chpasswd', 'create-config', 'limine-install'):
    assert forbidden not in source, forbidden
assert 'pacman -Syu --needed' in source
assert 'arch-chroot /mnt /usr/bin/bash /root/hyprcachy-setup.sh "$NEW_USER"' in installer
assert installer.index('setup.sh must be beside') < installer.index('sgdisk --zap-all')
assert 'git clone' not in installer

with tempfile.TemporaryDirectory() as tmp:
    base = Path(tmp)
    config = base / 'etc/greetd/config.toml'
    config.parent.mkdir(parents=True)
    config.write_text('original config')
    bin_dir = base / 'bin'
    bin_dir.mkdir()
    systemctl = bin_dir / 'systemctl'
    systemctl.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$CALLS"\n')
    systemctl.chmod(0o755)
    env = dict(os.environ, PATH=f'{bin_dir}:{os.environ["PATH"]}', CALLS=str(base / 'calls'))
    body = 'set -euo pipefail\ndie() { echo "$*" >&2; exit 1; }\n' + source.split('# Replace only', 1)[1].split('\n', 1)[1]
    body = body.replace('/etc/greetd/', str(config.parent) + '/')

    def run(status=0):
        result = subprocess.run(['bash', '-c', body], env=env, capture_output=True, text=True)
        assert result.returncode == status, result.stderr

    run()
    backup = config.with_name('config.toml.hyprcachy-backup')
    assert backup.read_text() == 'original config'
    generated = config.read_text()
    run()
    assert config.read_text() == generated
    assert len(list(config.parent.glob('*backup*'))) == 1
    config.write_text('custom config')
    run()
    assert backup.read_text() == 'custom config'
    assert config.with_name('config.toml.hyprcachy-backup.~1~').read_text() == 'original config'
    config.unlink()
    config.symlink_to(backup)
    run(status=1)
    assert backup.read_text() == 'custom config'
    calls = (base / 'calls').read_text().splitlines()
    assert calls == ['enable NetworkManager greetd.service', '--global enable hyprpolkitagent.service'] * 3
print('PASS: install/setup separation, repeatable config backups, symlink refusal, and enable-only services')
