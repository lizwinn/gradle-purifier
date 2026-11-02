#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Exercise native locking and execution with a Nix-provided JVM module."""
from pathlib import Path
import json, os, shutil, subprocess, tempfile

root = Path(__file__).resolve().parent.parent
system = subprocess.check_output(
    ['nix', 'eval', '--impure', '--raw', '--expr', 'builtins.currentSystem'], text=True).strip()
snapshot = json.loads(subprocess.check_output(
    ['nix', 'flake', 'metadata', '--json', '--no-write-lock-file', 'path:' + str(root)], text=True))['path']
with tempfile.TemporaryDirectory(prefix="purifier-native-composition-") as temporary:
    temporary = Path(temporary)
    package = subprocess.check_output(
        ['nix', 'build', str(root) + '#default', '--print-out-paths',
         '--out-link', str(temporary / 'cli')], text=True).strip().splitlines()[-1]
    cli = Path(package) / 'bin/gradle-purifier'
    workspace = temporary / 'project'
    shutil.copytree(root / 'tests/fixtures/java-library', workspace)
    (workspace / 'gradle-purifier.lock.json').unlink(missing_ok=True)
    reference='path:'+snapshot+'#checks.'+system+'.composition.producer'
    env=dict(os.environ,GRADLE_USER_HOME=str(temporary/'gradle-home'))
    def run(*args):
        subprocess.run([str(x) for x in args],cwd=workspace,env=env,check=True)
    run(cli,'lock','--input',reference)
    locked=json.loads((workspace/'gradle-purifier.lock.json').read_text())
    assert len(locked['projectInputs'])==1
    assert not any('/org/apache/commons/commons-lang3/' in entry.get('path', entry.get('url', '')) for entry in locked['artifacts'])
    run(cli,'prefetch')
    run(workspace/'.gradle-purifier/distribution/bin/gradle','--no-daemon','clean','check','generatePomFileForMavenPublication')
    print('GRADLE NATIVE ROUNDTRIP PASSED')
