"""Non-destructive checks: python tests/test_dotfiles.py"""

import os
import shlex
import subprocess
import tempfile
from pathlib import Path

source = (Path(__file__).resolve().parents[1] / "install.sh").read_text()
block = source.split('# --- 9. USER DOTFILES ---', 1)[1]
command = block[block.index('arch-chroot '):block.index('\necho "=== FINISHED!')]
argv = shlex.split(command.replace('\\\n', ''))
assert argv[:5] == ['arch-chroot', '/mnt', 'runuser', '-u', '$NEW_USER']
assert 'HOME=/home/$NEW_USER' in argv
body = argv[-1]
assert argv[-2] == '-c'

with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    fixture = root / 'fixture'
    for profile in ('default', 'new-profile'):
        (fixture / 'machines' / profile).mkdir(parents=True)
    (fixture / 'machines' / 'not-a-directory').touch()
    (fixture / 'install.sh').write_text('printf "%s" "$1" > "$HOME/selected"\nexit "${SETUP_STATUS:-0}"\n')
    bin_dir = root / 'bin'
    bin_dir.mkdir()
    git = bin_dir / 'git'
    git.write_text('#!/bin/bash\nset -eu\n[[ "$1" == clone ]]\n[[ "$2" == --branch && "$3" == standalone-hyprland ]]\n[[ "$4" == https://github.com/JacksonDCollins/dotfiles.git ]]\ncp -R "$FIXTURE" "$5"\n')
    git.chmod(0o755)
    env = dict(os.environ, FIXTURE=str(fixture),
               PATH=f'{bin_dir}:{os.environ["PATH"]}')
    for index, (answer, setup_status, expected_status) in enumerate([
        ('99\n2\n', '0', 0), ('', '0', 1), ('1\n', '7', 7),
    ]):
        home = root / f'home-{index}'
        home.mkdir()
        env.update(HOME=str(home), SETUP_STATUS=setup_status)
        result = subprocess.run(['bash', '-c', body], input=answer, text=True,
                                capture_output=True, env=env)
        assert result.returncode == expected_status, result.stderr
        if index == 0:
            assert (home / 'selected').read_text() == 'new-profile'
            assert 'Invalid selection' in result.stderr
        if index == 1:
            assert not (home / 'selected').exists()
    # A repository with no selectable profiles must fail without running setup.
    for profile in ('default', 'new-profile'):
        (fixture / 'machines' / profile).rmdir()
    home = root / 'empty-home'
    home.mkdir()
    env['HOME'] = str(home)
    result = subprocess.run(['bash', '-c', body], input='', text=True,
                            capture_output=True, env=env)
    assert result.returncode != 0 and 'No valid' in result.stderr
print('PASS: dynamic profiles, invalid input, EOF, empty profiles, and setup failure')
