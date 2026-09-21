"""Exercise setup's user phase with local Git repos and a temporary HOME."""

import os
import shlex
import subprocess
import tempfile
from pathlib import Path

source = (Path(__file__).resolve().parents[1] / 'setup.sh').read_text()
command = source[source.index('runuser -u '):source.index('\n# Replace only')]
argv = shlex.split(command)
assert argv[:3] == ['runuser', '-u', '$user']
assert 'HOME=$user_home' in argv
body = argv[argv.index('-c') + 1]
url = 'https://github.com/JacksonDCollins/dotfiles.git'
branch = 'standalone-hyprland'

with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    remote = root / 'remote'
    home = root / 'home'
    home.mkdir()
    env = dict(os.environ, HOME=str(home), GIT_CONFIG_GLOBAL='/dev/null',
               GIT_CONFIG_NOSYSTEM='1', GIT_AUTHOR_NAME='Test', GIT_AUTHOR_EMAIL='test@example.com',
               GIT_COMMITTER_NAME='Test', GIT_COMMITTER_EMAIL='test@example.com',
               GIT_CONFIG_COUNT='1', GIT_CONFIG_KEY_0=f'url.{remote}.insteadOf', GIT_CONFIG_VALUE_0=url)

    def git(path, *args):
        return subprocess.check_output(['git', '-C', str(path), *args], env=env, text=True).strip()

    subprocess.run(['git', 'init', '-q', '-b', branch, str(remote)], env=env, check=True)
    for name in ('default', 'new-profile'):
        (remote / 'machines' / name).mkdir(parents=True)
        (remote / 'machines' / name / '.keep').touch()
    (remote / 'install.sh').write_text('''set -e
mkdir -p "$HOME/.local/state/dotfiles"
printf "%s" "$1" > "$HOME/.local/state/dotfiles/machine"
printf "%s\\n" "$1" >> "$HOME/selected"
exit "${SETUP_STATUS:-0}"
''')
    git(remote, 'add', '.')
    git(remote, 'commit', '-qm', 'fixture')

    # Keep origin's public URL visible to validation while redirecting transport locally.
    # git remote get-url expands insteadOf, so mock only that read, not clone/pull/status.
    real_git = subprocess.check_output(['which', 'git'], text=True).strip()
    bin_dir = root / 'bin'
    bin_dir.mkdir()
    wrapper = bin_dir / 'git'
    wrapper.write_text(f'''#!/bin/bash
if [[ "$*" == "remote get-url origin" ]]; then
    exec {shlex.quote(real_git)} config --get remote.origin.url
fi
exec {shlex.quote(real_git)} "$@"
''')
    wrapper.chmod(0o755)
    env['PATH'] = f'{bin_dir}:{env["PATH"]}'

    def run(answer='', profile='', status=0):
        result = subprocess.run(['bash', '-c', body, '--', profile], input=answer,
                                capture_output=True, text=True, env=env)
        assert result.returncode == status, result.stderr
        return result

    run('99\n2\n')
    assert (home / 'selected').read_text().splitlines() == ['new-profile']
    repo = home / 'dotfiles'
    (remote / 'updated').write_text('new upstream version')
    git(remote, 'add', '.')
    git(remote, 'commit', '-qm', 'update')
    run()  # Saved profile, fast-forward update, no prompt.
    assert (repo / 'updated').exists()
    assert (home / 'selected').read_text().splitlines() == ['new-profile'] * 2
    run(profile='default')
    assert (home / '.local/state/dotfiles/machine').read_text() == 'default'
    (repo / 'uncommitted').touch()
    assert 'local dotfiles changes' in run(status=1).stderr
    (repo / 'uncommitted').unlink()
    git(repo, 'switch', '-qc', 'different')
    assert 'Expected dotfiles branch' in run(status=1).stderr
    git(repo, 'switch', '-q', branch)
    run(profile='../../etc', status=1)
    (home / '.local/state/dotfiles/machine').unlink()
    run(status=1)  # EOF is not silently accepted.
    env['SETUP_STATUS'] = '7'
    run(profile='default', status=7)
    del env['SETUP_STATUS']
    (repo / 'local').touch()
    git(repo, 'add', '.')
    git(repo, 'commit', '-qm', 'local commit')
    (remote / 'upstream').touch()
    git(remote, 'add', '.')
    git(remote, 'commit', '-qm', 'upstream commit')
    run(profile='default', status=128)  # Divergence must not trigger a merge/reset.
print('PASS: clone, saved profiles, fast-forward updates, dirty/wrong-branch/diverged refusal, EOF and setup failure')
