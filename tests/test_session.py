"""Check the generated login config without installing or starting a session."""

import shlex
from pathlib import Path

import tomllib

source = (Path(__file__).resolve().parents[1] / 'install.sh').read_text()
packages = shlex.split(source.split('EXTRA_PACKAGES=(', 1)[1].split(')', 1)[0])
assert {'uwsm', 'greetd', 'greetd-tuigreet', 'hyprpolkitagent'} <= set(packages)
config = tomllib.loads(source.split("<<'GREETD'\n", 1)[1].split('\nGREETD', 1)[0])
assert config['terminal']['vt'] == 1
assert config['default_session']['user'] == 'greeter'
args = shlex.split(config['default_session']['command'])
assert args == ['tuigreet', '--time', '--remember', '--cmd',
                'uwsm start -e -D Hyprland hyprland.desktop']
assert 'initial_session' not in config
assert 'systemctl --global enable hyprpolkitagent.service' in source
assert 'systemctl --user start hyprpolkitagent' not in source
print('PASS: UWSM greeter command, authenticated login, and offline service enablement')
