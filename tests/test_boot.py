import os
import subprocess
import tempfile
from pathlib import Path

launcher = Path(__file__).resolve().parents[1] / 'boot.sh'
subprocess.run(['bash', '-n', launcher], check=True)
with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    mock = root / 'systemd-run'
    mock.write_text('''#!/usr/bin/env python3
import os, sys
from pathlib import Path
args = sys.argv[1:]
assert '--fail-early' in args and '--fail' in args
paths = [Path(args[i+1]) for i, arg in enumerate(args) if arg == '--output']
assert [p.name for p in paths] == ['install.sh', 'setup.sh']
Path(os.environ['WORK_LOG']).write_text(str(paths[0].parent))
paths[0].write_text('test -f "$(dirname "$0")/setup.sh" || exit 1\\nprintf ran > "$RUN_LOG"\\n')
if os.environ.get('FAIL_DOWNLOAD'):
    sys.exit(22)
paths[1].write_text('# mock setup\\n')
''')
    mock.chmod(0o755)
    env = dict(os.environ, PATH=f'{root}:{os.environ["PATH"]}',
               WORK_LOG=str(root / 'work'), RUN_LOG=str(root / 'ran'))
    subprocess.run(['bash', launcher], env=env, check=True)
    assert (root / 'ran').read_text() == 'ran'
    assert not Path((root / 'work').read_text()).exists()
    (root / 'ran').unlink()
    env['FAIL_DOWNLOAD'] = '1'
    result = subprocess.run(['bash', launcher], env=env)
    assert result.returncode == 22
    assert not (root / 'ran').exists()
    assert not Path((root / 'work').read_text()).exists()
print('PASS: both scripts required, download failure stops execution, temporary files cleaned')
